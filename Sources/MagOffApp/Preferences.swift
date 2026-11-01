import Foundation

enum Preferences {
    private static let flashKey = "flashOnNotification"
    private static let gptFlashKey = "flashOnGPTReply"

    /// Flash on any Notification Center banner.
    static var flashOnNotification: Bool {
        get {
            if UserDefaults.standard.object(forKey: flashKey) == nil { return false }
            return UserDefaults.standard.bool(forKey: flashKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: flashKey) }
    }

    /// Flash when local Codex/ChatGPT finishes a task (`task_complete` in ~/.codex/sessions).
    /// Independent of Notification Center (those apps often don't post banners).
    static var flashOnGPTReply: Bool {
        get {
            if UserDefaults.standard.object(forKey: gptFlashKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: gptFlashKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: gptFlashKey) }
    }
}
