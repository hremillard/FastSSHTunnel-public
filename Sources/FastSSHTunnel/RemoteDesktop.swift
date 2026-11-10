import AppKit
import Network

struct RemoteDesktop: Codable, Equatable, Sendable {
    static let defaultLocalPort = 13389

    var isEnabled = false
    var host = ""
    var remotePort = 3389
    var localPort = Self.defaultLocalPort

    private var destination: String {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("["), address.hasSuffix("]") {
            return String(address.dropFirst().dropLast())
        }
        return address
    }

    var validationIssue: String? {
        let address = destination
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        if address.isEmpty { return "Enter the Windows PC's host or IP address." }
        if address.contains(":") {
            let ipv6Characters = hostCharacters.union(CharacterSet(charactersIn: ":%"))
            guard address.unicodeScalars.allSatisfy(ipv6Characters.contains), IPv6Address(address) != nil else {
                return "Enter a valid IPv6 address for the Windows PC."
            }
        } else {
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
                  !address.hasPrefix("-"), address.unicodeScalars.allSatisfy(hostCharacters.contains) else {
                return "Enter a hostname or IP address for the Windows PC. Use the separate field for its port."
            }
        }
        guard (1...65535).contains(remotePort) else { return "Remote Desktop port must be between 1 and 65535." }
        guard (1...65535).contains(localPort) else { return "Local Remote Desktop port must be between 1 and 65535." }
        return nil
    }

    var localAddress: String { "127.0.0.1:\(localPort)" }

    var forwardingArgument: String {
        let address = destination
        let target = address.contains(":") ? "[\(address)]" : address
        return "\(localAddress):\(target):\(remotePort)"
    }

    var clientURL: URL? {
        // The legacy RDP URI uses an attribute list where a standard URL has
        // an authority. Preserve the client's expected spelling verbatim.
        URL(dataRepresentation: Data("rdp://full%20address=s:\(localAddress)".utf8), relativeTo: nil)
    }

    @MainActor
    func openClient() async throws {
        guard let client = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.rdc.macos") else {
            throw RemoteDesktopError("Install Windows App or Microsoft Remote Desktop, then try again.")
        }
        guard let clientURL else {
            throw RemoteDesktopError("Could not create the Remote Desktop connection address.")
        }
        _ = try await NSWorkspace.shared.open([clientURL], withApplicationAt: client, configuration: .init())
    }
}

struct RemoteDesktopError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
