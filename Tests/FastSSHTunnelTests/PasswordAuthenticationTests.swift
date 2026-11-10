import Foundation
import Testing
@testable import FastSSHTunnel

struct PasswordAuthenticationTests {
    @Test func connectionRequiresPasswordOrSelectedKey() {
        #expect(!SSHConfiguration.hasAuthentication(password: "", identityFile: ""))
        #expect(!SSHConfiguration.hasAuthentication(password: "", identityFile: "  \n"))
        #expect(SSHConfiguration.hasAuthentication(password: "secret", identityFile: ""))
        #expect(SSHConfiguration.hasAuthentication(password: "", identityFile: "/tmp/id_ed25519"))
        #expect(SSHConfiguration.hasAuthentication(password: "secret", identityFile: "/tmp/id_ed25519"))
    }

    @Test func askpassDeliversPasswordWithoutPersistingIt() throws {
        let secret = "test-only-'$`\\-密碼"
        let broker = try SSHPasswordBroker(password: secret)
        defer { broker.stop() }
        broker.authorize(processID: ProcessInfo.processInfo.processIdentifier)
        #expect(!broker.environment.values.contains(where: { $0.contains(secret) }))
        #expect(try !String(contentsOf: broker.helperURL).contains(secret))
        #expect(try runHelper(broker, prompt: "tester@localhost's password: ").output == secret + "\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: broker.directory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let directory = broker.directory
        broker.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func askpassRejectsOtherChallengesAndWrongTokens() throws {
        let broker = try SSHPasswordBroker(password: "test-only-secret")
        defer { broker.stop() }
        broker.authorize(processID: ProcessInfo.processInfo.processIdentifier)
        for prompt in ["Are you sure you want to continue connecting (yes/no)?", "Enter passphrase for key:", "Verification code:"] {
            let result = try runHelper(broker, prompt: prompt)
            #expect(result.status != 0)
            #expect(result.output.isEmpty)
        }
        var invalidEnvironment = broker.environment
        invalidEnvironment["FASTSSH_ASKPASS_TOKEN"] = "wrong-token"
        #expect(try runHelper(broker, prompt: "Password:", environment: invalidEnvironment).output.isEmpty)
    }

    @Test func askpassRejectsARequestFromAnotherSSHProcess() throws {
        let broker = try SSHPasswordBroker(password: "test-only-secret")
        defer { broker.stop() }
        broker.authorize(processID: ProcessInfo.processInfo.processIdentifier + 1)
        #expect(try runHelper(broker, prompt: "Password:").output.isEmpty)
        broker.authorize(processID: ProcessInfo.processInfo.processIdentifier)
        #expect(try runHelper(broker, prompt: "Password:").output == "test-only-secret\n")
    }

    @Test func passwordArgumentsAndDestinationAreUnambiguous() {
        var profile = TunnelProfile()
        profile.host = "-not-an-option"
        profile.username = "test-user"
        profile.sshPort = 2222
        profile.socksPort = 8080
        let args = SSHConfiguration.arguments(for: profile, usesPassword: true, readyMarker: "TEST_READY")
        #expect(args.contains("BatchMode=no"))
        #expect(args.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(args.contains("StrictHostKeyChecking=accept-new"))
        #expect(args.contains("127.0.0.1:8080"))
        #expect(Array(args.suffix(4)) == ["-l", "test-user", "--", "-not-an-option"])
        let keyArgs = SSHConfiguration.arguments(for: profile, usesPassword: false, readyMarker: "TEST_READY")
        #expect(keyArgs.contains("BatchMode=yes"))
        #expect(!keyArgs.contains("PreferredAuthentications=password,keyboard-interactive"))
    }

    @Test func openSSHUsesAcceptNewForBothAuthenticationMethods() throws {
        var profile = TunnelProfile()
        profile.host = "hostkey-test.invalid"
        profile.username = "test-user"
        for usesPassword in [false, true] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // -G only prints effective configuration. -F avoids user-config
            // Match/ProxyCommand hooks; no server or known_hosts is accessed.
            process.arguments = ["-G", "-F", "/dev/null"] + SSHConfiguration.arguments(
                for: profile, usesPassword: usesPassword, readyMarker: "TEST_READY"
            )
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            #expect(lines.contains("stricthostkeychecking accept-new"))
        }
    }

    @Test func profilesNeverEncodePasswordsAndLegacyProfilesStillDecode() throws {
        let profile = TunnelProfile()
        let encoded = try JSONEncoder().encode(profile)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["password"] == nil)
        #expect(fields["rememberPassword"] == nil)
        #expect(try JSONDecoder().decode(TunnelProfile.self, from: encoded) == profile)
        var otherDestination = profile
        otherDestination.host = "other.example.com"
        #expect(PasswordIdentity(profile) != PasswordIdentity(otherDestination))
    }

    private func runHelper(_ broker: SSHPasswordBroker, prompt: String, environment: [String: String]? = nil) throws -> (output: String, status: Int32) {
        let process = Process()
        let output = Pipe()
        process.executableURL = broker.helperURL
        process.arguments = [prompt]
        process.environment = ProcessInfo.processInfo.environment.merging(environment ?? broker.environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}
