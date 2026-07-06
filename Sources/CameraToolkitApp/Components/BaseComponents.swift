import SwiftUI

struct Panel<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(AppTheme.accent)
                    }
                    Text(title)
                        .font(.headline)
                    Spacer()
                }
            }
            content
        }
        .padding(18)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
    }
}

struct MetricPill: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 34, height: 34)
                .foregroundStyle(tint)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct HeaderView: View {
    var eyebrow: String
    var title: String
    var subtitle: String
    var badgeTitle: String = "Simulation"
    var badgeSubtitle: String = "No real volumes touched"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                headerCopy
                Spacer(minLength: 16)
                HeaderBadge(title: badgeTitle, subtitle: badgeSubtitle)
            }

            VStack(alignment: .leading, spacing: 14) {
                headerCopy
                HeaderBadge(title: badgeTitle, subtitle: badgeSubtitle)
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .lineLimit(2)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HeaderBadge: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Label(title, systemImage: "testtube.2")
                .font(.headline)
                .foregroundStyle(AppTheme.amber)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CommandBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                content
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
    }
}

struct CommandButton: View {
    enum Prominence {
        case primary
        case secondary
    }

    var title: String
    var symbol: String
    var prominence: Prominence = .secondary
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        switch prominence {
        case .primary:
            button
                .buttonStyle(.borderedProminent)
        case .secondary:
            button
                .buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
        }
        .disabled(isDisabled)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier(accessibilityID)
    }

    private var accessibilityID: String {
        "command-\(title.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(32))"
    }
}
