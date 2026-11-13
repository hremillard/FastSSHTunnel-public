import AppKit
import Foundation

struct SSHDevice: Codable, Equatable, Sendable {
    var host = ""
    var username = ""
    var port = 22
}

struct SSHDeviceError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum SSHDeviceConfiguration {
    // A copied username can include a zero-width space or byte order mark at its edges.
    private static let usernamePadding = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}"))

    static func arguments(for device: SSHDevice, socksPort: Int) throws -> [String] {
        let host = device.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = device.username.trimmingCharacters(in: usernamePadding)
        guard !host.isEmpty else { throw SSHDeviceError("Enter the device's host or IP address.") }
        // OpenSSH substitutes the host into a shell-based ProxyCommand. Restrict
        // it to literal DNS/IP characters, including IPv6, before that happens.
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(hostCharacters.contains) else {
            throw SSHDeviceError("Use a hostname or IP address without spaces, brackets, or shell characters.")
        }
        guard !username.isEmpty else { throw SSHDeviceError("Enter the device's SSH username.") }
        guard !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SSHDeviceError("The device's SSH username contains invisible control characters. Retype the username and try again.")
        }
        guard (1...65535).contains(device.port) else {
            throw SSHDeviceError("Device SSH port must be between 1 and 65535.")
        }
        guard (1...65535).contains(socksPort) else {
            throw SSHDeviceError("The tunnel's SOCKS port must be between 1 and 65535.")
        }
        return [
            // Ignore local SSH config so an alias, proxy, or existing control
            // socket cannot silently route the session around this tunnel.
            "-F", "/dev/null", "-tt",
            "-p", String(device.port),
            "-o", "ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:\(socksPort) '%h' '%p'",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-l", username, "--", host
        ]
    }

    static func terminalScript(for device: SSHDevice, socksPort: Int) throws -> String {
        let arguments = try arguments(for: device, socksPort: socksPort)
        return """
        #!/bin/sh
        /bin/rm -f -- "$0"
        export SSH_ASKPASS_REQUIRE=never
        exec /usr/bin/ssh \(arguments.map(shellQuote).joined(separator: " "))

        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

@MainActor
enum SSHDeviceTerminal {
    static func open(_ device: SSHDevice, socksPort: Int) async throws {
        let script = try SSHDeviceConfiguration.terminalScript(for: device, socksPort: socksPort)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw SSHDeviceError("Terminal could not be found on this Mac.")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastSSHTunnel-SSH-\(UUID().uuidString).command")
        // Create with owner-only permissions from the outset. No passwords are
        // written; the script removes itself when Terminal begins the session.
        guard FileManager.default.createFile(atPath: file.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw SSHDeviceError("Could not prepare the SSH session for Terminal.")
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
