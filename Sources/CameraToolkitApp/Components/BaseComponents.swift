import CameraToolkitCore
import SwiftUI

struct Panel<Content: View>: View {
    var title: String?
    var symbol: String?
    var helpTitle: String?
    var helpText: String?
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
                    if let helpText {
                        HelpButton(title: helpTitle ?? title, message: helpText)
                    }
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

struct HelpButton: View {
    var title: String
    var message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Explain \(title)")
        .accessibilityLabel("Explain \(title)")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
        }
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
    var badgeTitle: String = "Ready Workspace"
    var badgeSubtitle: String = "Real writes locked"

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
            Label(title, systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(AppTheme.mint)
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
    var helpText: String?
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
        .help(helpText ?? title)
    }

    private var accessibilityID: String {
        "command-\(title.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(32))"
    }
}

struct HelpedCommandButton: View {
    var title: String
    var symbol: String
    var prominence: CommandButton.Prominence = .secondary
    var isDisabled: Bool = false
    var helpTitle: String? = nil
    var helpText: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            CommandButton(
                title: title,
                symbol: symbol,
                prominence: prominence,
                isDisabled: isDisabled,
                helpText: helpText,
                action: action
            )
            HelpButton(title: helpTitle ?? title, message: helpText)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct FormFieldLabel: View {
    var title: String
    var helpText: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            HelpButton(title: title, message: helpText)
        }
    }
}

struct ActiveJobBanner: View {
    var job: JobSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.action.displayName)
                        .font(.callout.weight(.semibold))
                    Text("\(Int(job.progress * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                Text(job.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            ProgressView(value: job.progress)
                .frame(width: 180)
                .accessibilityLabel("Job progress")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(AppTheme.accent.opacity(0.18))
        )
    }
}
