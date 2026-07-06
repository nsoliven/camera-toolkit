import CameraToolkitCore
import AppKit
import SwiftUI

struct AppShell: View {
    @Bindable var model: DashboardModel

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(
                    model: model,
                    isCollapsed: Binding(
                        get: { model.isSidebarCollapsed },
                        set: { model.isSidebarCollapsed = $0 }
                    )
                )
                .frame(width: model.isSidebarCollapsed ? 74 : 252)
                .animation(.snappy(duration: 0.18), value: model.isSidebarCollapsed)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)

                DetailContainer(
                    section: model.selectedSection,
                    isSidebarCollapsed: model.isSidebarCollapsed,
                    isRefreshing: model.isRefreshing,
                    lastRefreshedAt: model.lastRefreshedAt,
                    toggleSidebar: toggleSidebar,
                    refreshAll: model.refreshAll
                ) {
                    detailView
                }
            }
        }
        .onAppear {
            model.refreshAllIfStale(maxAge: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAllIfStale()
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
        case .config:
            ConfigView(model: model)
        }
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.18)) {
            model.toggleSidebar()
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
                        title: "Execution Locked",
                        message: "Configured folders, tools, and Immich endpoints are live in the workspace. Real writes, deletes, and uploads stay locked until you deliberately add an execution path."
                    )
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
                .help("Execution locked")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Label("Ready Workspace", systemImage: "lock.shield")
                            .font(.headline)
                            .foregroundStyle(AppTheme.mint)
                        HelpButton(
                            title: "Ready Workspace",
                            message: "The app points at persistent config, real workflow plans, and live Immich connection checks. Local simulations are available for proof runs, while real writes remain locked."
                        )
                    }
                    Text("Real plans are shown; execution stays locked.")
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
    var isRefreshing: Bool
    var lastRefreshedAt: Date?
    var toggleSidebar: () -> Void
    var refreshAll: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SidebarToggleButton(isCollapsed: isSidebarCollapsed, action: toggleSidebar)
                Label(section.rawValue, systemImage: section.symbol)
                    .font(.headline)
                Spacer()
                RefreshControl(
                    isRefreshing: isRefreshing,
                    lastRefreshedAt: lastRefreshedAt,
                    refreshAll: refreshAll
                )
                HStack(spacing: 6) {
                    Label("Execution locked", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AppTheme.amber)
                        .labelStyle(.titleAndIcon)
                    HelpButton(
                        title: "Execution locked",
                        message: "The workspace reads persistent config and shows the exact planned commands and endpoints. Buttons that move bytes still run only local simulations unless a real execution path is explicitly added later."
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

private struct RefreshControl: View {
    var isRefreshing: Bool
    var lastRefreshedAt: Date?
    var refreshAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }
            if let lastRefreshedAt {
                Text("Updated \(lastRefreshedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: refreshAll) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRefreshing)
            .help("Refresh all (Command-R)")
            .accessibilityLabel("Refresh all")
        }
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
