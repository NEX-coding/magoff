import AppKit
import ApplicationServices
import CoreGraphics

/// Detects Notification Center banners.
/// Primary path: CGWindowList polling (works with or without Accessibility).
/// On modern macOS the banner host is a large layer≥15 window owned by 通知中心;
/// desktop widgets under NC use huge negative layers and are ignored.
final class NotificationBannerMonitor {
    private var observer: AXObserver?
    private var observedPIDs = Set<pid_t>()
    private var windowPollTimer: Timer?
    private var axAttachTimer: Timer?
    private var knownWindowIDs = Set<CGWindowID>()
    private var primed = false
    private var lastFire = Date.distantPast
    private let cooldown: TimeInterval = 2.0
    private(set) var isRunning = false
    /// Fired when a notification banner host appears.
    var onBanner: (() -> Void)?
    /// Fired when all notification banner hosts have disappeared (user dismissed / timed out).
    var onBannersCleared: (() -> Void)?
    private var hadBannerHost = false

    private let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterAlert",
        "AXNotificationCenterNotification",
        "AXNotificationCenterBannerWindow",
        "AXNotificationCenterAlertStack",
    ]

    private let ownerNames: Set<String> = [
        "Notification Center",
        "NotificationCentre",
        "Notification Center UI",
        "通知中心",
    ]

    func start() {
        stop()
        isRunning = true
        knownWindowIDs = currentBannerWindowIDs()
        hadBannerHost = !knownWindowIDs.isEmpty
        primed = true

        windowPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollWindows()
        }
        if let windowPollTimer {
            RunLoop.main.add(windowPollTimer, forMode: .common)
        }

        if AXIsProcessTrusted() {
            attachToNotificationCenter()
            axAttachTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.attachToNotificationCenter()
            }
            if let axAttachTimer {
                RunLoop.main.add(axAttachTimer, forMode: .common)
            }
        }

        NSLog(
            "MagOff: banner monitor started (bannerHosts=%d, ax=%d)",
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

    // MARK: - CGWindowList

    private func pollWindows() {
        let current = currentBannerWindowIDs()
        defer { knownWindowIDs = current }
        guard primed else { return }

        let newlyAppeared = current.subtracting(knownWindowIDs)
        if !newlyAppeared.isEmpty {
            NSLog("MagOff: notification host appeared ids=%@", Array(newlyAppeared).description)
            hadBannerHost = true
            fireIfNeeded()
        }

        if hadBannerHost && current.isEmpty {
            hadBannerHost = false
            NSLog("MagOff: notification hosts cleared → restore")
            DispatchQueue.main.async { [weak self] in
                self?.onBannersCleared?()
            }
        } else if !current.isEmpty {
            hadBannerHost = true
        }
    }

    /// Banner host windows only (not NC desktop widgets).
    private func currentBannerWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()

        let ncPIDs = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.notificationcenterui"
            ).map(\.processIdentifier)
        )

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return ids }

        for info in list {
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let isNC = ncPIDs.contains(pid) || ownerNames.contains(owner)
            guard isNC else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // Real banners: layer 15+ host window. Widgets use ~ -2147483601.
            guard layer >= 15 else { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let windowID = CGWindowID(info[kCGWindowNumber as String] as? UInt32 ?? 0)
            guard windowID != 0, alpha > 0.05 else { continue }

            ids.insert(windowID)
        }
        return ids
    }

    // MARK: - Accessibility (backup)

    private func attachToNotificationCenter() {
        guard AXIsProcessTrusted() else { return }
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        )
        guard let app = apps.first, app.processIdentifier != 0 else { return }
        let pid = app.processIdentifier
        guard !observedPIDs.contains(pid) else { return }

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

        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedPIDs = [pid]
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
