import Foundation

enum SSHConfiguration {
    static func hasAuthentication(password: String, identityFile: String) -> Bool {
        !password.isEmpty || !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func arguments(for profile: TunnelProfile, usesPassword: Bool, readyMarker: String) -> [String] {
        var arguments = [
            "-N", "-D", "127.0.0.1:\(profile.socksPort)",
            "-p", String(profile.sshPort),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            // Keep every listener owned by this process so Disconnect and Quit can stop it.
            "-o", "ControlPath=none",
            "-o", "ForkAfterAuthentication=no",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "VerifyHostKeyDNS=no",
            "-o", "FingerprintHash=sha256",
            // Batch mode would reject new keys without calling the prompt helper.
            "-o", "BatchMode=no",
            "-o", "PermitLocalCommand=yes",
            // This fixed local command runs only after authentication and forwarding
            // setup succeed. The marker contains only a generated UUID, never user input.
            "-o", "LocalCommand=/usr/bin/printf '\\n\(readyMarker)\\n' >&2"
        ]
        if let remoteDesktop = profile.enabledRemoteDesktop {
            arguments += ["-L", remoteDesktop.forwardingArgument]
        }
        if let staticPort = profile.enabledStaticPort {
            arguments += ["-L", staticPort.forwardingArgument]
        }
        if profile.enabledRemoteDesktop != nil || profile.enabledStaticPort != nil {
            arguments += ["-o", "ClearAllForwardings=no"]
        }
        if usesPassword {
            arguments += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "NumberOfPasswordPrompts=1"
            ]
        } else {
            arguments += [
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0"
            ]
        }
        if !profile.identityFile.isEmpty { arguments += ["-i", profile.identityFile] }
        // Keep user-supplied values out of SSH's option parser and shell commands.
        arguments += ["-l", profile.username, "--", profile.host]
        return arguments
    }
}
