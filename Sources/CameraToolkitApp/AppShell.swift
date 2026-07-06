import CameraToolkitCore
import SwiftUI

struct AppShell: View {
    @Bindable var model: DashboardModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                detailView
                    .padding(28)
            }
        }
    }

    private var sidebar: some View {
        List(AppSection.allCases, selection: $model.selectedSection) { section in
            Label(section.rawValue, systemImage: section.symbol)
                .tag(section)
                .padding(.vertical, 3)
        }
        .navigationTitle("Camera Toolkit")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Protected Mode", systemImage: "lock.shield")
                    .font(.headline)
                Text("Real cards, NAS writes, and delete flows stay disabled until the safety suite is green.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selectedSection {
        case .overview:
            OverviewView(model: model)
        case .import:
            ImportView(model: model)
        case .library:
            LibraryView(model: model)
        case .drive:
            DriveView(model: model)
        case .immich:
            ImmichView(model: model)
        case .jobs:
            JobsView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}

enum AppTheme {
    static let background = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(red: 0.08, green: 0.105, blue: 0.12).opacity(0.36)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panel = Color(nsColor: .controlBackgroundColor).opacity(0.78)
    static let accent = Color(red: 0.08, green: 0.47, blue: 0.62)
    static let mint = Color(red: 0.12, green: 0.58, blue: 0.42)
    static let amber = Color(red: 0.86, green: 0.55, blue: 0.16)
}

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
