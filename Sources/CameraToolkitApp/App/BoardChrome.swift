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

/// Part of a board's top bar that scrolls once it reaches `maxHeight`:
/// short content keeps its own height, taller content stops at the limit
/// and scrolls inside it. A safe-area bar is laid out at its content's full
/// height, so without this a bar with many chips outgrows the window.
struct BoardBarScrollRegion<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        HeightLimitedLayout(maxHeight: maxHeight) {
            ScrollView(.vertical) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Sizes its one subview to the subview's own height (its content's height,
/// for a vertical `ScrollView`) up to `maxHeight`, in one layout pass.
private struct HeightLimitedLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let natural = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// Filter · tiles/list · Sort · Group · tile size · hide sorted — the
/// board's view controls as one floating glass capsule. Sort and Group are
/// separate, labelled menus ("Sort: Largest Bursts", "Group: Day"); compact
/// bars shorten them to "Sort" and "Group", the narrowest to icons (the
/// current choice stays in the help and VoiceOver label), and move the slider into the Group menu as
/// Larger/Smaller items.
///
/// The filter button only toggles `filterPresented`: boards lay this out
/// inside a `ViewThatFits`, so the filter popover is attached outside it
/// with `boardFilterPopover` (see there).
struct BoardViewControls: View {
    @Bindable var workspace: EventsWorkspace
    /// Whether the board's filter popover is open — owned by the board,
    /// outside the `ViewThatFits` candidates.
    @Binding var filterPresented: Bool
    /// The board's groups as computed once for this render — Expand or
    /// Collapse All reads them instead of re-planning the board.
    let groups: [OrganizeBoardGroup]
    @Binding var mode: OrganizeBoardMode
    @Binding var grouping: OrganizeBoardGrouping
    let groupings: [OrganizeBoardGrouping]
    @Binding var sort: OrganizeStackSort
    @Binding var tileWidth: Double
    /// Unsorted boards only.
    var hideSorted: Binding<Bool>? = nil
    var compact = false
    /// The narrowest bars: Sort and Group as bare icons (their current
    /// choice stays in the help and VoiceOver label).
    var iconOnlyMenus = false

    static let tileWidthRange = 88.0...460.0

    var body: some View {
        HStack(spacing: 6) {
            OrganizeFilterButton(isPresented: $filterPresented, search: workspace.search)
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
                BoardSortMenuContent(sort: $sort, grouping: grouping)
            } label: {
                Label(compact ? "Sort" : "Sort: \(sort.summary)", systemImage: "arrow.up.arrow.down")
                    .labelStyle(iconOnlyMenus ? AnyBoardLabelStyle(.iconOnly) : AnyBoardLabelStyle(.titleAndIcon))
            }
            .menuIndicator(compact ? .hidden : .visible)
            .fixedSize()
            .help("Sort: \(sort.key.title), \(sort.key.directionTitle(ascending: sort.ascending))")
            .accessibilityLabel("Sort, \(sort.summary)")
            Menu {
                BoardGroupMenuContent(
                    workspace: workspace,
                    groups: groups,
                    grouping: $grouping,
                    groupings: groupings,
                    tileWidth: compact && mode == .tiles ? $tileWidth : nil
                )
            } label: {
                Label(compact ? "Group" : "Group: \(grouping.title)", systemImage: "rectangle.3.group")
                    .labelStyle(iconOnlyMenus ? AnyBoardLabelStyle(.iconOnly) : AnyBoardLabelStyle(.titleAndIcon))
            }
            .menuIndicator(compact ? .hidden : .visible)
            .fixedSize()
            .help("Group the board by \(grouping.title.lowercased()), or collapse its groups")
            .accessibilityLabel("Group, \(grouping.title)")
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

/// The Sort menu's items, in their own view so they are built with the
/// menu rather than on every board render: the key, then its direction
/// worded for that key ("Largest First"). Picking a new key starts it in
/// its natural direction — biggest bursts and files first, oldest time
/// and A–Z names first.
private struct BoardSortMenuContent: View {
    @Binding var sort: OrganizeStackSort
    let grouping: OrganizeBoardGrouping

    var body: some View {
        Picker("Sort By", selection: Binding(
            get: { sort.key },
            set: { sort = OrganizeStackSort(key: $0) }
        )) {
            ForEach(OrganizeSortKey.allCases) { key in
                Label(key.title, systemImage: key.symbol).tag(key)
            }
        }
        .pickerStyle(.inline)
        Picker("Order", selection: $sort.ascending) {
            Label(sort.key.directionTitle(ascending: true), systemImage: "arrow.up").tag(true)
            Label(sort.key.directionTitle(ascending: false), systemImage: "arrow.down").tag(false)
        }
        .pickerStyle(.inline)
        if grouping != .ungrouped && sort.key != .captureTime {
            Divider()
            Text("Sorted within each \(grouping.title.lowercased()) group. Group by None to sort the whole board.")
        }
    }
}

/// The Group menu's items: the grouping, Expand/Collapse All, and — in a
/// compact bar — Larger/Smaller Tiles in place of the slider.
private struct BoardGroupMenuContent: View {
    let workspace: EventsWorkspace
    let groups: [OrganizeBoardGroup]
    @Binding var grouping: OrganizeBoardGrouping
    let groupings: [OrganizeBoardGrouping]
    /// Set in compact bars, where the slider is not shown.
    var tileWidth: Binding<Double>?

    var body: some View {
        Picker("Group By", selection: $grouping) {
            ForEach(groupings) { option in
                Label(option.title, systemImage: option.symbol).tag(option)
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

/// Picks between two label styles at runtime.
private struct AnyBoardLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
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
