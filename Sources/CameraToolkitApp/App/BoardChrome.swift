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
    /// The ids of the board's groups — what Expand or Collapse All acts on.
    /// Ids, not the groups: a bar handed the groups drew again every time a
    /// stack changed, which a move does three times.
    let groupIDs: [String]
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
                    groupIDs: groupIDs,
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
    let groupIDs: [String]
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
        let anyCollapsed = groupIDs.contains { workspace.collapsedGroupIDs.contains($0) }
        Button(anyCollapsed ? "Expand All Groups" : "Collapse All Groups") {
            workspace.setAllGroupsCollapsed(!anyCollapsed, groupIDs: groupIDs)
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
    /// Read while the status line draws, so the bar itself does not depend on
    /// the loading state it reports.
    var loadingNote: () -> String? = { nil }
    /// A trailing hint, shown after the status when there is room.
    var hint: String? = nil
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 6) {
            ApplyBannerSlot(model: model, workspace: workspace)
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

/// The running apply's progress banner, when there is one. Its own view: the
/// job list and the running apply change with every job that starts or ends,
/// and the bar around the controls has no reason to re-run for them.
private struct ApplyBannerSlot: View {
    let model: DashboardModel
    let workspace: EventsWorkspace

    var body: some View {
        if let running = workspace.runningApply,
           model.jobs.contains(where: { $0.id == running.jobID && $0.state == .running }) {
            ApplyProgressBanner(running: running)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The caption under the bottom bar: a running job with its progress,
/// board loading progress, or `statusMessage`.
private struct BoardStatusLine: View {
    @Bindable var model: DashboardModel
    let loadingNote: () -> String?
    let hint: String?

    var body: some View {
        HStack(spacing: 8) {
            if let job = model.activeJob {
                ProgressView(value: job.progress)
                    .controlSize(.small)
                    .frame(width: 120)
                Text(job.note)
                    .truncationMode(.middle)
            } else if let loadingNote = loadingNote() {
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

// MARK: - Width-adaptive bars

/// Which rendering of a bar to show, given the width it has. Renderings run
/// from the widest (tier 0) to the narrowest. `naturals[t]` is the width
/// tier `t` was last measured at, nil until it has been shown once.
///
/// The bar moves one tier at a time and only on what was measured, so a
/// width the bar fits in never changes anything: it steps down when the
/// shown tier is wider than the space, and back up when the next wider tier
/// — as last measured — fits. Both moves use the same numbers, so a width
/// cannot flip between two tiers.
enum AdaptiveBarChoice {
    static func tier(current: Int, tierCount: Int, available: Double, naturals: [Double?]) -> Int {
        guard tierCount > 1, naturals.indices.contains(current) else { return current }
        if let natural = naturals[current], natural > available + 0.5, current < tierCount - 1 {
            return current + 1
        }
        if current > 0, let wider = naturals[current - 1], wider <= available {
            return current - 1
        }
        return current
    }
}

/// What an `AdaptiveBar` has measured. Reference-typed and unobserved:
/// layout reports into it, and only a changed choice becomes state.
@MainActor
final class AdaptiveBarProbe {
    var tierCount = 1
    var available: Double?
    var naturals: [Double?] = []
    var tier = 0
    var apply: (Int) -> Void = { _ in }
    private var pending = false

    func measured(natural: Double, forTier tier: Int) {
        guard tier == self.tier else { return }
        if naturals.count < tierCount { naturals += Array(repeating: nil, count: tierCount - naturals.count) }
        guard naturals[tier] != natural else { return }
        naturals[tier] = natural
        evaluate()
    }

    func measured(available width: Double) {
        guard available != width else { return }
        available = width
        evaluate()
    }

    /// Steps toward the tier that fits. Applied on the next turn of the run
    /// loop, never from inside a layout pass.
    private func evaluate() {
        guard let available, !pending else { return }
        let next = AdaptiveBarChoice.tier(current: tier, tierCount: tierCount, available: available, naturals: naturals)
        guard next != tier else { return }
        pending = true
        DispatchQueue.main.async { [self] in
            pending = false
            guard let available = self.available else { return }
            let target = AdaptiveBarChoice.tier(current: tier, tierCount: tierCount, available: available, naturals: naturals)
            guard target != tier else { return }
            tier = target
            apply(target)
        }
    }
}

/// Reports the natural width of its one child during layout, then lays it
/// out exactly as the child asks. `ViewThatFits` builds and measures every
/// candidate again whenever anything around it changes — for a bottom bar
/// beside a status line that ticks with job progress, that was a full
/// re-measure of every candidate ten times a second while scrolling. This
/// measures the one child that is shown.
private struct NaturalWidthLayout: Layout {
    let report: (Double) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        report(Double(subview.sizeThatFits(.unspecified).width))
        subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// A bar that shows the widest of its `tierCount` renderings that fits.
/// Only the shown rendering exists: a width change measures once and
/// switches once, and nothing re-measures while the bar's width is steady.
/// Renderings must keep one view structure (they differ in parameters), so
/// a switch never re-presents a popover or sheet attached to the bar.
struct AdaptiveBar<Content: View>: View {
    /// Where the last tier is remembered, so a board opened again starts at
    /// the tier its width settled on instead of stepping down from the widest.
    let id: String
    let tierCount: Int
    @ViewBuilder let content: (Int) -> Content

    @State private var tier: Int
    @State private var probe = AdaptiveBarProbe()

    init(id: String, tierCount: Int, @ViewBuilder content: @escaping (Int) -> Content) {
        self.id = id
        self.tierCount = tierCount
        self.content = content
        _tier = State(initialValue: min(RememberedTiers.shared.tiers[id] ?? 0, tierCount - 1))
    }

    var body: some View {
        let _ = configureProbe()
        NaturalWidthLayout(report: { [probe, tier] width in
            MainActor.assumeIsolated { probe.measured(natural: width, forTier: tier) }
        }) {
            content(tier)
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
            probe.measured(available: width)
        }
    }

    @MainActor
    private func configureProbe() -> Bool {
        probe.tierCount = tierCount
        probe.tier = tier
        let id = id
        let setTier = _tier
        probe.apply = { next in
            setTier.wrappedValue = next
            RememberedTiers.shared.tiers[id] = next
        }
        return true
    }
}

/// The last tier each bar settled on, for the life of the app.
@MainActor
final class RememberedTiers {
    static let shared = RememberedTiers()
    var tiers: [String: Int] = [:]
}
