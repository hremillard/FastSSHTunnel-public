import Foundation
import Testing
@testable import FastSSHTunnel

struct SSHDeviceTests {
    @Test func existingProfilesDecodeAndDeviceSettingsRoundTrip() throws {
        let original = TunnelProfile()
        let encoded = try JSONEncoder().encode(original)
        var legacyFields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyFields.removeValue(forKey: "sshDevice")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyFields)
        let restored = try JSONDecoder().decode(TunnelProfile.self, from: legacyData)
        #expect(restored == original)
        #expect(restored.sshDevice == nil)

        var updated = restored
        updated.sshDevice = SSHDevice(host: "router.internal", username: "admin", port: 2222)
        let saved = try JSONEncoder().encode(updated)
        #expect(try JSONDecoder().decode(TunnelProfile.self, from: saved) == updated)
    }

    @Test func effectiveSSHConfigurationUsesSOCKSAndSeparateDeviceCredentials() throws {
        let device = SSHDevice(host: "router.internal", username: " \u{FEFF}device-admin\u{200B}\n", port: 2222)
        let arguments = try SSHDeviceConfiguration.arguments(for: device, socksPort: 1087)
        let result = try run("/usr/bin/ssh", arguments: ["-G"] + arguments)
        #expect(result.status == 0)
        let lines = result.output.components(separatedBy: "\n")
        #expect(lines.contains("hostname router.internal"))
        #expect(lines.contains("user device-admin"))
        #expect(lines.contains("port 2222"))
        #expect(lines.contains("batchmode no"))
        #expect(lines.contains("stricthostkeychecking ask"))
        #expect(lines.contains("controlmaster false"))
        #expect(!lines.contains(where: { $0.hasPrefix("controlpath ") }))
        #expect(lines.contains("proxycommand /usr/bin/nc -X 5 -x 127.0.0.1:1087 '%h' '%p'"))
    }

    @Test func invalidHostsAndPortsAreRejectedBeforeOpeningTerminal() throws {
        for host in ["", "-proxy", "host;touch /tmp/no", "$(id)", "host\nname", "host%h", "[::1]"] {
            #expect(throws: SSHDeviceError.self) {
                try SSHDeviceConfiguration.arguments(for: SSHDevice(host: host, username: "admin"), socksPort: 1080)
            }
        }
        for port in [0, -1, 65536] {
            #expect(throws: SSHDeviceError.self) {
                try SSHDeviceConfiguration.arguments(for: SSHDevice(host: "router.internal", username: "admin", port: port), socksPort: 1080)
            }
            #expect(throws: SSHDeviceError.self) {
                try SSHDeviceConfiguration.arguments(for: SSHDevice(host: "router.internal", username: "admin"), socksPort: port)
            }
        }
        let ipv6 = try SSHDeviceConfiguration.arguments(for: SSHDevice(host: "fd00::10", username: "admin"), socksPort: 1080)
        #expect(ipv6.last == "fd00::10")
    }

    @Test func rejectsMissingUsernamesAndEmbeddedControlCharacters() {
        for username in ["", " \u{FEFF}\u{200B}\n", "device\u{200B}admin", "device\u{0000}admin"] {
            #expect(throws: SSHDeviceError.self) {
                try SSHDeviceConfiguration.arguments(for: SSHDevice(host: "router.internal", username: username), socksPort: 1080)
            }
        }
    }

    @Test func terminalCommandPreservesLiteralArgumentsWithoutShellExpansion() throws {
        let username = "user'\"; $(printf INJECTED) `$HOME` \\"
        let device = SSHDevice(host: "router.internal", username: username)
        let arguments = try SSHDeviceConfiguration.arguments(for: device, socksPort: 1080)
        let script = try SSHDeviceConfiguration.terminalScript(for: device, socksPort: 1080)
        // Substitute a harmless argument printer for SSH; exercise the actual
        // generated command through the same shell Terminal will use.
        let sshCommand = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("exec ") })
        let printCommand = sshCommand.replacingOccurrences(of: "exec /usr/bin/ssh ", with: "printf '%s\\n' ")
        let result = try run("/bin/sh", arguments: ["-c", printCommand])
        #expect(result.status == 0)
        #expect(result.output == arguments.joined(separator: "\n") + "\n")
    }

    private func run(_ executable: String, arguments: [String]) throws -> (output: String, status: Int32) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}
