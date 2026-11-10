import Foundation

// Only fixed diagnostic messages and numeric codes are recorded. SSH output,
// profile fields and error descriptions may contain credentials or addresses.
@MainActor
final class DebugLog {
    static let shared = DebugLog()
    private let defaults: UserDefaults
    private let key = "FastSSHTunnel.debugEvents.v1"
    private let limit = 500

    enum Event {
        case started, validationFailed, connecting, connected, disconnected
        case passwordSetupFailed, sshLaunchFailed, trafficFailed
        case sshExited(Int32), sshDiagnostic(SSHDiagnostic)
        case firefoxNotFound, firefoxOpened, firefoxFailed

        var description: String {
            switch self {
            case .started: "Application started"
            case .validationFailed: "Connection settings failed validation"
            case .connecting: "Starting SSH tunnel"
            case .connected: "SSH tunnel connected"
            case .disconnected: "SSH tunnel stopped"
            case .passwordSetupFailed: "Could not prepare password authentication"
            case .sshLaunchFailed: "Could not start SSH process"
            case .trafficFailed: "Traffic monitoring failed"
            case .sshExited(let status): "SSH process exited with status \(status)"
            case .sshDiagnostic(let diagnostic): "SSH: \(diagnostic.rawValue)"
            case .firefoxNotFound: "Firefox was not found"
            case .firefoxOpened: "Firefox launched"
            case .firefoxFailed: "Could not launch Firefox"
            }
        }
    }

    enum SSHDiagnostic: String {
        case authentication = "authentication failed"
        case hostKey = "host key verification failed"
        case resolve = "host name resolution failed"
        case refused = "connection refused"
        case timeout = "connection timed out"
        case network = "network unreachable"
        case bind = "local port could not be bound"
        case closed = "connection closed"
        case other = "additional SSH output omitted"

        static func classify(_ text: String) -> Self {
            let text = text.lowercased()
            if text.contains("permission denied") || text.contains("authentication failed") { return .authentication }
            if text.contains("host key verification failed") || text.contains("remote host identification has changed") { return .hostKey }
            if text.contains("could not resolve hostname") || text.contains("name or service not known") { return .resolve }
            if text.contains("connection refused") { return .refused }
            if text.contains("timed out") { return .timeout }
            if text.contains("network is unreachable") || text.contains("no route to host") { return .network }
            if text.contains("address already in use") || text.contains("cannot listen to port") || text.contains("could not request local forwarding") { return .bind }
            if text.contains("connection closed") || text.contains("connection reset") { return .closed }
            return .other
        }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ event: Event, profileID: UUID? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let profile = profileID.map { " [tunnel \($0.uuidString)]" } ?? ""
        var events = defaults.stringArray(forKey: key) ?? []
        events.append("\(timestamp)\(profile) \(event.description)")
        defaults.set(Array(events.suffix(limit)), forKey: key)
    }

    func contents() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let events = defaults.stringArray(forKey: key) ?? []
        return (["FastSSHTunnel diagnostic log", "Version: \(version) (build \(build))",
                 "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                 "Exported: \(ISO8601DateFormatter().string(from: Date()))",
                 "Contains up to the last 500 diagnostic events. SSH output and connection settings are omitted.", ""] + events).joined(separator: "\n") + "\n"
    }
}
