import CameraToolkitCore
import SwiftUI

// Chrome shared by the event and unsorted boards: the centered toolbar
// title with its count capsule, the floating bottom glass bar with the
// view controls, and the status caption under it.

/// The toolbar's centered title: an event's color dot (or a folder
/// symbol), the name, and a count capsule — "N of M" while a search is
/// narrowing the board. Date, size, and the long summary are in `help`.
struct BoardToolbarTitle: View {
    let title: String
    var color: Color? = nil
    var symbol: String? = nil
    let count: String
    let countHelp: String
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            } else if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Text(count)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quinary, in: Capsule())
                .help(countHelp)
        }
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(countHelp)")
    }
}

/// Filter · tiles/list · sort and group · tile size · hide sorted — the
/// board's view controls as one floating glass capsule. Compact drops the
/// slider for Larger/Smaller items in the sort menu.
struct BoardViewControls: View {
    @Bindable var workspace: EventsWorkspace
    /// The unfiltered board's stacks, for the filter panel's pickers.
    let stacks: [OrganizeStack]
    var eventScope: Set<UUID>? = nil
    /// Stacks the current search keeps, for the filter panel's readout.
    let matchedCount: Int
    /// The board's groups as computed once for this render — Expand or
    /// Collapse All reads them instead of re-planning the board.
    let groups: [OrganizeBoardGroup]
    @Binding var mode: OrganizeBoardMode
    @Binding var grouping: OrganizeBoardGrouping
    let groupings: [OrganizeBoardGrouping]
    @Binding var order: OrganizeBoardOrder
    @Binding var tileWidth: Double
    /// Unsorted boards only.
    var hideSorted: Binding<Bool>? = nil
    var compact = false

    static let tileWidthRange = 88.0...460.0

    var body: some View {
        HStack(spacing: 6) {
            OrganizeFilterButton(
                workspace: workspace,
                stacks: stacks,
                eventScope: eventScope,
                search: $workspace.search,
                matchedCount: matchedCount
            )
            Picker("View", selection: $mode) {
                ForEach(OrganizeBoardMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the board as tiles or as a list")
            Menu {
                BoardSortMenuContent(
                    workspace: workspace,
                    groups: groups,
                    grouping: $grouping,
                    groupings: groupings,
                    order: $order,
                    tileWidth: compact && mode == .tiles ? $tileWidth : nil
                )
            } label: {
                Label("Sort & Group", systemImage: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Group, sort, and collapse the board")
            if mode == .tiles && !compact {
                Slider(value: $tileWidth, in: Self.tileWidthRange) {
                    Text("Tile Size")
                } minimumValueLabel: {
                    Image(systemName: "photo")
                        .imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "photo")
                        .imageScale(.large)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
                .help("Tile size — smaller fits more bursts on screen")
            }
            if let hideSorted {
                Toggle(isOn: hideSorted) {
                    Label("Hide Sorted", systemImage: "eye.slash")
                }
                .toggleStyle(.button)
                .help(hideSorted.wrappedValue ? "Show sorted items again" : "Hide items already sorted into an event")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// The Sort & Group menu's items, in their own view so they are built
/// with the menu rather than on every board render.
private struct BoardSortMenuContent: View {
    let workspace: EventsWorkspace
    let groups: [OrganizeBoardGroup]
    @Binding var grouping: OrganizeBoardGrouping
    let groupings: [OrganizeBoardGrouping]
    @Binding var order: OrganizeBoardOrder
    /// Set in compact bars, where the slider is not shown.
    var tileWidth: Binding<Double>?

    var body: some View {
        Picker("Group By", selection: $grouping) {
            ForEach(groupings) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.inline)
        Picker("Order", selection: $order) {
            ForEach(OrganizeBoardOrder.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.inline)
        Divider()
        let anyCollapsed = groups.contains { workspace.collapsedGroupIDs.contains($0.id) }
        Button(anyCollapsed ? "Expand All Groups" : "Collapse All Groups") {
            workspace.setAllGroupsCollapsed(!anyCollapsed, groups: groups)
        }
        if let tileWidth {
            Divider()
            Button("Larger Tiles") {
                tileWidth.wrappedValue = min(tileWidth.wrappedValue * 1.25, BoardViewControls.tileWidthRange.upperBound)
            }
            Button("Smaller Tiles") {
                tileWidth.wrappedValue = max(tileWidth.wrappedValue / 1.25, BoardViewControls.tileWidthRange.lowerBound)
            }
        }
    }
}

/// The bottom of a board: the floating glass controls, then one caption
/// line with the running job, loading progress, or the latest status
/// message — errors land in `statusMessage` and stay visible here.
struct BoardBottomBar<Controls: View>: View {
    @Bindable var model: DashboardModel
    let workspace: EventsWorkspace
    /// "Reading capture dates… 40 left." while the board is still loading.
    var loadingNote: String? = nil
    /// A trailing hint, shown after the status when there is room.
    var hint: String? = nil
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 6) {
            if let running = workspace.runningApply,
               model.jobs.contains(where: { $0.id == running.jobID && $0.state == .running }) {
                ApplyProgressBanner(running: running)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            GlassEffectContainer(spacing: 10) {
                controls()
            }
            BoardStatusLine(model: model, loadingNote: loadingNote, hint: hint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// The caption under the bottom bar: a running job with its progress,
/// board loading progress, or `statusMessage`.
private struct BoardStatusLine: View {
    @Bindable var model: DashboardModel
    let loadingNote: String?
    let hint: String?

    var body: some View {
        HStack(spacing: 8) {
            if let job = model.activeJob {
                ProgressView(value: job.progress)
                    .controlSize(.small)
                    .frame(width: 120)
                Text(job.note)
                    .truncationMode(.middle)
            } else if let loadingNote {
                ProgressView()
                    .controlSize(.small)
                Text(loadingNote)
            } else {
                Text(model.statusMessage)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let hint {
                Text(hint)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 16)
    }
}
