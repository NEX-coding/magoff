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
    /// Primary detector on modern macOS (banners are not separate CGWindows).
    private let logMonitor = NotificationLogMonitor()
    private let codexWatcher = CodexSessionWatcher()
    /// True while a GPT/Codex reply flash is active (stop when that app is focused).
    private var gptFlashActive = false
    /// True after a system-notification flash until amber is cleared.
    private var ncUnreadActive = false
    /// Last time the user brought an app to the front (used to detect notification clicks).
    private var lastAppActivationAt = Date.distantPast
    private var lastNCFlashAt = Date.distantPast
    private var lastBannerClearedAt = Date.distantPast
    private var pendingClearWork: DispatchWorkItem?
    private var stuckAmberWatch: Timer?

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
        startStuckAmberWatch()
        // Helper may still be holding amber from a previous session — clear it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.triggerRestore()
        }
    }

    /// If LED is amber but user mode isn't amber and we're not in an active
    /// unread/GPT flash, force restore (fixes stuck orange after dismiss).
    private func startStuckAmberWatch() {
        stuckAmberWatch?.invalidate()
        stuckAmberWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard Preferences.flashOnNotification || Preferences.flashOnGPTReply else { return }
            guard !self.ncUnreadActive, !self.gptFlashActive else { return }
            guard MagOffPaths.Mode.load() != .amber else { return }
            guard MagSafeLED.current() == .amber else { return }
            // Allow a short grace after flash start.
            guard Date().timeIntervalSince(self.lastNCFlashAt) > 12 else { return }
            NSLog("MagOff: stuck amber detected → restore")
            self.triggerRestore()
        }
        if let stuckAmberWatch {
            RunLoop.main.add(stuckAmberWatch, forMode: .common)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        refreshStatusItemImage()
    }

    private func configureWatchers() {
        let onBanner: () -> Void = { [weak self] in
            guard let self else { return }
            guard Preferences.flashOnNotification else { return }
            // Debounce window+log dual detectors.
            let now = Date()
            guard now.timeIntervalSince(self.lastNCFlashAt) > 1.2 else { return }
            self.lastNCFlashAt = now
            NSLog("MagOff: notification → flash")
            self.gptFlashActive = false
            self.ncUnreadActive = true
            self.triggerFlash()
        }
        /// Banner timed out unread → stop blink, keep amber.
        let onExpired: () -> Void = { [weak self] in
            guard let self else { return }
            guard Preferences.flashOnNotification else { return }
            guard !self.gptFlashActive else { return }
            guard self.ncUnreadActive else { return }
            self.lastBannerClearedAt = Date()
            self.pendingClearWork?.cancel()
            // Wait briefly: a click often arrives as app-activation just after dismiss.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.ncUnreadActive, !self.gptFlashActive else { return }
                if Date().timeIntervalSince(self.lastAppActivationAt) < 1.2 {
                    NSLog("MagOff: expired but app focused → clear amber")
                    self.ncUnreadActive = false
                    self.triggerRestore()
                    return
                }
                // Stop flash first, then hold. A hold issued mid-flash races the
                // helper's abort path and can reapply mode (灯灭) on older helpers.
                NSLog("MagOff: banner auto-expired → restore then hold amber")
                self.triggerRestore()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, self.ncUnreadActive, !self.gptFlashActive else { return }
                    if Date().timeIntervalSince(self.lastAppActivationAt) < 1.2 {
                        self.ncUnreadActive = false
                        self.triggerRestore()
                        return
                    }
                    self.triggerHoldAmber()
                }
            }
            self.pendingClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }

        /// User opened / cleared the notification → light off.
        let onHandled: () -> Void = { [weak self] in
            guard let self else { return }
            guard Preferences.flashOnNotification else { return }
            guard !self.gptFlashActive else { return }
            self.lastBannerClearedAt = Date()
            self.pendingClearWork?.cancel()
            NSLog("MagOff: notification handled → clear amber")
            self.ncUnreadActive = false
            self.triggerRestore()
        }

        bannerMonitor.onBanner = onBanner
        // Window detector can't tell timeout vs click — use the delayed expire logic.
        bannerMonitor.onBannersCleared = onExpired
        logMonitor.onBanner = onBanner
        logMonitor.onBannerExpired = onExpired
        logMonitor.onBannerHandled = onHandled

        bannerMonitor.onNotificationCenterOpened = { [weak self] in
            guard let self else { return }
            guard Preferences.flashOnNotification, self.ncUnreadActive else { return }
            NSLog("MagOff: Notification Center opened → clear amber")
            self.pendingClearWork?.cancel()
            self.ncUnreadActive = false
            self.triggerRestore()
        }

        codexWatcher.onTaskComplete = { [weak self] in
            guard Preferences.flashOnGPTReply else { return }
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
            if !NotificationBannerMonitor.isTrusted {
                NotificationBannerMonitor.requestAccessibilityPermission()
            }
            if !bannerMonitor.isRunning { bannerMonitor.start() }
            if !logMonitor.isRunning { logMonitor.start() }
        } else {
            bannerMonitor.stop()
            logMonitor.stop()
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
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }

            // Ignore our own menu-bar process.
            if app.bundleIdentifier == MagOffPaths.bundleID { return }

            self.lastAppActivationAt = Date()

            if Preferences.flashOnGPTReply, self.gptFlashActive, self.isReplyAttentionApp(app) {
                NSLog("MagOff: switched to %@ → stop GPT flash", app.localizedName ?? "")
                self.gptFlashActive = false
                self.ncUnreadActive = false
                self.triggerRestore()
                return
            }

            // User tapped a notification: banner often disappears *before* activation.
            if Preferences.flashOnNotification, self.ncUnreadActive {
                let bannerUp = self.bannerMonitor.hasVisibleBanner
                let justCleared = Date().timeIntervalSince(self.lastBannerClearedAt) < 2.5
                // Also: within a short window after the flash, focusing an app = opened it.
                let recentFlash = Date().timeIntervalSince(self.lastNCFlashAt) < 45
                if bannerUp || justCleared || recentFlash {
                    NSLog("MagOff: app %@ focused → clear unread amber", app.localizedName ?? "")
                    self.pendingClearWork?.cancel()
                    self.ncUnreadActive = false
                    self.triggerRestore()
                }
            }
        }
    }

    private func triggerFlash() {
        do {
            try MagOffPaths.requestFlash()
        } catch {
            NSLog("MagOff flash failed: \(error)")
        }
    }

    private func triggerHoldAmber() {
        do {
            try MagOffPaths.requestHoldAmber()
        } catch {
            NSLog("MagOff hold failed: \(error)")
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
            title: "测试闪灯（结束后恢复设定）",
            action: #selector(testFlash(_:)),
            keyEquivalent: ""
        )
        testFlash.target = self
        testFlash.isEnabled = supported && helperOn
        menu.addItem(testFlash)

        let clearAmber = NSMenuItem(
            title: "恢复设定模式（取消橙灯保持）",
            action: #selector(clearUnreadAmber(_:)),
            keyEquivalent: ""
        )
        clearAmber.target = self
        clearAmber.isEnabled = supported && helperOn
        menu.addItem(clearAmber)

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

            let ncHint = NSMenuItem(
                title: "自动消失→保持橙 · 点开/清掉→灭灯",
                action: nil,
                keyEquivalent: ""
            )
            ncHint.isEnabled = false
            menu.addItem(ncHint)

            let qqHint = NSMenuItem(
                title: logMonitor.isRunning
                    ? "系统横幅日志监听：工作中"
                    : "系统横幅日志监听：未启动",
                action: nil,
                keyEquivalent: ""
            )
            qqHint.isEnabled = false
            menu.addItem(qqHint)

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
            title: helperOn
                ? "换模式无需密码 · 插拔线会自动再关"
                : "首次选模式需一次管理员密码",
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
        · 首次安装后台服务要一次管理员密码，之后换模式不用再输
        · 可选：GPT 回复或系统通知时绿橙交叉闪
        · 需要带指示灯的 MagSafe 线 + Apple Silicon MacBook
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
            ncUnreadActive = false
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
            ncUnreadActive = true
            gptFlashActive = false
            try MagOffPaths.requestFlash()
        } catch {
            presentError(error)
        }
    }

    @objc private func clearUnreadAmber(_ sender: Any?) {
        ncUnreadActive = false
        gptFlashActive = false
        triggerRestore()
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
