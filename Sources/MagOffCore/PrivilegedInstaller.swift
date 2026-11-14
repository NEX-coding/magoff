import Foundation

/// Installs / updates / removes the root LaunchDaemon via an admin shell script.
public enum PrivilegedInstaller {
    public enum InstallError: Error, CustomStringConvertible {
        case helperBinaryMissing
        case authorizationCancelled
        case scriptFailed(String)

        public var description: String {
            switch self {
            case .helperBinaryMissing:
                return "找不到 magoff-helper，请先运行 scripts/build.sh"
            case .authorizationCancelled:
                return "已取消管理员授权"
            case .scriptFailed(let message):
                return message
            }
        }
    }

    public static func bundledHelperURL() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: MagOffPaths.helperBinaryName) {
            return url
        }
        let inHelpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(MagOffPaths.helperBinaryName)")
        if FileManager.default.isExecutableFile(atPath: inHelpers.path) {
            return inHelpers
        }
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(MagOffPaths.helperBinaryName)
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    public static var isHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: MagOffPaths.helperInstallPath)
            && FileManager.default.fileExists(atPath: MagOffPaths.launchDaemonPlist)
    }

    /// First-time (or repair) install: copies helper + LaunchDaemon. Requires admin **once**.
    public static func setMode(_ mode: MagOffPaths.Mode, helperURL: URL? = nil) throws {
        try installOrUpdate(mode: mode, helperURL: helperURL)
    }

    /// Change LED mode without admin.
    /// Writes `mode` for persistence, then nudges the helper via polled `cmd` (`set:`).
    /// (Directory FSEvents alone are unreliable for in-place mode writes.)
    public static func writeModeOnly(_ mode: MagOffPaths.Mode) throws {
        let canMode = MagOffPaths.isModeFileWritable
        let canCmd = FileManager.default.isWritableFile(atPath: MagOffPaths.cmdFile)

        if !canMode && !canCmd {
            try relaxSupportFilePermissions()
        }

        if MagOffPaths.isModeFileWritable {
            try MagOffPaths.writeMode(mode)
        }

        if FileManager.default.isWritableFile(atPath: MagOffPaths.cmdFile) {
            try MagOffPaths.requestSetMode(mode)
            return
        }

        // Last resort: mode file only (helper FSEvents / next reassert).
        if MagOffPaths.isModeFileWritable {
            return
        }
        throw MagOffPaths.FlashError.writeFailed
    }

    /// One-shot admin fix so mode/cmd are user-writable (666).
    public static func relaxSupportFilePermissions() throws {
        let script = """
        set -euo pipefail
        mkdir -p '\(MagOffPaths.supportDir)'
        /usr/bin/touch '\(MagOffPaths.modeFile)'
        /usr/bin/touch '\(MagOffPaths.cmdFile)'
        /usr/sbin/chown root:wheel '\(MagOffPaths.modeFile)' '\(MagOffPaths.cmdFile)'
        /bin/chmod 666 '\(MagOffPaths.modeFile)' '\(MagOffPaths.cmdFile)'
        """
        try runAdminShell(script)
    }

    /// Ensures the world-writable flash command file exists (admin once).
    public static func ensureCommandFile() throws {
        try relaxSupportFilePermissions()
    }

    public static func uninstall() throws {
        let script = """
        set -euo pipefail
        /bin/launchctl bootout system/\(MagOffPaths.helperLabel) >/dev/null 2>&1 || true
        # Best-effort LED restore via the helper if it still launches.
        if [ -x '\(MagOffPaths.helperInstallPath)' ]; then
          '\(MagOffPaths.helperInstallPath)' --reset >/dev/null 2>&1 || true
        fi
        # Clean old PrivilegedHelperTools install from earlier versions.
        /bin/rm -f /Library/PrivilegedHelperTools/\(MagOffPaths.helperLabel)
        /bin/rm -f '\(MagOffPaths.launchDaemonPlist)'
        /bin/rm -f '\(MagOffPaths.helperInstallPath)'
        /bin/rm -f '\(MagOffPaths.modeFile)'
        /bin/rm -f '\(MagOffPaths.cmdFile)'
        /bin/rmdir '\(MagOffPaths.supportDir)' >/dev/null 2>&1 || true
        """
        try runAdminShell(script)
    }

    private static func installOrUpdate(mode: MagOffPaths.Mode, helperURL: URL?) throws {
        let helper = try resolveHelper(helperURL)
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magoff-\(UUID().uuidString).plist")
        try launchDaemonPlistContents().write(to: plistURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plistURL) }

        // Re-sign AFTER copy — ad-hoc signatures break when the binary is moved,
        // which caused SIGKILL (Code Signature Invalid) / exit 137.
        let script = """
        set -euo pipefail
        mkdir -p '\(MagOffPaths.supportDir)'
        /bin/cp -f '\(helper.path)' '\(MagOffPaths.helperInstallPath)'
        /usr/sbin/chown root:wheel '\(MagOffPaths.helperInstallPath)'
        /bin/chmod 755 '\(MagOffPaths.helperInstallPath)'
        /usr/bin/codesign --force --sign - --identifier '\(MagOffPaths.helperLabel)' '\(MagOffPaths.helperInstallPath)'
        /usr/bin/printf '%s' '\(mode.rawValue)' > '\(MagOffPaths.modeFile)'
        /usr/sbin/chown root:wheel '\(MagOffPaths.modeFile)'
        /bin/chmod 666 '\(MagOffPaths.modeFile)'
        /usr/bin/touch '\(MagOffPaths.cmdFile)'
        /usr/sbin/chown root:wheel '\(MagOffPaths.cmdFile)'
        /bin/chmod 666 '\(MagOffPaths.cmdFile)'
        /bin/cp -f '\(plistURL.path)' '\(MagOffPaths.launchDaemonPlist)'
        /usr/sbin/chown root:wheel '\(MagOffPaths.launchDaemonPlist)'
        /bin/chmod 644 '\(MagOffPaths.launchDaemonPlist)'
        # Remove legacy path if present.
        /bin/rm -f /Library/PrivilegedHelperTools/\(MagOffPaths.helperLabel)
        /bin/launchctl bootout system/\(MagOffPaths.helperLabel) >/dev/null 2>&1 || true
        /bin/launchctl bootout system '\(MagOffPaths.launchDaemonPlist)' >/dev/null 2>&1 || true
        /bin/sleep 0.4
        if /bin/launchctl print system/\(MagOffPaths.helperLabel) >/dev/null 2>&1; then
          /bin/launchctl kickstart -k system/\(MagOffPaths.helperLabel)
        else
          /bin/launchctl bootstrap system '\(MagOffPaths.launchDaemonPlist)'
          /bin/launchctl enable system/\(MagOffPaths.helperLabel) >/dev/null 2>&1 || true
          /bin/launchctl kickstart -k system/\(MagOffPaths.helperLabel) >/dev/null 2>&1 || true
        fi
        # Daemon reads mode file on start — do not exec helper --set (codesign/taskgated race).
        """
        try runAdminShell(script)
    }

    private static func resolveHelper(_ helperURL: URL?) throws -> URL {
        if let helperURL { return helperURL }
        guard let bundled = bundledHelperURL() else { throw InstallError.helperBinaryMissing }
        return bundled
    }

    private static func launchDaemonPlistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>Label</key>
        	<string>\(MagOffPaths.helperLabel)</string>
        	<key>ProgramArguments</key>
        	<array>
        		<string>\(MagOffPaths.helperInstallPath)</string>
        	</array>
        	<key>RunAtLoad</key>
        	<true/>
        	<key>KeepAlive</key>
        	<true/>
        	<key>ProcessType</key>
        	<string>Background</string>
        </dict>
        </plist>
        """
    }

    private static func runAdminShell(_ script: String) throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("magoff-install-\(UUID().uuidString).sh")
        try script.write(to: temp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temp.path
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let quoted = temp.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/bin/bash \\\"\(quoted)\\\"\" with administrator privileges",
        ]
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lowered = err.lowercased()
            if lowered.contains("user canceled")
                || lowered.contains("(-128)")
                || lowered.contains("cancelled") {
                throw InstallError.authorizationCancelled
            }
            throw InstallError.scriptFailed(err.isEmpty ? "安装失败 (exit \(process.terminationStatus))" : err)
        }
    }
}
