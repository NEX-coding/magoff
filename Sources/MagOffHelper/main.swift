import Foundation
import IOKit.ps
import MagOffCore
import os.log

/// Root LaunchDaemon: keeps MagSafe LED in the configured mode.
/// Re-asserts on power-source changes because plugging MagSafe resets the LED.
/// Handles flash / pulse / restore for notification unread indication.

let log = Logger(subsystem: MagOffPaths.helperLabel, category: "helper")

if CommandLine.arguments.contains("--probe") {
    do {
        let info = try SMC.keyInfo(MagSafeLED.key)
        print("ACLC present: size=\(info.size) type=\(info.type)")
        print("supported=yes")
        exit(0)
    } catch {
        print("ACLC probe failed: \(error)")
        exit(1)
    }
}

// Read-only diagnostic used by the portable repair/verification script.
if CommandLine.arguments.contains("--status") {
    do {
        print("ACLC byte=\(try SMC.readByte(MagSafeLED.key))")
        exit(0)
    } catch {
        fputs("status failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--off") {
    do {
        try MagSafeLED.set(.off)
        print("MagSafe LED off")
        exit(0)
    } catch {
        fputs("off failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--reset") {
    do {
        try MagSafeLED.set(.system)
        print("MagSafe LED handed back to macOS")
        exit(0)
    } catch {
        fputs("reset failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--flash") {
    do {
        _ = try runCrossFlash(using: nil, shouldStop: { false })
        try MagSafeLED.set(.amber)
        print("flashed then amber")
        exit(0)
    } catch {
        fputs("flash failed: \(error)\n", stderr)
        exit(1)
    }
}

if let setIndex = CommandLine.arguments.firstIndex(of: "--set"),
   CommandLine.arguments.indices.contains(setIndex + 1) {
    let raw = CommandLine.arguments[setIndex + 1]
    guard let color = MagSafeLED.Color.allCases.first(where: { $0.description == raw })
            ?? MagSafeLED.Color(rawValue: UInt8(raw) ?? 255) else {
        fputs("unknown color: \(raw)\n", stderr)
        exit(2)
    }
    do {
        try MagSafeLED.set(color)
        print("MagSafe LED set to \(color)")
        exit(0)
    } catch {
        fputs("set failed: \(error)\n", stderr)
        exit(1)
    }
}

/// ~10s green ↔ amber at 0.2s per color. Stops early when `shouldStop` becomes true
/// (notification dismissed mid-flash).
@discardableResult
private func runCrossFlash(
    using connection: SMC.Connection?,
    shouldStop: () -> Bool
) throws -> Bool {
    let dwell: TimeInterval = 0.3
    let duration: TimeInterval = 10.0
    let cycles = max(1, Int((duration / (dwell * 2.0)).rounded()))
    let sequence: [MagSafeLED.Color] = [.green, .amber]

    func apply(_ color: MagSafeLED.Color) throws {
        if shouldStop() { return }
        if let connection {
            try MagSafeLED.set(color, using: connection)
        } else {
            try MagSafeLED.set(color)
        }
        // Interruptible dwell so restore can cut flash within ~50ms.
        let deadline = Date().addingTimeInterval(dwell)
        while Date() < deadline {
            if shouldStop() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    for _ in 0..<cycles {
        if shouldStop() { return true }
        for color in sequence {
            if shouldStop() { return true }
            try apply(color)
        }
    }
    return shouldStop()
}

final class Helper {
    private let smc: SMC.Connection
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var modeWatcher: DispatchSourceFileSystemObject?
    private var modeDirFD: Int32 = -1
    private var assertTimer: DispatchSourceTimer?
    private var cmdPollTimer: DispatchSourceTimer?
    private var isFlashing = false
    /// After a notification flash, keep amber until `restore` (banner dismissed).
    private var holdingUnreadAmber = false
    /// Set when user dismisses notification during the 10s flash — abort immediately.
    private var flashStopRequested = false
    private var flashWorkItem: DispatchWorkItem?
    private var lastModeRaw: String = MagOffPaths.Mode.load().rawValue

    init() throws {
        self.smc = try SMC.Connection()
    }

    func start() {
        ensureCmdFile()
        applyCurrentMode(reason: "startup")
        watchPowerSource()
        watchSupportDir()
        startReassertTimer()
        startCmdPollTimer()
        installSignalHandlers()
        log.info("magoff-helper running")
        RunLoop.main.run()
    }

    private func ensureCmdFile() {
        try? FileManager.default.createDirectory(
            atPath: MagOffPaths.supportDir,
            withIntermediateDirectories: true
        )
        for path in [MagOffPaths.cmdFile, MagOffPaths.modeFile] {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(
                    atPath: path,
                    contents: path == MagOffPaths.modeFile
                        ? Data(MagOffPaths.Mode.system.rawValue.utf8)
                        : Data(),
                    attributes: [.posixPermissions: 0o666]
                )
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o666],
                ofItemAtPath: path
            )
        }
    }

    private func applyCurrentMode(reason: String, force: Bool = false) {
        guard force || !isFlashing else { return }
        if holdingUnreadAmber {
            do {
                try MagSafeLED.set(.amber, using: smc)
                log.info("LED amber (unread hold, \(reason, privacy: .public))")
            } catch {
                log.error("failed to hold amber: \(String(describing: error), privacy: .public)")
            }
            return
        }
        let mode = MagOffPaths.Mode.load()
        do {
            try MagSafeLED.set(mode.led, using: smc)
            log.info("LED \(mode.led.description, privacy: .public) (\(reason, privacy: .public))")
        } catch {
            log.error("failed to set LED: \(String(describing: error), privacy: .public)")
        }
    }

    private func clearCmdFile() {
        let fd = open(MagOffPaths.cmdFile, O_WRONLY | O_TRUNC)
        if fd >= 0 { close(fd) }
    }

    private func handleCommandFile() {
        guard let raw = try? String(contentsOfFile: MagOffPaths.cmdFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return }

        clearCmdFile()

        if raw.hasPrefix("set:") {
            let name = String(raw.dropFirst(4))
            guard let mode = MagOffPaths.Mode(rawValue: name) else {
                log.error("unknown set mode: \(raw, privacy: .public)")
                return
            }
            // Root can rewrite mode even when file is 644; also relax perms for the app.
            if let data = mode.rawValue.data(using: .utf8) {
                try? data.write(to: URL(fileURLWithPath: MagOffPaths.modeFile), options: .atomic)
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o666],
                ofItemAtPath: MagOffPaths.modeFile
            )
            lastModeRaw = mode.rawValue
            flashStopRequested = true
            flashWorkItem?.cancel()
            holdingUnreadAmber = false
            isFlashing = false
            applyCurrentMode(reason: "set-cmd", force: true)
            log.info("mode set via cmd: \(mode.rawValue, privacy: .public)")
            return
        }

        switch MagOffPaths.Command(rawValue: raw) {
        case .flash:
            // Flash then return to configured mode. Amber "unread hold" is opt-in via `hold`.
            startFlash(holdAmberAfter: false)
        case .pulse:
            startFlash(holdAmberAfter: false)
        case .hold:
            // Banner auto-timeout (unread). Stop blink, keep amber until user handles it.
            holdingUnreadAmber = true
            flashStopRequested = true
            flashWorkItem?.cancel()
            isFlashing = false
            applyCurrentMode(reason: "hold-amber", force: true)
            log.info("hold: flash stopped, amber kept")
        case .restore:
            // Explicit clear (mode menu / GPT focus / 「恢复设定」).
            flashStopRequested = true
            flashWorkItem?.cancel()
            holdingUnreadAmber = false
            isFlashing = false
            applyCurrentMode(reason: "restore", force: true)
            log.info("restore: flash aborted, mode reapplied")
        case .none:
            log.error("unknown cmd: \(raw, privacy: .public)")
        }
    }

    private func startFlash(holdAmberAfter: Bool) {
        flashWorkItem?.cancel()
        flashStopRequested = false
        isFlashing = true
        holdingUnreadAmber = false
        log.info("cross-flash ~10s holdAfter=\(holdAmberAfter)")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var stoppedEarly = false
            do {
                stoppedEarly = try runCrossFlash(using: self.smc) {
                    self.flashStopRequested || (self.flashWorkItem?.isCancelled ?? false)
                }
            } catch {
                log.error("flash failed: \(String(describing: error), privacy: .public)")
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let aborted = stoppedEarly || self.flashStopRequested
                    || (self.flashWorkItem?.isCancelled == true)
                self.isFlashing = false
                if aborted {
                    // `hold` may have already requested unread amber — don't wipe it.
                    if self.holdingUnreadAmber {
                        self.applyCurrentMode(reason: "flash-aborted-keep-amber", force: true)
                        log.info("flash aborted → keep amber hold")
                    } else {
                        self.applyCurrentMode(reason: "flash-aborted", force: true)
                        log.info("flash aborted → reapply mode")
                    }
                    return
                }
                if holdAmberAfter {
                    self.holdingUnreadAmber = true
                    self.applyCurrentMode(reason: "flash-hold-amber", force: true)
                } else if self.holdingUnreadAmber {
                    self.applyCurrentMode(reason: "flash-done-keep-amber", force: true)
                } else {
                    self.applyCurrentMode(reason: "flash-done", force: true)
                }
                log.info(
                    "flash done hold=\(self.holdingUnreadAmber) mode=\(MagOffPaths.Mode.load().rawValue, privacy: .public)"
                )
            }
        }
        flashWorkItem = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func checkModeFileChange() {
        let raw = MagOffPaths.Mode.load().rawValue
        guard raw != lastModeRaw else { return }
        lastModeRaw = raw
        // Mode change always wins over an in-progress flash / amber hold.
        flashStopRequested = true
        flashWorkItem?.cancel()
        isFlashing = false
        holdingUnreadAmber = false
        applyCurrentMode(reason: "mode-file-change", force: true)
    }

    private func watchPowerSource() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            let helper = Unmanaged<Helper>.fromOpaque(ctx!).takeUnretainedValue()
            helper.applyCurrentMode(reason: "power-source-change")
        }, context)?.takeRetainedValue() else {
            log.error("failed to create IOPS notification source")
            return
        }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func watchSupportDir() {
        let dir = MagOffPaths.supportDir
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        modeDirFD = open(dir, O_EVTONLY)
        guard modeDirFD >= 0 else {
            log.error("cannot watch \(dir, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: modeDirFD,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleCommandFile()
            self?.checkModeFileChange()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.modeDirFD, fd >= 0 {
                close(fd)
                self?.modeDirFD = -1
            }
        }
        modeWatcher = source
        source.resume()
    }

    private func startReassertTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFlashing else { return }
            if self.holdingUnreadAmber {
                self.applyCurrentMode(reason: "reassert-unread")
                return
            }
            guard MagOffPaths.Mode.load() != .system else { return }
            self.applyCurrentMode(reason: "reassert")
        }
        assertTimer = timer
        timer.resume()
    }

    private func startCmdPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.handleCommandFile()
            self?.checkModeFileChange()
        }
        cmdPollTimer = timer
        timer.resume()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                log.info("signal \(sig); restoring system LED control")
                try? MagSafeLED.set(.system)
                exit(0)
            }
            source.resume()
        }
    }
}

do {
    try Helper().start()
} catch {
    fputs("helper failed to start: \(error)\n", stderr)
    exit(1)
}
