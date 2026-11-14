import Foundation

/// Watches unified logs from NotificationCenter for banner present/dismiss.
/// On modern macOS, banners are drawn inside a full-screen NC host window —
/// CGWindow size filters cannot see them; log lines can.
final class NotificationLogMonitor {
    private var process: Process?
    private var outPipe: Pipe?
    private let queue = DispatchQueue(label: "com.nex.magoff.nc-log")
    private(set) var isRunning = false
    private var buffer = Data()

    var onBanner: (() -> Void)?
    /// Banner timed out by itself (still unread) → keep amber.
    var onBannerExpired: (() -> Void)?
    /// User dismissed / deleted / acted on it → clear amber.
    var onBannerHandled: (() -> Void)?

    func start() {
        stop()
        isRunning = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--style", "compact",
            "--predicate",
            #"process == "NotificationCenter" AND subsystem == "com.apple.unc" AND category == "banner""#,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        outPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async { self?.consume(chunk) }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self, self.isRunning else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.isRunning else { return }
                self.start()
            }
        }

        do {
            try proc.run()
            process = proc
            NSLog("MagOff: NC log monitor started")
        } catch {
            NSLog("MagOff: NC log monitor failed: %@", String(describing: error))
            isRunning = false
        }
    }

    func stop() {
        isRunning = false
        outPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        outPipe = nil
        buffer.removeAll()
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line: line)
        }
        if buffer.count > 64_000 {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func handle(line: String) {
        let lower = line.lowercased()

        if lower.contains("displaying as banner")
            || lower.contains("setting visible banner")
            || (lower.contains("addorupdate") && lower.contains("present: true")) {
            NSLog("MagOff: NC log → banner present")
            DispatchQueue.main.async { [weak self] in self?.onBanner?() }
            return
        }

        // Explicit user actions (clear from NC, delete, etc.)
        if lower.contains("fromuseraction: true")
            || lower.contains("alert/banner deleted")
            || lower.contains("removed history notification") {
            NSLog("MagOff: NC log → user handled")
            DispatchQueue.main.async { [weak self] in self?.onBannerHandled?() }
            return
        }

        // Auto-timeout (banner slid away unread).
        // Do NOT match "Dismissing banner in 5.000000s" — that is the schedule
        // line posted when the banner first appears, not the actual dismiss.
        if lower.contains("clearing banner after expiration")
            || lower.contains("dismissing ") && !lower.contains("dismissing banner in") {
            NSLog("MagOff: NC log → banner expired")
            DispatchQueue.main.async { [weak self] in self?.onBannerExpired?() }
        }
    }
}
