import Foundation
import Testing
@testable import FastSSHTunnel

struct DebugLogTests {
    @Test @MainActor func retainsRecentEventsAndNeverStoresRawSSHOutput() throws {
        let suite = "DebugLogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DebugLog(defaults: defaults)
        let sensitiveOutput = "ssh: connect to host secret.example port 22: Connection refused; password hunter2"
        log.record(.sshDiagnostic(.classify(sensitiveOutput)))
        let exported = log.contents()
        #expect(exported.contains("connection refused"))
        #expect(!exported.contains("secret.example"))
        #expect(!exported.contains("hunter2"))
        #expect(DebugLog.SSHDiagnostic.classify("unexpected secret.example") == .other)
        for _ in 0..<500 { log.record(.connected) }
        let retained = log.contents()
        #expect(!retained.contains("connection refused"))
        #expect(retained.components(separatedBy: "SSH tunnel connected").count - 1 == 500)
    }
}
