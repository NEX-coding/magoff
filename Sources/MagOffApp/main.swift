import AppKit
import MagOffCore
import ServiceManagement

@main
enum MagOffMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var supported = false
    private let bannerMonitor = NotificationBannerMonitor()
    private let codexWatcher = CodexSessionWatcher()
    /// True while a GPT/Codex reply flash is active (stop when that app is focused).
    private var gptFlashActive = false

    private let gptAppBundleIDs: Set<String> = [
        "com.openai.codex", // ChatGPT.app on this Mac
        "com.openai.chat",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        supported = MagSafeLED.isSupported()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = "暗灯 · MagSafe 指示灯"
        }
        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshStatusItemImage()
        configureWatchers()
        observeAppActivation()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        refreshStatusItemImage()
    }

    private func configureWatchers() {
        bannerMonitor.onBanner = { [weak self] in
            guard Preferences.flashOnNotification else { return }
            NSLog("MagOff: NC banner → flash")
            self?.gptFlashActive = false
            self?.triggerFlash()
        }
        bannerMonitor.onBannersCleared = { [weak self] in
            guard Preferences.flashOnNotification else { return }
            // Only restore for general NC flash; GPT flash stops on app focus.
            guard self?.gptFlashActive != true else { return }
            self?.triggerRestore()
        }

        codexWatcher.onTaskComplete = { [weak self] in
            guard Preferences.flashOnGPTReply else { return }
            // Only skip when ChatGPT/Codex chat is already frontmost.
            // Cursor stays a "stop when switched to" target, but must NOT suppress
            // flashes for ChatGPT replies while you're working in Cursor.
            if self?.isChatGPTFrontmost() == true {
                NSLog("MagOff: ChatGPT already focused → skip flash")
                return
            }
            NSLog("MagOff: GPT/Codex reply detected → flash")
            self?.gptFlashActive = true
            self?.triggerFlash()
        }

        updateWatchersRunning()
    }

    private func updateWatchersRunning() {
        if Preferences.flashOnNotification {
            if !bannerMonitor.isRunning { bannerMonitor.start() }
        } else {
            bannerMonitor.stop()
        }

        if Preferences.flashOnGPTReply {
            if !codexWatcher.isRunning { codexWatcher.start() }
        } else {
            codexWatcher.stop()
            gptFlashActive = false
        }
    }

    /// Apps that mean "I'm looking at the reply" → stop an active flash.
    private func isReplyAttentionApp(_ app: NSRunningApplication) -> Bool {
        let bid = app.bundleIdentifier ?? ""
        let name = (app.localizedName ?? "").lowercased()
        return gptAppBundleIDs.contains(bid)
            || name.contains("chatgpt")
            || name.contains("codex")
            || name.contains("cursor")
    }

    /// ChatGPT / Codex desktop only (not Cursor) — skip starting a flash.
    private func isChatGPTFrontmost() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let bid = app.bundleIdentifier ?? ""
        let name = (app.localizedName ?? "").lowercased()
        if bid == "com.todesktop.230313mzl4w4u92" || name.contains("cursor") {
            return false
        }
        return bid == "com.openai.codex"
            || bid == "com.openai.chat"
            || name.contains("chatgpt")
            || name.contains("codex")
    }

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard Preferences.flashOnGPTReply, self.gptFlashActive else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            guard self.isReplyAttentionApp(app) else { return }
            NSLog("MagOff: switched to %@ → stop GPT flash", app.localizedName ?? "")
            self.gptFlashActive = false
            self.triggerRestore()
        }
    }

    private func triggerFlash() {
        do {
            try MagOffPaths.requestFlash()
        } catch {
            NSLog("MagOff flash failed: \(error)")
        }
    }

    private func triggerRestore() {
        do {
            try MagOffPaths.requestRestore()
        } catch {
            NSLog("MagOff restore failed: \(error)")
        }
    }

    private func refreshStatusItemImage() {
        let color = MagSafeLED.current()
        let symbol: String
        switch color {
        case .off:
            symbol = "lightbulb.slash"
        case .green, .amber, .amberBlinkSlow, .amberBlinkFast, .amberBlinkThenOff:
            symbol = "lightbulb.fill"
        case .system, .none:
            symbol = "lightbulb"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "暗灯")!
        image.isTemplate = true
        statusItem.button?.image = image.withSymbolConfiguration(config) ?? image
    }

    @objc private func rebuildMenu() {
        menu.removeAllItems()

        let live = MagSafeLED.current()
        let configured = MagOffPaths.Mode.load()
        let helperOn = PrivilegedInstaller.isHelperInstalled

        let title = NSMenuItem(
            title: supported ? "暗灯 · MagSafe 指示灯" : "暗灯 · 本机可能不支持",
            action: nil,
            keyEquivalent: ""
        )
        title.isEnabled = false
        menu.addItem(title)

        let liveTitle: String
        if let live {
            liveTitle = "当前灯光：\(live.statusTitle)"
        } else {
            liveTitle = "当前灯光：无法读取"
        }
        let liveItem = NSMenuItem(title: liveTitle, action: nil, keyEquivalent: "")
        liveItem.isEnabled = false
        menu.addItem(liveItem)

        if helperOn {
            let cfg = NSMenuItem(
                title: "设定模式：\(configured.led.statusTitle)",
                action: nil,
                keyEquivalent: ""
            )
            cfg.isEnabled = false
            menu.addItem(cfg)
        }

        menu.addItem(.separator())

        let liveMode = live?.mode
        addModeItem(menu, title: "关闭指示灯", mode: .off, selected: liveMode == .off, enabled: supported)
        addModeItem(
            menu,
            title: "系统默认（橙/绿）",
            mode: .system,
            selected: liveMode == .system || (liveMode == nil && live?.isStickyMode != false && !helperOn),
            enabled: supported
        )
        menu.addItem(.separator())
        addModeItem(menu, title: "强制绿灯", mode: .green, selected: liveMode == .green, enabled: supported)
        addModeItem(menu, title: "强制橙灯", mode: .amber, selected: liveMode == .amber, enabled: supported)

        menu.addItem(.separator())

        let gptFlash = NSMenuItem(
            title: "GPT/Codex 回复时闪烁",
            action: #selector(toggleGPTFlash(_:)),
            keyEquivalent: ""
        )
        gptFlash.target = self
        gptFlash.state = Preferences.flashOnGPTReply ? .on : .off
        gptFlash.isEnabled = supported
        menu.addItem(gptFlash)

        let flashToggle = NSMenuItem(
            title: "所有系统通知都闪烁",
            action: #selector(toggleFlashOnNotification(_:)),
            keyEquivalent: ""
        )
        flashToggle.target = self
        flashToggle.state = Preferences.flashOnNotification ? .on : .off
        flashToggle.isEnabled = supported
        menu.addItem(flashToggle)

        let testFlash = NSMenuItem(
            title: "测试闪灯",
            action: #selector(testFlash(_:)),
            keyEquivalent: ""
        )
        testFlash.target = self
        testFlash.isEnabled = supported && helperOn
        menu.addItem(testFlash)

        if Preferences.flashOnGPTReply {
            let listen = NSMenuItem(
                title: codexWatcher.isRunning
                    ? "Codex 会话监听：工作中"
                    : "Codex 会话监听：未启动",
                action: nil,
                keyEquivalent: ""
            )
            listen.isEnabled = false
            menu.addItem(listen)

            let hint = NSMenuItem(
                title: "监听 Codex DB + sessions（不靠系统通知）",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)

            let hint2 = NSMenuItem(
                title: "切到 ChatGPT/Codex/Cursor 即停闪",
                action: nil,
                keyEquivalent: ""
            )
            hint2.isEnabled = false
            menu.addItem(hint2)
        }

        if Preferences.flashOnNotification {
            let nc = NSMenuItem(
                title: bannerMonitor.isRunning ? "系统通知监听：工作中" : "系统通知监听：未启动",
                action: nil,
                keyEquivalent: ""
            )
            nc.isEnabled = false
            menu.addItem(nc)

            let ax = NSMenuItem(
                title: NotificationBannerMonitor.isTrusted
                    ? "辅助功能：已授权"
                    : "打开辅助功能设置…",
                action: NotificationBannerMonitor.isTrusted ? nil : #selector(openAccessibilitySettings(_:)),
                keyEquivalent: ""
            )
            ax.target = self
            ax.isEnabled = !NotificationBannerMonitor.isTrusted
            menu.addItem(ax)
        }

        let colorNote = NSMenuItem(
            title: "灯色只有橙 / 绿（可关）",
            action: nil,
            keyEquivalent: ""
        )
        colorNote.isEnabled = false
        menu.addItem(colorNote)

        menu.addItem(.separator())

        let status = NSMenuItem(
            title: helperOn ? "后台服务：已安装" : "后台服务：未安装",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        let note = NSMenuItem(
            title: "插拔充电器后会自动再关一次",
            action: nil,
            keyEquivalent: ""
        )
        note.isEnabled = false
        menu.addItem(note)
        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        login.target = self
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        if helperOn {
            let uninstall = NSMenuItem(
                title: "卸载后台服务…",
                action: #selector(uninstallHelper(_:)),
                keyEquivalent: ""
            )
            uninstall.target = self
            menu.addItem(uninstall)
        }

        menu.addItem(.separator())
        let about = NSMenuItem(
            title: "关于暗灯…",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: "退出暗灯",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    @objc private func showAbout(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "暗灯 MagOff \(version)"
        alert.informativeText = """
        关掉 MagSafe 充电器上夜里晃眼的那颗灯。

        · 只改指示灯显示，不影响充电 / 电池 / 键盘背光
        · 可选：GPT 回复或系统通知时绿橙交叉闪
        · 需要带指示灯的 MagSafe 线 + Apple Silicon MacBook

        分享给室友 / 同学前，先自己测一遍「关闭指示灯」。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func addModeItem(
        _ menu: NSMenu,
        title: String,
        mode: MagOffPaths.Mode,
        selected: Bool,
        enabled: Bool
    ) {
        let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode.rawValue
        item.state = selected ? .on : .off
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MagOffPaths.Mode(rawValue: raw) else { return }

        do {
            if PrivilegedInstaller.isHelperInstalled {
                try PrivilegedInstaller.writeModeOnly(mode)
            } else {
                try PrivilegedInstaller.setMode(mode)
            }
            gptFlashActive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.rebuildMenu()
                self?.refreshStatusItemImage()
            }
        } catch {
            presentError(error)
        }
    }

    @objc private func toggleFlashOnNotification(_ sender: Any?) {
        Preferences.flashOnNotification.toggle()
        if Preferences.flashOnNotification, !NotificationBannerMonitor.isTrusted {
            NotificationBannerMonitor.openAccessibilitySettings()
        }
        updateWatchersRunning()
        rebuildMenu()
    }

    @objc private func toggleGPTFlash(_ sender: Any?) {
        Preferences.flashOnGPTReply.toggle()
        updateWatchersRunning()
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        NotificationBannerMonitor.openAccessibilitySettings()
    }

    @objc private func testFlash(_ sender: Any?) {
        do {
            if !FileManager.default.isWritableFile(atPath: MagOffPaths.cmdFile) {
                try PrivilegedInstaller.ensureCommandFile()
            }
            try MagOffPaths.requestPulse()
        } catch {
            presentError(error)
        }
    }

    @objc private func uninstallHelper(_ sender: Any?) {
        do {
            try PrivilegedInstaller.uninstall()
            rebuildMenu()
            refreshStatusItemImage()
        } catch {
            presentError(error)
        }
    }

    private var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            rebuildMenu()
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "暗灯"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
