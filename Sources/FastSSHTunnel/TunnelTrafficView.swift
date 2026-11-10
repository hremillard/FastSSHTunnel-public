import SwiftUI

struct TunnelTrafficView: View {
    let statistics: TunnelTrafficStatistics?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let statistics {
                HStack(alignment: .top, spacing: 24) {
                    direction(
                        "TX · Sent", symbol: "arrow.up", color: .blue,
                        packets: statistics.totals.txPackets, bytes: statistics.totals.txBytes,
                        packetsPerSecond: statistics.txPacketsPerSecond,
                        bytesPerSecond: statistics.txBytesPerSecond
                    )
                    direction(
                        "RX · Received", symbol: "arrow.down", color: .green,
                        packets: statistics.totals.rxPackets, bytes: statistics.totals.rxBytes,
                        packetsPerSecond: statistics.rxPacketsPerSecond,
                        bytesPerSecond: statistics.rxBytesPerSecond
                    )
                }
                Text("Updates every second · Current connection, including SSH overhead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring tunnel traffic…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func direction(
        _ title: String, symbol: String, color: Color,
        packets: UInt64, bytes: UInt64,
        packetsPerSecond: Double, bytesPerSecond: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text("\(packets.formatted()) packets")
                .font(.system(.title3, design: .monospaced))
                .monospacedDigit()
            Text("\(packetsPerSecond.formatted(.number.precision(.fractionLength(0...1)))) pkt/s · \(byteCount(bytesPerSecond))/s")
                .font(.caption)
                .monospacedDigit()
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)) transferred")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func byteCount(_ value: Double) -> String {
        // Clamp only for formatting; the stored packet/byte totals remain UInt64.
        let bounded = value.isFinite ? min(max(value, 0), 1e18) : 0
        return ByteCountFormatter.string(fromByteCount: Int64(bounded), countStyle: .binary)
    }
}
