import Darwin
import Foundation

struct TunnelTrafficCounters: Equatable, Sendable {
    var txPackets: UInt64 = 0
    var rxPackets: UInt64 = 0
    var txBytes: UInt64 = 0
    var rxBytes: UInt64 = 0
}

struct TunnelTrafficStatistics: Equatable, Sendable {
    var totals = TunnelTrafficCounters()
    var txPacketsPerSecond: Double = 0
    var rxPacketsPerSecond: Double = 0
    var txBytesPerSecond: Double = 0
    var rxBytesPerSecond: Double = 0
}

struct TunnelTrafficSample: Sendable {
    let counters: TunnelTrafficCounters
    let timestamp: TimeInterval
}

struct TunnelTrafficAccumulator {
    private(set) var statistics = TunnelTrafficStatistics()
    private var previousTimestamp: TimeInterval?

    mutating func record(_ sample: TunnelTrafficSample) -> TunnelTrafficStatistics {
        let previous = statistics.totals
        // A transient missing socket must not make connection totals decrease.
        let totals = TunnelTrafficCounters(
            txPackets: max(previous.txPackets, sample.counters.txPackets),
            rxPackets: max(previous.rxPackets, sample.counters.rxPackets),
            txBytes: max(previous.txBytes, sample.counters.txBytes),
            rxBytes: max(previous.rxBytes, sample.counters.rxBytes)
        )
        let elapsed = previousTimestamp.map { sample.timestamp - $0 } ?? 0
        statistics = TunnelTrafficStatistics(totals: totals)
        if elapsed > 0 {
            statistics.txPacketsPerSecond = Double(totals.txPackets - previous.txPackets) / elapsed
            statistics.rxPacketsPerSecond = Double(totals.rxPackets - previous.rxPackets) / elapsed
            statistics.txBytesPerSecond = Double(totals.txBytes - previous.txBytes) / elapsed
            statistics.rxBytesPerSecond = Double(totals.rxBytes - previous.rxBytes) / elapsed
        }
        previousTimestamp = max(previousTimestamp ?? sample.timestamp, sample.timestamp)
        return statistics
    }
}

/// nettop repeats its CSV header at each sampling boundary. Read the header
/// names rather than relying on a column order, which can change across macOS.
struct NettopTrafficParser {
    let processID: Int32
    let socksPort: Int
    let localForwardPort: Int?
    let staticForwardPort: Int?
    private var buffer = Data()
    private var columns: [String] = []
    private var totals = TunnelTrafficCounters()
    private var timestamp: TimeInterval?
    private var hasConnection = false
    private var isTargetProcess = false

    init(processID: Int32, socksPort: Int, localForwardPort: Int? = nil, staticForwardPort: Int? = nil) {
        self.processID = processID
        self.socksPort = socksPort
        self.localForwardPort = localForwardPort
        self.staticForwardPort = staticForwardPort
    }

    mutating func consume(_ data: Data, timestamp: TimeInterval) -> [TunnelTrafficSample] {
        buffer.append(data)
        var samples: [TunnelTrafficSample] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            let cells = line.components(separatedBy: ",")
            guard let label = cells.first else { continue }
            if label.isEmpty && cells.contains("packets_in") && cells.contains("bytes_out") {
                if let sample = finishFrame() { samples.append(sample) }
                columns = cells
                self.timestamp = timestamp
                continue
            }
            if !label.hasPrefix("tcp4 ") && !label.hasPrefix("tcp6 ") {
                isTargetProcess = label.hasSuffix(".\(processID)")
                continue
            }
            guard isTargetProcess, self.timestamp != nil,
                  let separator = label.range(of: "<->") else { continue }
            let local = label[..<separator.lowerBound]
            let remote = label[separator.upperBound...]
            guard let colon = local.lastIndex(of: ":"),
                  let localPort = Int(local[local.index(after: colon)...]),
                  remote.lastIndex(of: ":").flatMap({ Int(remote[remote.index(after: $0)...]) }) != nil,
                  localPort != socksPort, localPort != localForwardPort, localPort != staticForwardPort else { continue }
            // The SSH process also owns the SOCKS and Remote Desktop client
            // sockets. Excluding their local ports avoids counting traffic twice,
            // while still supporting SSH servers reached over loopback or VPN.
            guard let rxPackets = value("packets_in", in: cells),
                  let rxBytes = value("bytes_in", in: cells),
                  let txPackets = value("packets_out", in: cells),
                  let txBytes = value("bytes_out", in: cells) else { continue }
            totals.rxPackets += rxPackets
            totals.rxBytes += rxBytes
            totals.txPackets += txPackets
            totals.txBytes += txBytes
            hasConnection = true
        }
        // Bound memory if a system utility ever produces malformed output.
        if buffer.count > 65_536 { buffer.removeAll(keepingCapacity: false) }
        return samples
    }

    mutating func finish() -> TunnelTrafficSample? {
        finishFrame()
    }

    private func value(_ name: String, in cells: [String]) -> UInt64? {
        guard let index = columns.firstIndex(of: name), cells.indices.contains(index) else { return nil }
        return UInt64(cells[index])
    }

    private mutating func finishFrame() -> TunnelTrafficSample? {
        defer {
            totals = TunnelTrafficCounters()
            hasConnection = false
            isTargetProcess = false
            timestamp = nil
        }
        guard hasConnection, let timestamp else { return nil }
        return TunnelTrafficSample(counters: totals, timestamp: timestamp)
    }
}

/// One lightweight system sampler per connected tunnel. A single long-running
/// nettop process supplies a sample every second without privileged capture or
/// repeatedly launching a new process. Only this tunnel's SSH PID is queried.
final class TunnelTrafficMonitor: @unchecked Sendable {
    private let process = Process()
    private let output: FileHandle
    private let lock = NSLock()
    private var parser: NettopTrafficParser
    private var accumulator = TunnelTrafficAccumulator()
    private var stopped = false
    private var receivedSample = false
    private let onSample: @Sendable (TunnelTrafficStatistics) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(
        processID: Int32,
        socksPort: Int,
        localForwardPort: Int? = nil,
        staticForwardPort: Int? = nil,
        onSample: @escaping @Sendable (TunnelTrafficStatistics) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        parser = NettopTrafficParser(processID: processID, socksPort: socksPort, localForwardPort: localForwardPort, staticForwardPort: staticForwardPort)
        self.onSample = onSample
        self.onFailure = onFailure
        // nettop fully buffers CSV when stdout is a pipe, delaying updates
        // indefinitely on quiet tunnels. A PTY gives it line-buffered output
        // while -L keeps the format CSV. No Terminal window is opened.
        var master: Int32 = -1
        var slave: Int32 = -1
        guard Darwin.openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = Darwin.fcntl(master, F_SETFL, O_NONBLOCK)
        output = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? writer.close() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-L", "0", "-s", "1", "-n", "-x", "-m", "tcp",
            "-J", "packets_in,bytes_in,packets_out,bytes_out",
            "-p", String(processID)
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        output.readabilityHandler = { [weak self] handle in
            // FileHandle.read(upToCount:) can wait to fill its requested length.
            // A nonblocking POSIX read delivers the currently available sample.
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                self?.consume(Data(bytes.prefix(count)))
            } else if count == 0 {
                handle.readabilityHandler = nil
            } else if errno != EAGAIN && errno != EINTR {
                handle.readabilityHandler = nil
                self?.reportFailure("Live traffic statistics are unavailable for this connection.")
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.reportFailure("Live traffic statistics are unavailable for this connection.")
        }
        do {
            try process.run()
        } catch {
            output.readabilityHandler = nil
            throw error
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForFirstSample()
        }
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        guard shouldStop else { return }
        output.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    private func consume(_ data: Data) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let samples = parser.consume(data, timestamp: ProcessInfo.processInfo.systemUptime)
        let updates = samples.map { accumulator.record($0) }
        if !updates.isEmpty { receivedSample = true }
        lock.unlock()
        for update in updates { onSample(update) }
    }

    private func checkForFirstSample() {
        lock.lock()
        let missing = !stopped && !receivedSample
        lock.unlock()
        if missing { reportFailure("Live traffic statistics are unavailable for this connection.") }
    }

    private func reportFailure(_ message: String) {
        lock.lock()
        let shouldReport = !stopped
        lock.unlock()
        if shouldReport { onFailure(message) }
    }
}
