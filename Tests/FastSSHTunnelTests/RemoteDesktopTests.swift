import Testing
@testable import FastSSHTunnel

struct RemoteDesktopTests {
    @Test func staticForwardIsOptionalAndUsesLoopback() throws {
        var profile = TunnelProfile(host: "ssh.example.com", username: "admin")
        #expect(!SSHConfiguration.arguments(for: profile, usesPassword: false, readyMarker: "READY").contains("-L"))

        profile.remoteDesktop = RemoteDesktop(host: "pc.internal")
        #expect(!SSHConfiguration.arguments(for: profile, usesPassword: false, readyMarker: "READY").contains("-L"))

        profile.remoteDesktop?.isEnabled = true
        let args = SSHConfiguration.arguments(for: profile, usesPassword: false, readyMarker: "READY")
        let forwardIndex = try #require(args.firstIndex(of: "-L"))
        #expect(args[forwardIndex + 1] == "127.0.0.1:13389:pc.internal:3389")
        #expect(args.contains("127.0.0.1:1080"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
    }

    @Test func forwardsIPv6AndBuildsClientURLForConfiguredLocalPort() {
        let settings = RemoteDesktop(isEnabled: true, host: " [2001:db8::10] ", remotePort: 3390, localPort: 23389)
        #expect(settings.validationIssue == nil)
        #expect(settings.forwardingArgument == "127.0.0.1:23389:[2001:db8::10]:3390")
        #expect(settings.clientURL?.absoluteString == "rdp://full%20address=s:127.0.0.1:23389")
    }

    @Test func rejectsInvalidForwardTargetsAndPorts() {
        let invalidHosts = [
            "", "pc.internal:3389", "pc internal", "pc.internal/3389", "-pc.internal",
            "[pc.internal]", "::g", "::1\0extra", "::1%not/an/interface"
        ]
        for host in invalidHosts {
            #expect(RemoteDesktop(host: host).validationIssue != nil)
        }
        #expect(RemoteDesktop(host: "pc.internal", remotePort: 0).validationIssue != nil)
        #expect(RemoteDesktop(host: "pc.internal", localPort: 65536).validationIssue != nil)
    }
}
