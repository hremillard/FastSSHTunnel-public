import Darwin
import Foundation
import Testing
@testable import FastSSHTunnel

struct TunnelTrafficTests {
    @Test func parserExcludesLocalForwardsAndOtherProcessesAndHandlesSplitReads() throws {
        var parser = NettopTrafficParser(processID: 42, socksPort: 1080, localForwardPort: 13389, staticForwardPort: 15432)
        let csv = """
        ,packets_in,bytes_in,packets_out,bytes_out,
        ssh.42,999,999999,999,999999,
        tcp4 10.0.0.2:52000<->10.0.0.3:22,12,12000,8,8000,
        tcp4 127.0.0.1:1080<->127.0.0.1:52001,8,8000,12,12000,
        tcp4 127.0.0.1:13389<->127.0.0.1:52004,7,7000,6,6000,
        tcp4 127.0.0.1:15432<->127.0.0.1:52005,7,7000,6,6000,
        other.142,500,500000,500,500000,
        tcp4 10.0.0.2:52002<->10.0.0.4:22,500,500000,500,500000,
        ,packets_in,bytes_in,packets_out,bytes_out,

        """
        let data = Data(csv.utf8)
        var samples: [TunnelTrafficSample] = []
        for offset in stride(from: 0, to: data.count, by: 7) {
            samples += parser.consume(data.subdata(in: offset..<min(offset + 7, data.count)), timestamp: 10)
        }
        let sample = try #require(samples.first)
        #expect(samples.count == 1)
        #expect(sample.counters == TunnelTrafficCounters(txPackets: 8, rxPackets: 12, txBytes: 8000, rxBytes: 12000))
    }

    @Test func parserFollowsHeaderOrderAndSupportsIPv6AndLoopbackServers() throws {
        var parser = NettopTrafficParser(processID: 42, socksPort: 1080)
        let csv = """
        ,bytes_out,packets_out,bytes_in,packets_in,
        ssh.42,900,9,1200,12,
        tcp6 [::1]:52000<->[::1]:22,900,9,1200,12,
        tcp6 [::1]:1080<->[::1]:52001,1200,12,900,9,
        tcp4 127.0.0.1:52002<->127.0.0.1:2222,100,1,200,2,
        tcp4 10.0.0.1:52003<->10.0.0.2:22,invalid,invalid,invalid,invalid,

        """
        #expect(parser.consume(Data(csv.utf8), timestamp: 10).isEmpty)
        let finalSample = parser.finish()
        let sample = try #require(finalSample)
        #expect(sample.counters == TunnelTrafficCounters(txPackets: 10, rxPackets: 14, txBytes: 1000, rxBytes: 1400))
        #expect(parser.finish() == nil)
    }

    @Test func ratesUseElapsedTimeAndReturnToZeroWhenIdle() {
        var accumulator = TunnelTrafficAccumulator()
        let first = TunnelTrafficCounters(txPackets: 10, rxPackets: 20, txBytes: 1000, rxBytes: 2000)
        #expect(accumulator.record(.init(counters: first, timestamp: 10)).txPacketsPerSecond == 0)
        let second = TunnelTrafficCounters(txPackets: 16, rxPackets: 30, txBytes: 4000, rxBytes: 7000)
        let active = accumulator.record(.init(counters: second, timestamp: 12))
        #expect(active.txPacketsPerSecond == 3)
        #expect(active.rxPacketsPerSecond == 5)
        #expect(active.txBytesPerSecond == 1500)
        #expect(active.rxBytesPerSecond == 2500)
        let idle = accumulator.record(.init(counters: second, timestamp: 13))
        #expect(idle.txPacketsPerSecond == 0)
        #expect(idle.rxBytesPerSecond == 0)
        let missing = accumulator.record(.init(counters: .init(), timestamp: 14))
        #expect(missing.totals == second)
        #expect(missing.txBytesPerSecond == 0)
        let duplicate = accumulator.record(.init(counters: second, timestamp: 14))
        #expect(duplicate.txPacketsPerSecond.isFinite)
        let restarted = TunnelTrafficAccumulator()
        #expect(restarted.statistics.totals == TunnelTrafficCounters())
    }

    @Test func liveSamplerMeasuresBothDirectionsOnLocalTCP() async throws {
        let connection = try LocalTrafficConnection()
        defer { connection.stop() }
        let recorder = TrafficRecorder()
        let monitor = try TunnelTrafficMonitor(
            processID: connection.processID,
            socksPort: 1080,
            onSample: { recorder.record($0) },
            onFailure: { recorder.fail($0) }
        )
        defer { monitor.stop() }
        try connection.exchange(byteCount: 16_384)
        let received = await waitFor {
            guard let sample = recorder.latest else { return false }
            return sample.totals.txBytes >= 16_384 && sample.totals.rxBytes >= 16_384
        }
        #expect(received, "The live macOS sampler should measure the test TCP socket in both directions.")
        let initial = try #require(recorder.latest)
        #expect(initial.totals.txPackets > 0)
        #expect(initial.totals.rxPackets > 0)
        try connection.exchange(byteCount: 16_384)
        let updated = await waitFor {
            guard let sample = recorder.latest else { return false }
            return sample.totals.txBytes > initial.totals.txBytes &&
                sample.totals.rxBytes > initial.totals.rxBytes &&
                sample.txBytesPerSecond > 0 && sample.rxBytesPerSecond > 0
        }
        #expect(updated, "Traffic totals and rates should update while data is flowing.")
        #expect(recorder.failure == nil)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}

private final class TrafficRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: TunnelTrafficStatistics?
    private var error: String?
    var latest: TunnelTrafficStatistics? {
        lock.lock()
        defer { lock.unlock() }
        return sample
    }
    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
    func record(_ sample: TunnelTrafficStatistics) {
        lock.lock()
        self.sample = sample
        lock.unlock()
    }
    func fail(_ message: String) {
        lock.lock()
        error = message
        lock.unlock()
    }
}

/// Generates traffic entirely on loopback. nettop observes the nc child,
/// while the test owns the peer socket, so no real SSH server is contacted.
private final class LocalTrafficConnection {
    private let client = Process()
    private let input = Pipe()
    private var peer: Int32 = -1
    var processID: Int32 { client.processIdentifier }

    init() throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(listener) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = Darwin.setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        client.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        client.arguments = ["-n", "127.0.0.1", String(UInt16(bigEndian: address.sin_port))]
        client.standardInput = input
        client.standardOutput = FileHandle.nullDevice
        client.standardError = FileHandle.nullDevice
        try client.run()
        peer = Darwin.accept(listener, nil, nil)
        guard peer >= 0 else { client.terminate(); throw POSIXError(.ETIMEDOUT) }
        _ = Darwin.setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = Darwin.setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        _ = Darwin.setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    }

    func exchange(byteCount: Int) throws {
        let data = Data(repeating: 65, count: byteCount)
        try input.fileHandleForWriting.write(contentsOf: data)
        var remaining = byteCount
        var buffer = [UInt8](repeating: 0, count: 4096)
        while remaining > 0 {
            let count = Darwin.recv(peer, &buffer, min(remaining, buffer.count), 0)
            guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
            remaining -= count
        }
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(peer, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw POSIXError(.EIO) }
                sent += count
            }
        }
    }

    func stop() {
        if client.isRunning { client.terminate() }
        if peer >= 0 { Darwin.close(peer); peer = -1 }
    }

    deinit { stop() }
}
