import CameraToolkitCore
import SwiftUI

struct AppShell: View {
    @Bindable var model: DashboardModel
    @State private var isSidebarCollapsed = false

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(model: model, isCollapsed: $isSidebarCollapsed)
                    .frame(width: isSidebarCollapsed ? 74 : 252)
                    .animation(.snappy(duration: 0.18), value: isSidebarCollapsed)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)

                DetailContainer(
                    section: model.selectedSection,
                    isSidebarCollapsed: isSidebarCollapsed,
                    toggleSidebar: toggleSidebar
                ) {
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

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.18)) {
            isSidebarCollapsed.toggle()
        }
    }
}

struct SidebarView: View {
    @Bindable var model: DashboardModel
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 18) {
            VStack(alignment: isCollapsed ? .center : .leading, spacing: 6) {
                HStack(spacing: isCollapsed ? 0 : 10) {
                    Image(systemName: "camera.aperture")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                    if !isCollapsed {
                        Text("Camera Toolkit")
                            .font(.title3.weight(.semibold))
                        Spacer(minLength: 8)
                    }
                    SidebarToggleButton(isCollapsed: isCollapsed, action: toggleSidebar)
                }
                if !isCollapsed {
                    Text("Native archive console")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, isCollapsed ? 12 : 18)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    SidebarRow(
                        section: section,
                        isSelected: model.selectedSection == section,
                        isCollapsed: isCollapsed
                    ) {
                        model.selectedSection = section
                    }
                }
            }
            .padding(.horizontal, isCollapsed ? 8 : 10)

            Spacer(minLength: 16)

            if isCollapsed {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.title3)
                        .foregroundStyle(AppTheme.mint)
                    HelpButton(
                        title: "Safe Demo",
                        message: "The app is currently locked to fake local folders under Application Support. It can show the workflow and run safety checks without touching a real camera card, drive, NAS, or Immich server."
                    )
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
                .help("Safe Demo: fake local folders only")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Label("Safe Demo", systemImage: "lock.shield")
                            .font(.headline)
                            .foregroundStyle(AppTheme.mint)
                        HelpButton(
                            title: "Safe Demo",
                            message: "The app is currently locked to fake local folders under Application Support. It can show the workflow and run safety checks without touching a real camera card, drive, NAS, or Immich server."
                        )
                    }
                    Text("Only fake local folders are touched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.18)) {
            isCollapsed.toggle()
        }
    }
}

struct SidebarRow: View {
    var section: AppSection
    var isSelected: Bool
    var isCollapsed: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: isCollapsed ? 0 : 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                if !isCollapsed {
                    Text(section.rawValue)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                    Spacer()
                }
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 8 : 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? AppTheme.accent : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
        .accessibilityLabel(section.rawValue)
    }
}

struct DetailContainer<Content: View>: View {
    var section: AppSection
    var isSidebarCollapsed: Bool
    var toggleSidebar: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SidebarToggleButton(isCollapsed: isSidebarCollapsed, action: toggleSidebar)
                Label(section.rawValue, systemImage: section.symbol)
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Label("Demo only", systemImage: "testtube.2")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AppTheme.amber)
                        .labelStyle(.titleAndIcon)
                    HelpButton(
                        title: "Demo only",
                        message: "Buttons run against fake folders unless a future real-device mode is deliberately unlocked. That keeps testing safe while the transfer and free-up rules are still being hardened."
                    )
                }
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
                    .padding(24)
                    .frame(maxWidth: 1180, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SidebarToggleButton: View {
    var isCollapsed: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isCollapsed ? "sidebar.right" : "sidebar.left")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityIdentifier(isCollapsed ? "sidebar-expand" : "sidebar-collapse")
    }
}
