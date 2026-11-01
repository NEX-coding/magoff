import Foundation
import IOKit

/// Minimal AppleSMC client for reading key info and writing a single-byte key.
/// Layout mirrors the kernel SMCParamStruct (80 bytes).
public enum SMC {
    public enum SMCError: Error, CustomStringConvertible {
        case serviceNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case smcResult(UInt8)
        case unexpectedLayout(Int)
        case invalidKey(String)

        public var description: String {
            switch self {
            case .serviceNotFound:
                return "找不到 AppleSMC 服务"
            case .openFailed(let kr):
                return "打开 AppleSMC 失败 (\(kr))"
            case .callFailed(let kr):
                return "调用 AppleSMC 失败 (\(kr))"
            case .smcResult(let r):
                return r == 0x84
                    ? "此 Mac 可能不支持 MagSafe 指示灯控制"
                    : "SMC 返回错误 \(r)"
            case .unexpectedLayout(let size):
                return "SMCParamStruct 大小异常 \(size)"
            case .invalidKey(let key):
                return "SMC key '\(key)' 必须是 4 个字符"
            }
        }
    }

    struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyInfo: UInt8 = 9

    public static func fourCC(_ code: String) throws -> UInt32 {
        guard code.utf8.count == 4 else { throw SMCError.invalidKey(code) }
        return code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func withConnection<T>(_ body: (io_connect_t) throws -> T) throws -> T {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else {
            throw SMCError.unexpectedLayout(MemoryLayout<SMCParamStruct>.stride)
        }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
        defer { IOServiceClose(connection) }
        return try body(connection)
    }

    private static func call(_ connection: io_connect_t, _ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        guard output.result == 0 else { throw SMCError.smcResult(output.result) }
        return output
    }

    public static func keyInfo(_ key: String) throws -> (size: UInt32, type: String) {
        try withConnection { connection in
            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCGetKeyInfo
            let reply = try call(connection, request)
            let t = reply.keyInfo.dataType
            let type = String(
                bytes: [
                    UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff),
                    UInt8(t >> 8 & 0xff), UInt8(t & 0xff),
                ],
                encoding: .ascii
            ) ?? "????"
            return (reply.keyInfo.dataSize, type)
        }
    }

    public static func readBytes(_ key: String) throws -> [UInt8] {
        try withConnection { connection in
            var info = SMCParamStruct()
            info.key = try fourCC(key)
            info.data8 = kSMCGetKeyInfo
            let infoReply = try call(connection, info)

            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCReadKey
            request.keyInfo.dataSize = infoReply.keyInfo.dataSize
            let reply = try call(connection, request)
            return withUnsafeBytes(of: reply.bytes) {
                Array($0.prefix(Int(infoReply.keyInfo.dataSize)))
            }
        }
    }

    public static func readByte(_ key: String) throws -> UInt8 {
        try readBytes(key).first ?? 0
    }

    /// Writes a single-byte SMC key. Requires root for MagSafe LED key.
    public static func writeByte(_ key: String, _ value: UInt8) throws {
        try withConnection { connection in
            var info = SMCParamStruct()
            info.key = try fourCC(key)
            info.data8 = kSMCGetKeyInfo
            let infoReply = try call(connection, info)

            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCWriteKey
            request.keyInfo.dataSize = infoReply.keyInfo.dataSize
            request.bytes.0 = value
            _ = try call(connection, request)
        }
    }

    /// Persistent SMC connection for the helper daemon.
    public final class Connection {
        private var connection: io_connect_t = 0
        private let service: io_service_t
        private var keyInfoCache: [String: UInt32] = [:]

        public init() throws {
            guard MemoryLayout<SMCParamStruct>.stride == 80 else {
                throw SMCError.unexpectedLayout(MemoryLayout<SMCParamStruct>.stride)
            }
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("AppleSMC")
            )
            guard service != 0 else { throw SMCError.serviceNotFound }
            self.service = service
            var conn: io_connect_t = 0
            let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
            guard kr == KERN_SUCCESS else {
                IOObjectRelease(service)
                throw SMCError.openFailed(kr)
            }
            self.connection = conn
        }

        deinit {
            if connection != 0 { IOServiceClose(connection) }
            IOObjectRelease(service)
        }

        public func writeByte(_ key: String, _ value: UInt8) throws {
            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCWriteKey
            request.keyInfo.dataSize = try keyInfoSize(key)
            request.bytes.0 = value
            _ = try call(request)
        }

        private func keyInfoSize(_ key: String) throws -> UInt32 {
            if let size = keyInfoCache[key] { return size }
            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCGetKeyInfo
            let reply = try call(request)
            keyInfoCache[key] = reply.keyInfo.dataSize
            return reply.keyInfo.dataSize
        }

        private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
            var input = input
            var output = SMCParamStruct()
            var outputSize = MemoryLayout<SMCParamStruct>.stride
            let kr = IOConnectCallStructMethod(
                connection,
                kSMCHandleYPCEvent,
                &input,
                MemoryLayout<SMCParamStruct>.stride,
                &output,
                &outputSize
            )
            guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
            guard output.result == 0 else { throw SMCError.smcResult(output.result) }
            return output
        }
    }
}
