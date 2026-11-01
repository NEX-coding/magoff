import AppKit
import ApplicationServices

/// Dismisses Notification Center banners that look like ChatGPT / Codex / OpenAI replies.
enum NotificationDismisser {
    static let gptKeywords: [String] = [
        "ChatGPT",
        "Codex",
        "OpenAI",
        "chatgpt",
        "openai",
    ]

    static func dismissGPTBanners() -> Int {
        guard AXIsProcessTrusted() else {
            NSLog("MagOff: cannot dismiss banners — Accessibility not trusted")
            return 0
        }
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        )
        guard let app = apps.first else { return 0 }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var dismissed = 0
        dismissMatching(in: root, depth: 0, dismissed: &dismissed)
        return dismissed
    }

    /// Whether any visible NC banner looks like ChatGPT / Codex / OpenAI.
    static func hasVisibleGPTBanner() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        )
        guard let app = apps.first else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        return hasGPTBanner(in: root, depth: 0)
    }

    static func bannerLooksLikeGPT(_ text: String) -> Bool {
        let lower = text.lowercased()
        return gptKeywords.contains { lower.contains($0.lowercased()) }
    }

    private static func hasGPTBanner(in element: AXUIElement, depth: Int) -> Bool {
        if depth > 10 { return false }
        let sub = stringAttr(element, kAXSubroleAttribute as String) ?? ""
        let desc = stringAttr(element, kAXDescriptionAttribute as String) ?? ""
        let title = stringAttr(element, kAXTitleAttribute as String) ?? ""
        let blob = "\(title) \(desc)"
        let isBanner =
            sub == "AXNotificationCenterBanner"
            || sub == "AXNotificationCenterAlert"
            || sub == "AXNotificationCenterNotification"
            || sub == "AXNotificationCenterAlertStack"
        if isBanner, bannerLooksLikeGPT(blob) { return true }
        guard let kids = arrayAttr(element, kAXChildrenAttribute as String) else { return false }
        for child in kids.prefix(40) {
            if hasGPTBanner(in: child, depth: depth + 1) { return true }
        }
        return false
    }

    private static func dismissMatching(in element: AXUIElement, depth: Int, dismissed: inout Int) {
        if depth > 10 { return }

        let sub = stringAttr(element, kAXSubroleAttribute as String) ?? ""
        let desc = stringAttr(element, kAXDescriptionAttribute as String) ?? ""
        let title = stringAttr(element, kAXTitleAttribute as String) ?? ""
        let blob = "\(title) \(desc)"

        let isBanner =
            sub == "AXNotificationCenterBanner"
            || sub == "AXNotificationCenterAlert"
            || sub == "AXNotificationCenterNotification"
            || sub == "AXNotificationCenterAlertStack"

        if isBanner, bannerLooksLikeGPT(blob) {
            if dismissBanner(element) {
                dismissed += 1
                NSLog("MagOff: dismissed GPT/Codex banner: %@", String(blob.prefix(80)))
            }
            return
        }

        guard let kids = arrayAttr(element, kAXChildrenAttribute as String) else { return }
        for child in kids.prefix(40) {
            dismissMatching(in: child, depth: depth + 1, dismissed: &dismissed)
        }
    }

    private static func dismissBanner(_ banner: AXUIElement) -> Bool {
        // Prefer explicit dismiss actions on the group.
        if performAction(banner, "AXDismiss") { return true }
        if performAction(banner, "AXRemoveFromParent") { return true }

        // Reveal close button (needed on newer macOS), then press it.
        hover(banner)
        Thread.sleep(forTimeInterval: 0.25)

        if let close = findCloseButton(in: banner, depth: 0) {
            if performAction(close, kAXPressAction as String) { return true }
        }

        // Last resort: actions named 关闭 / Close on the banner itself.
        var actionNames: CFArray?
        if AXUIElementCopyActionNames(banner, &actionNames) == .success,
           let names = actionNames as? [String] {
            for name in names {
                let lower = name.lowercased()
                if lower.contains("close") || lower.contains("dismiss") || name.contains("关闭") {
                    if performAction(banner, name) { return true }
                }
            }
        }
        return false
    }

    private static func findCloseButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 6 { return nil }
        let role = stringAttr(element, kAXRoleAttribute as String) ?? ""
        if role == "AXButton" {
            let title = (stringAttr(element, kAXTitleAttribute as String) ?? "").lowercased()
            let desc = (stringAttr(element, kAXDescriptionAttribute as String) ?? "").lowercased()
            let help = (stringAttr(element, kAXHelpAttribute as String) ?? "").lowercased()
            let blob = "\(title) \(desc) \(help)"
            if blob.contains("close")
                || blob.contains("clear")
                || blob.contains("dismiss")
                || blob.contains("关闭")
                || blob.contains("清除") {
                return element
            }
        }
        guard let kids = arrayAttr(element, kAXChildrenAttribute as String) else { return nil }
        for child in kids.prefix(30) {
            if let found = findCloseButton(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func hover(_ element: AXUIElement) {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as String as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as String as CFString, &size) == .success
        else { return }

        var point = CGPoint.zero
        var rectSize = CGSize.zero
        // AXValueGetValue is the portable way; fall back silently if unavailable.
        if CFGetTypeID(pos) == AXValueGetTypeID() {
            AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        }
        if CFGetTypeID(size) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &rectSize)
        }
        guard rectSize.width > 0, rectSize.height > 0 else { return }
        let target = CGPoint(x: point.x + min(24, rectSize.width / 2), y: point.y + min(16, rectSize.height / 2))
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
    }

    private static func performAction(_ element: AXUIElement, _ name: String) -> Bool {
        AXUIElementPerformAction(element, name as CFString) == .success
    }

    private static func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func arrayAttr(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
