import Foundation
import Testing
@testable import FastSSHTunnel

struct TunnelBackupTests {
    @Test func backupEncryptsCredentialsAndRejectsWrongPassphrasesAndTampering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).fastsshbackup")
        defer { try? FileManager.default.removeItem(at: url) }

        let passphrase = "a separate passphrase 密碼"
        let first = TunnelProfile(name: "Private office profile", host: "private-host.example", username: "admin")
        let second = TunnelProfile(
            socksPort: 1081,
            sshDevice: SSHDevice(host: "router.internal"),
            remoteDesktop: RemoteDesktop(isEnabled: true, host: "pc.internal")
        )
        let password = "test-only-SSH-password"
        let backup = TunnelBackup(entries: [
            .init(profile: first, password: password),
            .init(profile: second, password: nil)
        ])
        try backup.write(to: url, passphrase: passphrase)
        let file = try Data(contentsOf: url)
        let text = String(decoding: file, as: UTF8.self)
        #expect(!text.contains(first.name))
        #expect(!text.contains(password))
        #expect(!text.contains(passphrase))

        let restored = try TunnelBackup.read(from: url, passphrase: passphrase)
        #expect(restored.entries.map(\.profile) == [first, second])
        #expect(restored.entries.map(\.password) == [password, nil])
        #expect(throws: BackupError.cannotUnlock) {
            try TunnelBackup.read(from: url, passphrase: "the wrong passphrase")
        }

        var fields = try #require(JSONSerialization.jsonObject(with: file) as? [String: Any])
        let sealed = try #require(fields["sealedData"] as? String)
        var tampered = try #require(Data(base64Encoded: sealed))
        tampered[tampered.startIndex + 12] ^= 1
        fields["sealedData"] = tampered.base64EncodedString()
        try JSONSerialization.data(withJSONObject: fields).write(to: url)
        #expect(throws: BackupError.cannotUnlock) {
            try TunnelBackup.read(from: url, passphrase: passphrase)
        }
    }

    @Test @MainActor func restoreReplacesProfilesAndIsolatesPreviousCredentialsAndState() async throws {
        let original = TunnelProfile(name: "Before restore", host: "host.example", username: "admin")
        let store = TunnelStore(previewProfiles: [original, TunnelProfile(socksPort: 1081)])
        store.setPassword("old-password", for: original)
        store.states[original.id] = .connected

        var restored = original
        restored.name = "From backup"
        restored.socksPort = 2000
        let newProfile = TunnelProfile(socksPort: 2001)
        let backup = TunnelBackup(entries: [
            .init(profile: restored, password: nil),
            .init(profile: newProfile, password: nil)
        ])
        try await store.restore(backup)
        let first = try #require(store.profiles.first)
        #expect(store.profiles.map(\.portableSettings) == [restored, newProfile])
        #expect(first.keychainID != original.keychainID)
        #expect(store.credential(for: first).password.isEmpty)
        #expect(store.state(for: first) == .disconnected)

        try await store.restore(TunnelBackup(entries: []))
        #expect(store.profiles.isEmpty)
    }
}
