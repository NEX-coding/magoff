import Foundation

public enum MagOffPaths {
    public static let bundleID = "com.nex.magoff"
    public static let helperLabel = "com.nex.magoff.helper"
    public static let helperBinaryName = "magoff-helper"

    public static let supportDir = "/Library/Application Support/MagOff"
    public static let modeFile = supportDir + "/mode"
    /// World-writable command file; app writes commands, helper consumes them.
    public static let cmdFile = supportDir + "/cmd"
    public static let helperInstallPath = supportDir + "/magoff-helper"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(helperLabel).plist"

    public enum Mode: String {
        case off
        case system
        case green
        case amber

        public var led: MagSafeLED.Color {
            switch self {
            case .off: return .off
            case .system: return .system
            case .green: return .green
            case .amber: return .amber
            }
        }

        public static func load() -> Mode {
            guard let raw = try? String(contentsOfFile: modeFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let mode = Mode(rawValue: raw)
            else {
                return .system
            }
            return mode
        }
    }

    public enum Command: String {
        /// ~10s green/amber flash, then re-apply configured mode.
        case flash
        /// Leave unread-amber hold and re-apply configured mode.
        case restore
        /// Same as flash (compat).
        case pulse
        /// Stop blinking and keep amber until `restore` (optional unread hint).
        case hold
    }

    public static func requestFlash() throws {
        try writeCommand(.flash)
    }

    public static func requestRestore() throws {
        try writeCommand(.restore)
    }

    public static func requestPulse() throws {
        try writeCommand(.pulse)
    }

    public static func requestHoldAmber() throws {
        try writeCommand(.hold)
    }

    /// User-writable mode switch (helper watches this file). No admin needed.
    public static func writeMode(_ mode: Mode) throws {
        guard FileManager.default.fileExists(atPath: modeFile) else {
            throw FlashError.helperNotReady
        }
        try writeUTF8(mode.rawValue, toPath: modeFile)
    }

    /// Ask running helper (root) to change mode via the world-writable cmd file.
    public static func requestSetMode(_ mode: Mode) throws {
        guard FileManager.default.fileExists(atPath: cmdFile) else {
            throw FlashError.helperNotReady
        }
        try writeUTF8("set:\(mode.rawValue)", toPath: cmdFile)
    }

    public static var isModeFileWritable: Bool {
        FileManager.default.isWritableFile(atPath: modeFile)
    }

    private static func writeCommand(_ command: Command) throws {
        guard FileManager.default.fileExists(atPath: cmdFile) else {
            throw FlashError.helperNotReady
        }
        try writeUTF8(command.rawValue, toPath: cmdFile)
    }

    /// Must NOT use atomically:true — temp file in root-owned dir fails for user.
    private static func writeUTF8(_ text: String, toPath path: String) throws {
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { throw FlashError.writeFailed }
        defer { close(fd) }
        let data = Array(text.utf8)
        let written = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, data.count)
        }
        guard written == data.count else { throw FlashError.writeFailed }
        fsync(fd)
    }

    public enum FlashError: Error, CustomStringConvertible {
        case helperNotReady
        case writeFailed

        public var description: String {
            switch self {
            case .helperNotReady:
                return "请先选择一个灯光模式，安装后台服务后再试闪灯"
            case .writeFailed:
                return "无法写入（模式/命令文件不可写）。可在菜单重新选一次模式以修复权限。"
            }
        }
    }
}
