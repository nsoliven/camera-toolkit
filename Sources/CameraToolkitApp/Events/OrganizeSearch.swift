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

    /// Every row carrying picks, in panel order — the board header's
    /// hot-link chips. Paused rows stay listed (they draw as outlines);
    /// a row with no values never chips.
    var rowsWithValues: [OrganizeFilterRow] {
        groups.flatMap(\.rows).filter(\.hasValues)
    }

    /// Whether any row reads the face catalog — boards skip the
    /// people-by-stack index unless a People row is filtering.
    var needsPeople: Bool {
        groups.contains { group in
            group.rows.contains { $0.property == .people && !$0.isEmpty }
        }
    }

    /// The same filter with every Event pick outside `familyIDs` removed,
    /// and "Not Sorted Yet" cleared — a family board's stacks all belong to
    /// it, so only in-family picks can narrow it. An Event row left with no
    /// in-family pick stops filtering instead of emptying the board, which
    /// keeps an unsorted board's carried-over picks from blanking it.
    func scopingEventRows(to familyIDs: Set<UUID>) -> OrganizeSearchFilter {
        var copy = self
        copy.groups = groups.map { group in
            var scoped = group
            scoped.rows = scoped.rows.map { row in
                guard row.property == .event else { return row }
                var narrowed = row
                narrowed.eventIDs.formIntersection(familyIDs)
                narrowed.includesUnsorted = false
                return narrowed
            }
            return scoped
        }
        return copy
    }

    /// Event ids an enabled "is none of" Event row excludes — a header
    /// chip's outline state: the tag's photos are filtered out. A paused
    /// exclusion row keeps its picks but hides nothing, so it does not
    /// mark the chip.
    var excludedEventIDs: Set<UUID> {
        groups.reduce(into: Set<UUID>()) { ids, group in
            for row in group.rows
            where row.property == .event && row.operator == .noneOf && row.isEnabled {
                ids.formUnion(row.eventIDs)
            }
        }
    }

    /// Toggles "is none of" for an event pick — the header chips' action.
    /// Adding joins an "is none of" Event row in every group (creating the
    /// rows, and a group when none exist) so the tag's photos drop no
    /// matter which OR-group a stack matches; removing takes the id out of
    /// every such row and drops the husk it leaves behind.
    mutating func toggleEventExclusion(_ id: UUID) {
        if excludedEventIDs.contains(id) {
            for groupIndex in groups.indices {
                for rowIndex in groups[groupIndex].rows.indices
                where groups[groupIndex].rows[rowIndex].property == .event
                    && groups[groupIndex].rows[rowIndex].operator == .noneOf {
                    groups[groupIndex].rows[rowIndex].eventIDs.remove(id)
                }
                groups[groupIndex].rows.removeAll {
                    $0.property == .event && $0.operator == .noneOf && !$0.hasValues
                }
            }
            groups.removeAll { $0.rows.isEmpty }
        } else if groups.isEmpty {
            groups = [OrganizeFilterGroup(rows: [.events([id], operator: .noneOf)])]
        } else {
            for groupIndex in groups.indices {
                if let rowIndex = groups[groupIndex].rows.firstIndex(where: {
                    $0.property == .event && $0.operator == .noneOf
                }) {
                    groups[groupIndex].rows[rowIndex].eventIDs.insert(id)
                    // A paused exclusion row resumes — the chip tap must
                    // hide the tag's photos, not edit a suspended row.
                    groups[groupIndex].rows[rowIndex].isEnabled = true
                } else {
                    groups[groupIndex].rows.append(.events([id], operator: .noneOf))
                }
            }
        }
    }

    /// Flips one row's `isEnabled` — the header hot links' tap: pause the
    /// row without deleting its picks, tap again to resume filtering.
    mutating func toggleRow(_ id: UUID) {
        for groupIndex in groups.indices {
            if let rowIndex = groups[groupIndex].rows.firstIndex(where: { $0.id == id }) {
                groups[groupIndex].rows[rowIndex].isEnabled.toggle()
                return
            }
        }
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

    /// List-property operators — the four cells of a row's truth table
    /// over its picks. "any" keeps a subject sharing one pick, "all"
    /// keeps only a subject carrying every pick, and the "none"/"not
    /// all" pair negates them. Date rows are always a from/to range and
    /// ignore the operator.
    enum Operator: String, CaseIterable, Sendable {
        /// "is any of" — the subject shares a picked value.
        case anyOf
        /// "is all of" — the subject carries every picked value.
        case allOf
        /// "is none of" — the subject drops when it has a picked value.
        case noneOf
        /// "is not all of" — the subject is missing a picked value.
        case notAllOf

        var title: String {
            switch self {
            case .anyOf: "is any of"
            case .allOf: "is all of"
            case .noneOf: "is none of"
            case .notAllOf: "is not all of"
            }
        }

        /// The verdict from the subject's two set facts: whether it
        /// carries any pick and whether it carries them all.
        func matches(hasAny: Bool, hasAll: Bool) -> Bool {
            switch self {
            case .anyOf: hasAny
            case .allOf: hasAll
            case .noneOf: !hasAny
            case .notAllOf: !hasAll
            }
        }
    }

    var id = UUID()
    var property: Property
    var `operator`: Operator = .anyOf
    /// Whether the row filters. The board header's hot links flip this —
    /// off keeps the row and its picks but suspends the match, and the
    /// chip draws as an outline until tapped again.
    var isEnabled = true
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

    init(id: UUID = UUID(), property: Property, operator: Operator = .anyOf) {
        self.id = id
        self.property = property
        self.operator = `operator`
    }

    /// A People row; `exclude: true` makes it "is none of".
    static func people(_ ids: Set<UUID>, exclude: Bool = false) -> Self {
        people(ids, operator: exclude ? .noneOf : .anyOf)
    }

    /// A People row with an explicit operator — the full truth table.
    static func people(_ ids: Set<UUID>, operator op: Operator) -> Self {
        var row = Self(property: .people, operator: op)
        row.peopleIDs = ids
        return row
    }

    /// An Event row; `unsorted` adds the "Not Sorted Yet" pseudo-value.
    static func events(_ ids: Set<UUID>, unsorted: Bool = false, exclude: Bool = false) -> Self {
        events(ids, unsorted: unsorted, operator: exclude ? .noneOf : .anyOf)
    }

    /// An Event row with an explicit operator — the full truth table.
    static func events(_ ids: Set<UUID>, unsorted: Bool = false, operator op: Operator) -> Self {
        var row = Self(property: .event, operator: op)
        row.eventIDs = ids
        row.includesUnsorted = unsorted
        return row
    }

    /// A Media row; `exclude: true` makes it "is none of".
    static func media(_ kinds: Set<OrganizeMediaKind>, exclude: Bool = false) -> Self {
        media(kinds, operator: exclude ? .noneOf : .anyOf)
    }

    /// A Media row with an explicit operator — the full truth table.
    static func media(_ kinds: Set<OrganizeMediaKind>, operator op: Operator) -> Self {
        var row = Self(property: .media, operator: op)
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

    /// The row holds at least one picked value — independent of
    /// `isEnabled`, so a paused row still counts for chips and cleanup.
    var hasValues: Bool {
        switch property {
        case .people: !peopleIDs.isEmpty
        case .event: !eventIDs.isEmpty || includesUnsorted
        case .media: !mediaKinds.isEmpty
        case .date: dayStart != nil || dayEnd != nil
        }
    }

    /// A row carrying no values — or switched off — never filters: it
    /// sits in the panel waiting for a pick or a tap on its chip.
    var isEmpty: Bool {
        !isEnabled || !hasValues
    }

    /// Switching property starts the row over — the old values would
    /// otherwise linger invisibly under the new property.
    mutating func setProperty(_ new: Property) {
        guard new != property else { return }
        self = OrganizeFilterRow(id: id, property: new)
    }

    /// The row's test against one subject — boards pass a stack's facts,
    /// the sidebar an event's. An empty or switched-off row passes.
    /// "is any of" keeps a subject sharing a pick, "is all of" keeps only
    /// a subject carrying them all, "is none of" drops it on a shared
    /// pick, and "is not all of" drops it only when it carries them all.
    func matches(subject: OrganizeFilterSubject, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return true }
        switch property {
        case .people:
            guard !peopleIDs.isEmpty else { return true }
            return `operator`.matches(
                hasAny: !subject.personIDs.isDisjoint(with: peopleIDs),
                hasAll: peopleIDs.isSubset(of: subject.personIDs)
            )
        case .event:
            guard !eventIDs.isEmpty || includesUnsorted else { return true }
            // "Not Sorted Yet" counts as a picked value the subject
            // carries only while it has no event at all.
            return `operator`.matches(
                hasAny: !subject.eventIDs.isDisjoint(with: eventIDs)
                    || (includesUnsorted && subject.eventIDs.isEmpty),
                hasAll: eventIDs.isSubset(of: subject.eventIDs)
                    && (!includesUnsorted || subject.eventIDs.isEmpty)
            )
        case .media:
            guard !mediaKinds.isEmpty else { return true }
            return `operator`.matches(
                hasAny: !subject.mediaKinds.isDisjoint(with: mediaKinds),
                hasAll: mediaKinds.isSubset(of: subject.mediaKinds)
            )
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
