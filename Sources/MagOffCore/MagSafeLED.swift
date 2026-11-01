import Foundation

/// MagSafe LED control via undocumented Apple Silicon SMC key `ACLC`.
///
/// Visible colors are effectively **green** and **amber (orange)**, plus **off**.
/// There is no red/blue/white. Firmware also accepts a few amber blink patterns.
public enum MagSafeLED {
    public static let key = "ACLC"

    public enum Color: UInt8, CaseIterable, CustomStringConvertible {
        case system = 0
        case off = 1
        case green = 3
        case amber = 4
        /// Firmware slow amber blink (not used as a sticky “mode”).
        case amberBlinkSlow = 6
        /// Firmware fast amber blink.
        case amberBlinkFast = 7
        /// Blink amber once, then off.
        case amberBlinkThenOff = 25

        public var description: String {
            switch self {
            case .system: return "system"
            case .off: return "off"
            case .green: return "green"
            case .amber: return "amber"
            case .amberBlinkSlow: return "amber-blink-slow"
            case .amberBlinkFast: return "amber-blink-fast"
            case .amberBlinkThenOff: return "amber-blink-off"
            }
        }

        public var statusTitle: String {
            switch self {
            case .system: return "系统控制中"
            case .off: return "已关闭"
            case .green: return "绿灯"
            case .amber: return "橙灯"
            case .amberBlinkSlow: return "橙灯慢闪"
            case .amberBlinkFast: return "橙灯快闪"
            case .amberBlinkThenOff: return "橙灯闪后关"
            }
        }

        /// Sticky modes shown in the menu (excludes one-shot blink codes).
        public var isStickyMode: Bool {
            switch self {
            case .system, .off, .green, .amber: return true
            default: return false
            }
        }

        public var mode: MagOffPaths.Mode? {
            switch self {
            case .system: return .system
            case .off: return .off
            case .green: return .green
            case .amber: return .amber
            default: return nil
            }
        }
    }

    public static func set(_ color: Color) throws {
        try SMC.writeByte(key, color.rawValue)
    }

    public static func set(_ color: Color, using connection: SMC.Connection) throws {
        try connection.writeByte(key, color.rawValue)
    }

    /// Reads the live MagSafe LED mode from SMC (no root required on this Mac).
    public static func current() -> Color? {
        guard let byte = try? SMC.readByte(key) else { return nil }
        return Color(rawValue: byte)
    }

    public static func isSupported() -> Bool {
        (try? SMC.keyInfo(key)) != nil
    }
}
