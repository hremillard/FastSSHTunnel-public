import Foundation
import Testing
@testable import FastSSHTunnel

struct StaticPortForwardTests {
    @Test func forwardsChosenPortsAlongsideRemoteDesktop() throws {
        var profile = TunnelProfile(host: "ssh.example.com", username: "admin")
        profile.staticPort = StaticPortForward(isEnabled: true, host: " [2001:db8::10] ", remotePort: 5432, localPort: 15432)
        profile.remoteDesktop = RemoteDesktop(isEnabled: true, host: "pc.internal")
        let forward = try #require(profile.enabledStaticPort)
        #expect(forward.validationIssue == nil)
        #expect(forward.forwardingArgument == "127.0.0.1:15432:[2001:db8::10]:5432")
        let arguments = SSHConfiguration.arguments(for: profile, usesPassword: false, readyMarker: "READY")
        #expect(arguments.filter { $0 == "-L" }.count == 2)
        #expect(arguments.contains(forward.forwardingArgument))
        #expect(Set(profile.localPorts) == Set([1080, 13389, 15432]))
        profile.staticPort?.isEnabled = false
        #expect(!SSHConfiguration.arguments(for: profile, usesPassword: false, readyMarker: "READY").contains(forward.forwardingArgument))
    }

    @Test func validatesDestinationAndPorts() {
        for host in ["", "host:80", "host name", "-host", "[host]", "::g"] {
            #expect(StaticPortForward(host: host).validationIssue != nil)
        }
        #expect(StaticPortForward(host: "localhost", remotePort: 0).validationIssue != nil)
        #expect(StaticPortForward(host: "localhost", localPort: 65536).validationIssue != nil)
        #expect(StaticPortForward(host: "localhost", remotePort: 1, localPort: 65535).validationIssue == nil)
    }

    @Test @MainActor func importedForwardAvoidsExistingPortsAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = TunnelProfile(socksPort: 1080, staticPort: StaticPortForward(isEnabled: true, host: "localhost", remotePort: 80, localPort: 8080))
        try original.export(to: url)
        let store = TunnelStore(previewProfiles: [TunnelProfile(socksPort: 8080)])
        try store.importProfile(from: url)
        let imported = try #require(store.profiles.last)
        #expect(imported.staticPort?.localPort == 1024)
        #expect(imported.staticPort?.remotePort == 80)
        #expect(imported.staticPort?.host == "localhost")
    }
}
