import AppKit
import ApplicationServices
import CoreGraphics

/// Detects incoming message / notification UI.
///
/// Sources:
/// 1. System Notification Center toast banners
/// 2. QQ / WeChat (微信) in-app toast windows (often bypass NC)
/// 3. Top-of-screen “island” pills
///
/// Desktop NC widgets (huge negative layers) are ignored.
final class NotificationBannerMonitor {
    private var observer: AXObserver?
    private var observedPIDs = Set<pid_t>()
    private var windowPollTimer: Timer?
    private var axAttachTimer: Timer?
    private var knownWindowIDs = Set<CGWindowID>()
    private var primed = false
    private var lastFire = Date.distantPast
    private let cooldown: TimeInterval = 1.5
    private(set) var isRunning = false
    var onBanner: (() -> Void)?
    var onBannersCleared: (() -> Void)?
    var onNotificationCenterOpened: (() -> Void)?
    private var hadBannerHost = false
    private var hadNotificationCenterPanel = false
    private(set) var hasVisibleBanner = false
    private(set) var isNotificationCenterOpen = false

    private let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterAlert",
        "AXNotificationCenterNotification",
        "AXNotificationCenterBannerWindow",
        "AXNotificationCenterAlertStack",
    ]

    private let ncOwnerNames: Set<String> = [
        "Notification Center",
        "NotificationCentre",
        "Notification Center UI",
        "通知中心",
        "Control Center",
        "控制中心",
    ]

    /// Apps that often show their own toasts instead of (or in addition to) NC.
    private let imOwnerHints: [String] = [
        "qq", "wechat", "微信", "telegram", "slack", "discord", "钉钉", "飞书", "lark",
    ]

    func start() {
        stop()
        isRunning = true
        knownWindowIDs = currentBannerWindowIDs()
        hadBannerHost = !knownWindowIDs.isEmpty
        hasVisibleBanner = hadBannerHost
        isNotificationCenterOpen = isNotificationCenterPanelVisible()
        hadNotificationCenterPanel = isNotificationCenterOpen
        primed = true

        windowPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.pollWindows()
        }
        if let windowPollTimer {
            RunLoop.main.add(windowPollTimer, forMode: .common)
        }

        if AXIsProcessTrusted() {
            attachAccessibilityTargets()
            axAttachTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.attachAccessibilityTargets()
            }
            if let axAttachTimer {
                RunLoop.main.add(axAttachTimer, forMode: .common)
            }
        }

        NSLog(
            "MagOff: banner monitor started (hosts=%d ax=%d)",
            knownWindowIDs.count,
            AXIsProcessTrusted() ? 1 : 0
        )
    }

    func stop() {
        isRunning = false
        windowPollTimer?.invalidate()
        windowPollTimer = nil
        axAttachTimer?.invalidate()
        axAttachTimer = nil
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        observedPIDs.removeAll()
        knownWindowIDs.removeAll()
        primed = false
    }

    static func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for s in urls {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    // MARK: - Poll

    private func pollWindows() {
        let current = currentBannerWindowIDs()
        defer { knownWindowIDs = current }
        guard primed else { return }

        hasVisibleBanner = !current.isEmpty

        let panelOpen = isNotificationCenterPanelVisible()
        isNotificationCenterOpen = panelOpen
        if panelOpen && !hadNotificationCenterPanel {
            NSLog("MagOff: Notification Center panel opened")
            DispatchQueue.main.async { [weak self] in
                self?.onNotificationCenterOpened?()
            }
        }
        hadNotificationCenterPanel = panelOpen

        let newlyAppeared = current.subtracting(knownWindowIDs)
        if !newlyAppeared.isEmpty {
            NSLog("MagOff: alert UI appeared ids=%@", Array(newlyAppeared).description)
            hadBannerHost = true
            fireIfNeeded()
        }

        if hadBannerHost && current.isEmpty {
            hadBannerHost = false
            NSLog("MagOff: alert UI cleared")
            DispatchQueue.main.async { [weak self] in
                self?.onBannersCleared?()
            }
        } else if !current.isEmpty {
            hadBannerHost = true
        }
    }

    private func ncProcessIDs() -> Set<pid_t> {
        Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.notificationcenterui"
            ).map(\.processIdentifier)
        )
    }

    private func windowSize(_ info: [String: Any]) -> (CGFloat, CGFloat) {
        let b = info[kCGWindowBounds as String] as? [String: Any]
        let w = b?["Width"] as? CGFloat ?? 0
        let h = b?["Height"] as? CGFloat ?? 0
        return (w, h)
    }

    private func windowOrigin(_ info: [String: Any]) -> (CGFloat, CGFloat) {
        let b = info[kCGWindowBounds as String] as? [String: Any]
        let x = b?["X"] as? CGFloat ?? 0
        let y = b?["Y"] as? CGFloat ?? 0
        return (x, y)
    }

    private func isNCOwner(pid: pid_t, owner: String, ncPIDs: Set<pid_t>) -> Bool {
        ncPIDs.contains(pid) || ncOwnerNames.contains(owner)
    }

    private func isIMOwner(_ owner: String) -> Bool {
        let low = owner.lowercased()
        return imOwnerHints.contains { low.contains($0) || owner.contains($0) }
    }

    /// Full Notification Center list (user reading / clearing).
    private func isNotificationCenterPanelVisible() -> Bool {
        let ncPIDs = ncProcessIDs()
        let screenH = NSScreen.main?.frame.height ?? 900
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return false }

        for info in list {
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard isNCOwner(pid: pid, owner: owner, ncPIDs: ncPIDs) else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { continue }
            let (w, h) = windowSize(info)
            // Tall sidebar — not the 360×360 desktop widgets.
            if w >= 300 && w <= 520 && h >= screenH * 0.5 { return true }
        }
        return false
    }

    /// Toast / island / IM alert windows that should trigger MagSafe flash.
    private func currentBannerWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        let ncPIDs = ncProcessIDs()

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return ids }

        for info in list {
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let windowID = CGWindowID(info[kCGWindowNumber as String] as? UInt32 ?? 0)
            guard windowID != 0, alpha > 0.05 else { continue }

            let (w, h) = windowSize(info)
            let (_, y) = windowOrigin(info)

            // Skip desktop widgets / huge app main windows / menu bar.
            if layer < -1000 { continue }
            if owner == "Window Server" || owner == "程序坞" || owner == "Dock" { continue }
            if w > 900 || h > 700 { continue }

            let nc = isNCOwner(pid: pid, owner: owner, ncPIDs: ncPIDs)
            let im = isIMOwner(owner)

            // 1) System NC toast (relaxed layer — some builds use 8–14).
            if nc, layer >= 8, w >= 100, w <= 560, h >= 36, h <= 480 {
                ids.insert(windowID)
                continue
            }

            // 2) QQ / WeChat floating toast (not the main chat window).
            if im, w >= 80, w <= 560, h >= 28, h <= 420, layer >= 0 {
                ids.insert(windowID)
                continue
            }

            // 3) Compact top pill from NC / IM only (avoid menu-bar false positives).
            if (nc || im), y <= 80, w >= 48, w <= 420, h >= 18, h <= 100, layer >= 0 {
                ids.insert(windowID)
                continue
            }
        }
        return ids
    }

    // MARK: - Accessibility (NC + QQ/WeChat)

    private func attachAccessibilityTargets() {
        guard AXIsProcessTrusted() else { return }
        var pids = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.notificationcenterui"
            ).map(\.processIdentifier)
        )
        for bid in ["com.tencent.qq", "com.tencent.xinWeChat"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                if app.processIdentifier != 0 { pids.insert(app.processIdentifier) }
            }
        }
        // Also match localized names if bundle lookup fails.
        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            if name == "qq" || name == "wechat" || name == "微信", app.processIdentifier != 0 {
                pids.insert(app.processIdentifier)
            }
        }

        for pid in pids where pid != 0 && !observedPIDs.contains(pid) {
            attachAX(to: pid)
        }
    }

    private func attachAX(to pid: pid_t) {
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<NotificationBannerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleAX(element: element)
        }, &newObserver)

        guard result == .success, let newObserver else { return }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let appElement = AXUIElementCreateApplication(pid)
        for name in [
            kAXCreatedNotification as String,
            kAXLayoutChangedNotification as String,
            "AXChildrenChanged",
            kAXWindowCreatedNotification as String,
        ] {
            AXObserverAddNotification(newObserver, appElement, name as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        // Keep the latest NC observer in `observer` for cleanup; IM observers stay via runloop.
        if observer == nil {
            observer = newObserver
        }
        observedPIDs.insert(pid)
        NSLog("MagOff: AX attached pid=%d", pid)
    }

    private func handleAX(element: AXUIElement) {
        if elementLooksLikeBanner(element) || treeContainsBanner(element, depth: 0) {
            fireIfNeeded()
        }
    }

    private func fireIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= cooldown else { return }
        lastFire = now
        DispatchQueue.main.async { [weak self] in
            self?.onBanner?()
        }
    }

    private func elementLooksLikeBanner(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
              let sub = subrole as? String
        else { return false }
        return bannerSubroles.contains(sub)
    }

    private func treeContainsBanner(_ element: AXUIElement, depth: Int) -> Bool {
        if depth > 4 { return false }
        if elementLooksLikeBanner(element) { return true }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement]
        else { return false }
        for child in list.prefix(20) {
            if treeContainsBanner(child, depth: depth + 1) { return true }
        }
        return false
    }
}
