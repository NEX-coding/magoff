import Foundation
import SQLite3

/// Detects ChatGPT / Codex reply completion without relying on Notification Center.
///
/// 1. Codex agent: FSEvents on `~/.codex/sessions/**/*.jsonl` for `task_complete`
/// 2. ChatGPT desktop chats: poll `~/.codex/sqlite/codex.db` `local_thread_catalog.source_updated_at`
final class CodexSessionWatcher {
    private var stream: FSEventStreamRef?
    private var fileOffsets: [String: UInt64] = [:]
    private var primed = false
    private var pollTimer: DispatchSourceTimer?
    private var lastCatalogUpdatedAt: Double = 0
    private let sessionsRoot: URL
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.nex.magoff.codex-watcher")
    var onTaskComplete: (() -> Void)?

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.sessionsRoot = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.dbPath = homeDirectory
            .appendingPathComponent(".codex/sqlite/codex.db")
            .path
    }

    private(set) var isRunning = false

    func start() {
        stop()
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        primeOffsets()
        lastCatalogUpdatedAt = readMaxCatalogUpdatedAt() ?? 0
        primed = true
        isRunning = true
        startSessionFSEvents()
        startCatalogPoll()
        NSLog(
            "MagOff: GPT watcher started (sessions + catalog max=%.3f)",
            lastCatalogUpdatedAt
        )
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        pollTimer?.cancel()
        pollTimer = nil
        fileOffsets.removeAll()
        primed = false
        isRunning = false
    }

    // MARK: - ChatGPT catalog poll (普通 ChatGPT 对话)

    private func startCatalogPoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.8, repeating: 0.8)
        timer.setEventHandler { [weak self] in
            self?.pollCatalog()
        }
        pollTimer = timer
        timer.resume()
    }

    private func pollCatalog() {
        guard primed else { return }
        guard let current = readMaxCatalogUpdatedAt() else { return }
        // Ignore tiny floating noise; require a real bump.
        if current > lastCatalogUpdatedAt + 0.01 {
            let previous = lastCatalogUpdatedAt
            lastCatalogUpdatedAt = current
            // First observed bump after start is real activity.
            if previous > 0 {
                NSLog("MagOff: ChatGPT/Codex catalog updated %.3f → %.3f", previous, current)
                DispatchQueue.main.async { [weak self] in
                    self?.onTaskComplete?()
                }
            }
        } else if current > lastCatalogUpdatedAt {
            lastCatalogUpdatedAt = current
        }
    }

    private func readMaxCatalogUpdatedAt() -> Double? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        // Read-only + URI so WAL readers don't fight the app.
        let uri = "file:\(dbPath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else { return nil }
        defer { sqlite3_close(db) }

        // Prefer ChatGPT desktop chats; also include local/vscode Codex threads.
        let sql = """
        SELECT MAX(source_updated_at) FROM local_thread_catalog
        WHERE source_kind IN ('chatgpt','vscode','openai')
           OR host_id LIKE 'chatgpt:%'
           OR host_id = 'local';
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    // MARK: - Codex sessions FSEvents

    private func startSessionFSEvents() {
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [sessionsRoot.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<CodexSessionWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                watcher.queue.async {
                    for i in 0..<numEvents where i < paths.count {
                        watcher.handlePathChange(paths[i])
                    }
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else {
            NSLog("MagOff: failed to create FSEventStream for Codex sessions")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func primeOffsets() {
        fileOffsets.removeAll()
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            fileOffsets[url.path] = size
        }
    }

    private func handlePathChange(_ path: String) {
        guard primed else { return }
        guard path.hasSuffix(".jsonl"), !path.hasSuffix(".jsonl.zst") else { return }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            fileOffsets.removeValue(forKey: path)
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let previous = fileOffsets[path] ?? 0

        var offset = previous
        if fileOffsets[path] == nil {
            offset = size > 256_000 ? size : 0
        } else if size < previous {
            offset = 0
        }

        defer { fileOffsets[path] = size }
        guard size > offset else { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            if containsTaskComplete(in: text) {
                NSLog("MagOff: Codex task_complete in %@", (path as NSString).lastPathComponent)
                DispatchQueue.main.async { [weak self] in
                    self?.onTaskComplete?()
                }
            }
        } catch {
            NSLog("MagOff: Codex watch read failed: %@", String(describing: error))
        }
    }

    private func containsTaskComplete(in chunk: String) -> Bool {
        for line in chunk.split(whereSeparator: \.isNewline) {
            guard line.contains("task_complete") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard (obj["type"] as? String) == "event_msg" else { continue }
            if let payload = obj["payload"] as? [String: Any],
               (payload["type"] as? String) == "task_complete" {
                return true
            }
        }
        return false
    }
}
