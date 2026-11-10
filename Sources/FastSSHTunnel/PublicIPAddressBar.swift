import AppKit
import SwiftUI

struct PublicIPAddressBar: View {
    let address: String?
    let isRefreshing: Bool
    let errorMessage: String?
    let lastUpdated: Date?
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text("Public IP (this Mac):")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(address ?? (isRefreshing ? "Checking…" : "Unavailable"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .help(statusHelp)
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Checking public IP")
                }
                Spacer(minLength: 8)
                if let address {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy public IP")
                    .accessibilityLabel("Copy public IP")
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .help("Refresh public IP")
                .accessibilityLabel("Refresh public IP")
            }
            .font(.callout)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
        }
    }

    private var statusHelp: String {
        if let errorMessage { return errorMessage }
        var message = "Public IP used by this Mac's network connection, including any system VPN. Updates every minute."
        if let lastUpdated {
            message += " Last checked \(lastUpdated.formatted(date: .omitted, time: .standard))."
        }
        return message
    }
}
