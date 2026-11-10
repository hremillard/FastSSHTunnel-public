import Foundation
import Testing
@testable import FastSSHTunnel

@Suite(.serialized)
struct PublicIPAddressTests {
    @Test func validatesIPv4AndIPv6AndRequestsFreshData() async throws {
        for address in ["203.0.113.42", "2001:db8::42"] {
            let session = sessionReturning(status: 200, body: "{\"ip\":\"\(address)\"}")
            defer { session.invalidateAndCancel() }
            #expect(try await PublicIPAddressService.fetch(using: session) == address)
            let request = try #require(PublicIPStubProtocol.lastRequest)
            #expect(request.url == PublicIPAddressService.endpoint)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 10)
        }
    }

    @Test func rejectsFailedResponsesAndInvalidAddresses() async {
        for (status, body) in [
            (503, "{\"ip\":\"203.0.113.42\"}"),
            (200, "<html>Connection failed</html>"),
            (200, "{\"ip\":\"example.com\"}"),
            (200, "{\"ip\":\"\"}"),
            (200, "{\"ip\":\"203.0.113.42\\u0000hidden\"}"),
            (200, String(repeating: "x", count: 1025))
        ] {
            let session = sessionReturning(status: status, body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await PublicIPAddressService.fetch(using: session)
                Issue.record("Invalid public-IP response was accepted: HTTP \(status), \(body.prefix(60))")
            } catch { /* Expected: the UI will show Unavailable. */ }
        }
    }

    @Test func lookupConfigurationUsesNoProxyOrPersistentStorage() {
        let configuration = PublicIPAddressService.configuration()
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForResource == 15)
    }

    @Test @MainActor func failedRefreshDoesNotDisplayAnOldAddress() async {
        let responses = PublicIPResponses()
        let store = PublicIPAddressStore { try await responses.next() }
        await store.refresh()
        #expect(store.address == "203.0.113.42")
        #expect(store.errorMessage == nil)
        #expect(store.lastUpdated != nil)
        await store.refresh()
        #expect(store.address == nil)
        #expect(store.errorMessage != nil)
        #expect(store.lastUpdated == nil)
        #expect(!store.isRefreshing)
    }

    @Test @MainActor func overlappingRefreshesShareOneLookup() async {
        let counter = PublicIPResponses()
        let store = PublicIPAddressStore {
            try await Task.sleep(for: .milliseconds(40))
            return try await counter.next()
        }
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        #expect(await counter.calls == 1)
        #expect(store.address == "203.0.113.42")
    }

    @Test @MainActor func previewsDoNotPerformNetworkLookups() async {
        let store = PublicIPAddressStore(previewAddress: "203.0.113.99")
        await store.refresh()
        await store.refreshContinuously()
        #expect(store.address == "203.0.113.99")
        #expect(!store.isRefreshing)
        #expect(store.lastUpdated == nil)
    }

    private func sessionReturning(status: Int, body: String) -> URLSession {
        PublicIPStubProtocol.responseStatus = status
        PublicIPStubProtocol.responseBody = Data(body.utf8)
        PublicIPStubProtocol.lastRequest = nil
        let configuration = PublicIPAddressService.configuration()
        configuration.protocolClasses = [PublicIPStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor PublicIPResponses {
    private(set) var calls = 0
    func next() throws -> String {
        calls += 1
        guard calls == 1 else { throw URLError(.notConnectedToInternet) }
        return "203.0.113.42"
    }
}

// This suite is serialized, so each stub response belongs to one test session.
private final class PublicIPStubProtocol: URLProtocol, @unchecked Sendable {
    static var responseStatus = 200
    static var responseBody = Data()
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
