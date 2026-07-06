import CameraToolkitCore
import SwiftUI

struct AppShell: View {
    @Bindable var model: DashboardModel

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 252)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)

                DetailContainer(section: model.selectedSection) {
                    detailView
                }
            }
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

struct SidebarView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.aperture")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                    Text("Camera Toolkit")
                        .font(.title3.weight(.semibold))
                }
                Text("Native archive console")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 22)
            .padding(.horizontal, 18)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    SidebarRow(
                        section: section,
                        isSelected: model.selectedSection == section
                    ) {
                        model.selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 8) {
                Label("Simulation", systemImage: "lock.shield")
                    .font(.headline)
                    .foregroundStyle(AppTheme.mint)
                Text("Real storage actions are locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }
}

struct SidebarRow: View {
    var section: AppSection
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(section.rawValue)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? AppTheme.accent : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DetailContainer<Content: View>: View {
    var section: AppSection
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(section.rawValue, systemImage: section.symbol)
                    .font(.headline)
                Spacer()
                Label("No live writes", systemImage: "testtube.2")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppTheme.amber)
                    .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }

            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: 1180, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
