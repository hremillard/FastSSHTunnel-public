import Foundation
import Network

struct StaticPortForward: Codable, Equatable, Sendable {
    var isEnabled = false
    var host = ""
    var remotePort = 8080
    var localPort = 8080

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
        if address.isEmpty { return "Enter the static forward destination host or IP address." }
        if address.contains(":") {
            let ipv6Characters = hostCharacters.union(CharacterSet(charactersIn: ":%"))
            guard address.unicodeScalars.allSatisfy(ipv6Characters.contains), IPv6Address(address) != nil else {
                return "Enter a valid IPv6 address for the static forward destination."
            }
        } else {
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
                  !address.hasPrefix("-"), address.unicodeScalars.allSatisfy(hostCharacters.contains) else {
                return "Enter a destination hostname or IP address. Use the separate field for its port."
            }
        }
        guard (1...65535).contains(remotePort) else { return "Destination port must be between 1 and 65535." }
        guard (1...65535).contains(localPort) else { return "Local static port must be between 1 and 65535." }
        return nil
    }

    var localAddress: String { "127.0.0.1:\(localPort)" }
    var forwardingArgument: String {
        let address = destination
        let target = address.contains(":") ? "[\(address)]" : address
        return "\(localAddress):\(target):\(remotePort)"
    }
}
