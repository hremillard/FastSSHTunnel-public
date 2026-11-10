import Foundation
import Testing
@testable import FastSSHTunnel

struct TunnelProfileTransferTests {
    @Test @MainActor func importingCopiesSettingsWithoutReusingIdentityOrCredentials() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = TunnelProfile(
            name: "Office",
            host: "ssh.example.com",
            username: "admin",
            sshPort: 2222,
            socksPort: 1089,
            identityFile: "/path/to/key",
            startPage: "https://example.com/start",
            sshDevice: SSHDevice(host: "router.internal", username: "operator", port: 2200)
        )
        let source = TunnelStore(previewProfiles: [original, TunnelProfile(socksPort: 1080)])
        source.setPassword("test-only-secret", for: original)
        source.setRememberPassword(true, for: original)
        try original.export(to: url)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("test-only-secret"))

        let destination = TunnelStore(previewProfiles: [])
        try destination.importProfile(from: url)
        let imported = try #require(destination.profiles.first)
        var expected = original
        expected.id = imported.id
        #expect(imported.id != original.id)
        #expect(imported == expected)

        try source.importProfile(from: url)
        let copy = try #require(source.profiles.last)
        expected.id = copy.id
        expected.socksPort = 1081
        #expect(source.profiles.count == 3)
        #expect(source.profiles.first == original)
        #expect(copy.id != original.id)
        #expect(copy == expected)
        #expect(source.credential(for: copy).password.isEmpty)
        #expect(!source.credential(for: copy).remember)
        #expect(source.state(for: copy) == .disconnected)
    }

    @Test @MainActor func importAvoidsConflictsBetweenSOCKSAndRemoteDesktopPorts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = TunnelProfile(
            socksPort: 1080,
            remoteDesktop: RemoteDesktop(isEnabled: true, host: "pc.internal")
        )
        let incoming = TunnelProfile(
            socksPort: 13389,
            remoteDesktop: RemoteDesktop(isEnabled: true, host: "other-pc.internal", remotePort: 3390, localPort: 1080)
        )
        try incoming.export(to: url)
        let store = TunnelStore(previewProfiles: [existing])
        try store.importProfile(from: url)

        let imported = try #require(store.profiles.last)
        #expect(store.profiles.first == existing)
        #expect(imported.socksPort == 1081)
        #expect(imported.remoteDesktop == RemoteDesktop(isEnabled: true, host: "other-pc.internal", remotePort: 3390, localPort: 13390))
    }

    @Test @MainActor func invalidImportLeavesExistingProfilesIntact() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url)

        let original = TunnelProfile()
        let store = TunnelStore(previewProfiles: [original])
        #expect(throws: (any Error).self) { try store.importProfile(from: url) }
        #expect(store.profiles == [original])
    }
}
