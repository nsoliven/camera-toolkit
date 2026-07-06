import CameraToolkitCore
import SwiftUI

struct LocationStatusGrid: View {
    var locations: [LocationCard]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 14)], spacing: 14) {
            ForEach(locations) { location in
                LocationStatusCard(location: location)
            }
        }
    }
}

struct LocationStatusCard: View {
    var location: LocationCard

    var body: some View {
        Panel(title: nil, symbol: nil) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(tint)
                Spacer()
                Label(location.status.rawValue, systemImage: location.status.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(location.title)
                    .font(.title3.weight(.semibold))
                Text(location.subtitle)
                    .foregroundStyle(.secondary)
                Text(location.detail)
                    .font(.callout.monospacedDigit())
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var icon: String {
        switch location.kind {
        case .card: "sdcard"
        case .drive: "externaldrive"
        case .nas: "server.rack"
        case .immich: "sparkles.rectangle.stack"
        case .mac: "macbook"
        }
    }

    private var tint: Color {
        switch location.status {
        case .ready: AppTheme.mint
        case .warning: AppTheme.amber
        case .offline: .red
        }
    }
}

struct SafetyPanel: View {
    var checks: [SafetyCheck]

    var body: some View {
        Panel(
            title: "Safety Gates",
            symbol: "lock.shield",
            helpTitle: "Safety Gates",
            helpText: "These are the rules that protect real files: no overwrite-style archive copies, no freeing space until checksums match, no permanent delete without confirmation, and real writes/uploads locked until deliberately enabled."
        ) {
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: check.state.symbol)
                        .font(.title3)
                        .foregroundStyle(color(for: check.state))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(check.title)
                                .font(.headline)
                            HelpButton(title: check.title, message: check.helpText)
                        }
                        Text(check.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if check.id != checks.last?.id {
                    Divider()
                }
            }
        }
        .frame(width: 360)
    }

    private func color(for state: SafetyState) -> Color {
        switch state {
        case .passed: AppTheme.mint
        case .attention: AppTheme.amber
        case .blocked: .red
        }
    }
}
