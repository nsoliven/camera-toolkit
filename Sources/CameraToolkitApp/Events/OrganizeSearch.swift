import CameraToolkitCore
import Foundation

/// The structured filters behind the board's search field — the builder
/// panel that opens under it. Conditions are rows grouped into
/// conjunctions: every non-empty row in a group must match, and a stack
/// stays when any group does (an OR of AND-groups). Text stays free-form —
/// file name, burst label, origin subfolder, or event title — and ANDs
/// with the groups. An empty builder never filters.
struct OrganizeSearchFilter: Equatable, Sendable {
    /// Raw text of the search field — normalized through `needle`.
    var text = ""
    /// The AND-groups of condition rows, ORed at match time. May be
    /// empty; groups whose rows are all empty apply no condition.
    var groups: [OrganizeFilterGroup] = []

    /// No filtering at all — empty text and no active condition rows.
    /// The board shows everything.
    var isEmpty: Bool {
        OrganizeSearch.needle(text).isEmpty && !hasActiveConditions
    }

    /// Nothing to reset — no text and no rows at all, so Clear All has
    /// nothing to clear (a group of empty rows is still a row).
    var isUntouched: Bool {
        OrganizeSearch.needle(text).isEmpty && groups.isEmpty
    }

    /// Any group holding at least one non-empty row — the builder is
    /// actually narrowing the board.
    var hasActiveConditions: Bool {
        groups.contains { !$0.isEmpty }
    }

    /// Non-empty condition rows across every group — the funnel button's
    /// badge count.
    var activeRowCount: Int {
        groups.reduce(0) { $0 + $1.rows.filter { !$0.isEmpty }.count }
    }

    /// Whether any row reads the face catalog — boards skip the
    /// people-by-stack index unless a People row is filtering.
    var needsPeople: Bool {
        groups.contains { group in
            group.rows.contains { $0.property == .people && !$0.peopleIDs.isEmpty }
        }
    }

    /// The same filter minus every Event row. An event board is one event
    /// already, so picks carried over from an unsorted board's panel are
    /// dropped there rather than emptying the board.
    func droppingEventRows() -> OrganizeSearchFilter {
        var copy = self
        copy.groups = groups.map { group in
            var scoped = group
            scoped.rows = scoped.rows.filter { $0.property != .event }
            return scoped
        }
        return copy
    }
}

/// A conjunction of condition rows — every row must match for the group
/// to keep a subject. Groups OR inside `OrganizeSearchFilter`.
struct OrganizeFilterGroup: Equatable, Sendable, Identifiable {
    var id = UUID()
    var rows: [OrganizeFilterRow] = []

    /// A group whose rows are all empty applies no condition and is
    /// skipped in the OR — an unfinished group must not silently widen
    /// the match to everything.
    var isEmpty: Bool { rows.allSatisfy(\.isEmpty) }
}

/// One condition row in the filter builder: a property, an operator, and
/// the values it tests. Several values sit in one row and each can be
/// removed on its own; a row with no values never filters.
struct OrganizeFilterRow: Equatable, Sendable, Identifiable {
    /// The stack fact the row tests.
    enum Property: String, CaseIterable, Sendable {
        case people, event, media, date

        var title: String {
            switch self {
            case .people: "People"
            case .event: "Event"
            case .media: "Media"
            case .date: "Date"
            }
        }
    }

    /// List-property operators. Date rows are always a from/to range and
    /// ignore the operator.
    enum Operator: String, CaseIterable, Sendable {
        /// "is any of" — the subject keeps any picked value.
        case include
        /// "is none of" — the subject drops when it has a picked value.
        case exclude

        var title: String {
            switch self {
            case .include: "is any of"
            case .exclude: "is none of"
            }
        }
    }

    var id = UUID()
    var property: Property
    var `operator`: Operator = .include
    /// Values for a People row — roster people or unnamed face groups.
    var peopleIDs: Set<UUID> = []
    /// Values for an Event row.
    var eventIDs: Set<UUID> = []
    /// The "Not Sorted Yet" pseudo-value among an Event row's picks.
    var includesUnsorted = false
    /// Values for a Media row — stills, RAW, video.
    var mediaKinds: Set<OrganizeMediaKind> = []
    /// Inclusive day bounds for a Date row, matched at the camera wall
    /// clock's day granularity — the same day bucketing
    /// `OrganizeStacker.days` uses.
    var dayStart: Date?
    var dayEnd: Date?

    init(id: UUID = UUID(), property: Property, operator: Operator = .include) {
        self.id = id
        self.property = property
        self.operator = `operator`
    }

    /// A People row; `exclude: true` makes it "is none of".
    static func people(_ ids: Set<UUID>, exclude: Bool = false) -> Self {
        var row = Self(property: .people, operator: exclude ? .exclude : .include)
        row.peopleIDs = ids
        return row
    }

    /// An Event row; `unsorted` adds the "Not Sorted Yet" pseudo-value.
    static func events(_ ids: Set<UUID>, unsorted: Bool = false, exclude: Bool = false) -> Self {
        var row = Self(property: .event, operator: exclude ? .exclude : .include)
        row.eventIDs = ids
        row.includesUnsorted = unsorted
        return row
    }

    /// A Media row; `exclude: true` makes it "is none of".
    static func media(_ kinds: Set<OrganizeMediaKind>, exclude: Bool = false) -> Self {
        var row = Self(property: .media, operator: exclude ? .exclude : .include)
        row.mediaKinds = kinds
        return row
    }

    /// A Date row — either bound may stay open.
    static func days(from start: Date?, to end: Date?) -> Self {
        var row = Self(property: .date)
        row.dayStart = start
        row.dayEnd = end
        return row
    }

    /// A row carrying no values never filters — it sits in the panel
    /// waiting for a pick.
    var isEmpty: Bool {
        switch property {
        case .people: peopleIDs.isEmpty
        case .event: eventIDs.isEmpty && !includesUnsorted
        case .media: mediaKinds.isEmpty
        case .date: dayStart == nil && dayEnd == nil
        }
    }

    /// Switching property starts the row over — the old values would
    /// otherwise linger invisibly under the new property.
    mutating func setProperty(_ new: Property) {
        guard new != property else { return }
        self = OrganizeFilterRow(id: id, property: new)
    }

    /// The row's test against one subject — boards pass a stack's facts,
    /// the sidebar an event's. An empty row passes; an include row keeps
    /// the subject when it has any picked value; an exclude row drops it
    /// when any of its files carries a picked person, event, or kind.
    func matches(subject: OrganizeFilterSubject, calendar: Calendar = .current) -> Bool {
        switch property {
        case .people:
            guard !peopleIDs.isEmpty else { return true }
            return `operator` == .include
                ? !subject.personIDs.isDisjoint(with: peopleIDs)
                : subject.personIDs.isDisjoint(with: peopleIDs)
        case .event:
            guard !eventIDs.isEmpty || includesUnsorted else { return true }
            if `operator` == .include {
                return !subject.eventIDs.isDisjoint(with: eventIDs)
                    || (includesUnsorted && subject.eventIDs.isEmpty)
            }
            return subject.eventIDs.isDisjoint(with: eventIDs)
                && !(includesUnsorted && subject.eventIDs.isEmpty)
        case .media:
            guard !mediaKinds.isEmpty else { return true }
            let hasKind = !subject.mediaKinds.isDisjoint(with: mediaKinds)
            return `operator` == .include ? hasKind : !hasKind
        case .date:
            guard dayStart != nil || dayEnd != nil, let span = subject.daySpan else { return true }
            let lower = dayStart.map { calendar.startOfDay(for: $0) } ?? .distantPast
            let upper = dayEnd.map {
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) ?? .distantFuture
            } ?? .distantFuture
            return span.lowerBound < upper && span.upperBound >= lower
        }
    }
}

/// The facts one condition row evaluates — one stack's or one sidebar
/// event's resolved data. Boards build it from a stack plus its
/// `OrganizeStackFacts`; the sidebar builds it per event.
struct OrganizeFilterSubject: Equatable, Sendable {
    /// Roster people and unnamed groups detected on the subject's files.
    var personIDs: Set<UUID> = []
    /// Events the subject's files are assigned to — a partially or
    /// multiply assigned stack carries all of its events; a sidebar event
    /// carries itself. Empty means "Not Sorted Yet".
    var eventIDs: Set<UUID> = []
    /// Media kinds present on the subject's files — stills, RAW, video.
    var mediaKinds: Set<OrganizeMediaKind> = []
    /// The subject's capture interval, matched against a Date row's day
    /// bounds. Nil means the subject has no dates and never filters on
    /// one.
    var daySpan: ClosedRange<Date>?

    init(
        personIDs: Set<UUID> = [],
        eventIDs: Set<UUID> = [],
        mediaKinds: Set<OrganizeMediaKind> = [],
        daySpan: ClosedRange<Date>? = nil
    ) {
        self.personIDs = personIDs
        self.eventIDs = eventIDs
        self.mediaKinds = mediaKinds
        self.daySpan = daySpan
    }

    /// A board stack's subject — the same stack facts the old facet
    /// filter read: assigned events and face-catalog people, plus the
    /// item kinds and capture interval the stack itself reports.
    init(stack: OrganizeStack, facts: OrganizeStackFacts) {
        self.init(
            personIDs: facts.personIDs,
            eventIDs: facts.eventIDs,
            mediaKinds: Set(stack.items.map(\.kind)),
            daySpan: min(stack.captureDate, stack.endDate)...max(stack.captureDate, stack.endDate)
        )
    }
}

/// Per-stack facts the workspace resolves for structured matching — the
/// stack's assigned events and the face-catalog people on its files.
/// Kept out of `OrganizeStack` so scanning stays free of lookups.
struct OrganizeStackFacts: Equatable, Sendable {
    /// Every distinct event an item in the stack is assigned to — a
    /// partially or multiply assigned stack matches any of its events.
    var eventIDs: Set<UUID> = []
    /// Breadcrumb title when the stack lands in exactly one event — the
    /// text needle's event match, unchanged from before.
    var eventTitle: String?
    /// Roster people and unnamed groups detected on the stack's files.
    var personIDs: Set<UUID> = []
    /// Display names of those people and groups — the text needle's person
    /// match, so typing a roster name finds the same stacks a People row
    /// would.
    var personNames: Set<String> = []
}

/// Lowercase-contains text matching for the Events sidebar and the organize
/// board, plus the OR-of-AND-groups structured match the filter builder
/// produces. Everything runs over already-scanned data — no filesystem
/// access.
enum OrganizeSearch {
    /// The normalized query: trimmed and lowercased. An empty needle means
    /// "no filter" and callers should show everything.
    static func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func matches(_ text: String?, needle: String) -> Bool {
        guard let text else { return false }
        return text.lowercased().contains(needle)
    }

    /// A stack matches when the query hits any file name in it, its burst
    /// label ("B0001"), its origin subfolder relative to the scan root, the
    /// breadcrumb title of the event it is sorted into, or the name of a
    /// person or group whose face sits on one of its files.
    static func matches(
        stack: OrganizeStack,
        needle: String,
        rootPath: String?,
        eventTitle: String?,
        personNames: Set<String> = []
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        if matches(stack.burstLabel, needle: needle) { return true }
        // Stacks never span folders, so the first item's folder is the stack's.
        if let folderPath = stack.items.first?.primary.folderPath,
           matches(
               OrganizeFolderLabel.subfolder(forFolderPath: folderPath, rootPath: rootPath),
               needle: needle
           ) { return true }
        if stack.files.contains(where: { matches($0.name, needle: needle) }) { return true }
        if matches(eventTitle, needle: needle) { return true }
        return personNames.contains { matches($0, needle: needle) }
    }

    /// The builder's structured match: an OR of AND-groups. Groups whose
    /// rows are all empty are skipped — a row with no values does not
    /// filter, so an unfinished group must not widen the match either. No
    /// active group passes everything.
    static func matches(
        subject: OrganizeFilterSubject,
        search: OrganizeSearchFilter,
        calendar: Calendar = .current
    ) -> Bool {
        let activeGroups = search.groups.filter { !$0.isEmpty }
        guard !activeGroups.isEmpty else { return true }
        return activeGroups.contains { group in
            group.rows.allSatisfy { $0.matches(subject: subject, calendar: calendar) }
        }
    }

    /// The full board match: the text needle plus the builder's groups,
    /// ANDed. `facts` carries the stack's resolved event and people data;
    /// an empty `search` passes everything.
    static func matches(
        stack: OrganizeStack,
        search: OrganizeSearchFilter,
        rootPath: String?,
        facts: OrganizeStackFacts,
        calendar: Calendar = .current
    ) -> Bool {
        guard matches(
            stack: stack,
            needle: needle(search.text),
            rootPath: rootPath,
            eventTitle: facts.eventTitle,
            personNames: facts.personNames
        ) else { return false }

        return matches(
            subject: OrganizeFilterSubject(stack: stack, facts: facts),
            search: search,
            calendar: calendar
        )
    }
}
