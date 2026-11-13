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
        let broker = try SSHAskpassBroker(password: secret)
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
        let broker = try SSHAskpassBroker(password: "test-only-secret")
        defer { broker.stop() }
        broker.authorize(processID: ProcessInfo.processInfo.processIdentifier)
        for prompt in ["Are you sure you want to continue connecting (yes/no)?", "The authenticity of host 'password:", "Enter passphrase for key:", "Verification code:"] {
            let result = try runHelper(broker, prompt: prompt)
            #expect(result.status != 0)
            #expect(result.output.isEmpty)
        }
        var invalidEnvironment = broker.environment
        invalidEnvironment["FASTSSH_ASKPASS_TOKEN"] = "wrong-token"
        #expect(try runHelper(broker, prompt: "Password:", environment: invalidEnvironment).output.isEmpty)
    }

    @Test func askpassRejectsARequestFromAnotherSSHProcess() throws {
        let broker = try SSHAskpassBroker(password: "test-only-secret")
        defer { broker.stop() }
        broker.authorize(processID: ProcessInfo.processInfo.processIdentifier + 1)
        #expect(try runHelper(broker, prompt: "Password:").output.isEmpty)
        broker.authorize(processID: ProcessInfo.processInfo.processIdentifier)
        #expect(try runHelper(broker, prompt: "Password:").output == "test-only-secret\n")
    }

    @Test func askpassReturnsOnlyTheApprovedFingerprintOrDeclines() async throws {
        let fingerprint = "SHA256:" + Data(repeating: 0, count: 32).base64EncodedString().dropLast()
        let prompt = """
        The authenticity of host 'server.example (192.0.2.1)' can't be established.
        ED25519 key fingerprint is: \(fingerprint)
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """ + " "
        for approves in [true, false] {
            let broker = try SSHAskpassBroker(password: approves ? "" : "test-only-secret") { key in
                #expect(key.host == "server.example (192.0.2.1)")
                #expect(key.fingerprint == fingerprint)
                return approves
            }
            defer { broker.stop() }
            broker.authorize(processID: ProcessInfo.processInfo.processIdentifier)
            let result = try await Task.detached { try runHelper(broker, prompt: prompt) }.value
            #expect(result.status == 0)
            #expect(result.output == (approves ? fingerprint : "no") + "\n")
            if approves {
                #expect(try runHelper(broker, prompt: "Password:").output.isEmpty)
            }
        }
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
        #expect(args.contains("StrictHostKeyChecking=ask"))
        #expect(args.contains("127.0.0.1:8080"))
        #expect(Array(args.suffix(4)) == ["-l", "test-user", "--", "-not-an-option"])
        let keyArgs = SSHConfiguration.arguments(for: profile, usesPassword: false, readyMarker: "TEST_READY")
        #expect(keyArgs.contains("BatchMode=no"))
        #expect(keyArgs.contains("PasswordAuthentication=no"))
        #expect(keyArgs.contains("KbdInteractiveAuthentication=no"))
        #expect(keyArgs.contains("NumberOfPasswordPrompts=0"))
        #expect(!keyArgs.contains("PreferredAuthentications=password,keyboard-interactive"))
    }

    @Test func openSSHAsksBeforeTrustingNewKeysAndKeepsTheTunnelInTheForeground() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("fastssh-test-\(UUID().uuidString).config")
        defer { try? FileManager.default.removeItem(at: config) }
        try """
        ControlMaster auto
        ControlPath ~/.ssh/unused-fastssh-test-socket
        ControlPersist yes
        ForkAfterAuthentication yes
        """.write(to: config, atomically: true, encoding: .utf8)
        var profile = TunnelProfile()
        profile.host = "hostkey-test.invalid"
        profile.username = "test-user"
        for usesPassword in [false, true] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // -G prints the effective settings without connecting to a server.
            process.arguments = ["-G", "-F", config.path] + SSHConfiguration.arguments(
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
            #expect(lines.contains("stricthostkeychecking ask"))
            #expect(lines.contains("verifyhostkeydns false"))
            #expect(lines.contains("batchmode no"))
            #expect(lines.contains("forkafterauthentication no"))
            #expect(!lines.contains(where: { $0.hasPrefix("controlpath ") }))
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

    private func runHelper(_ broker: SSHAskpassBroker, prompt: String, environment: [String: String]? = nil) throws -> (output: String, status: Int32) {
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
