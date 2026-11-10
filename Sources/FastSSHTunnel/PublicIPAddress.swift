import Combine
import Darwin
import Foundation

enum PublicIPAddressService {
    // Dual-stack endpoint: returns the public IPv4 or IPv6 address used by
    // this Mac to reach the service, rather than an SSH server's address.
    static let endpoint = URL(string: "https://api64.ipify.org?format=json")!

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Do not inherit a system HTTP/SOCKS proxy or route through an app
        // tunnel. System VPN routing still applies to this Mac's connection.
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return configuration
    }

    static func fetch(using session: URLSession? = nil) async throws -> String {
        let connection = session ?? URLSession(configuration: configuration())
        defer {
            if session == nil { connection.finishTasksAndInvalidate() }
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await connection.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 1024 else {
            throw URLError(.badServerResponse)
        }
        struct Response: Decodable { let ip: String }
        let address = try JSONDecoder().decode(Response.self, from: data).ip
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard !address.utf8.contains(0),
              inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 else {
            throw URLError(.cannotParseResponse)
        }
        return address
    }
}

@MainActor
final class PublicIPAddressStore: ObservableObject {
    @Published private(set) var address: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    private let fetchAddress: @Sendable () async throws -> String
    private let isPreview: Bool

    init(fetchAddress: @escaping @Sendable () async throws -> String = { try await PublicIPAddressService.fetch() }) {
        self.fetchAddress = fetchAddress
        isPreview = false
    }

    init(previewAddress: String) {
        address = previewAddress
        fetchAddress = { previewAddress }
        isPreview = true
    }

    func refresh() async {
        guard !isPreview, !isRefreshing, !Task.isCancelled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await fetchAddress()
            try Task.checkCancellation()
            address = result
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            // Do not present an old network's address as the current public IP.
            address = nil
            lastUpdated = nil
            errorMessage = "Could not check the public IP. Check your internet connection and try refreshing."
        }
    }

    func refreshContinuously() async {
        guard !isPreview else { return }
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch { return }
            await refresh()
        }
    }
}
