import CameraToolkitCore
import Foundation

/// What the window's one search field searches. The board scope filters
/// the open board's stacks (`OrganizeSearchFilter.text`); the sidebar scope
/// narrows the sidebar's folders and events instead, so a file-name query
/// never empties the sidebar and hides the selected row.
enum OrganizeSearchScope: String, Hashable, Sendable {
    case board
    case sidebar

    /// The scope a fresh search starts in: the open board, or the sidebar
    /// when no board is open (the welcome view).
    static func defaultScope(hasBoard: Bool) -> OrganizeSearchScope {
        hasBoard ? .board : .sidebar
    }
}

/// The structured filters behind the board's search field — the builder
/// panel that opens under it. Conditions are rows grouped into
/// conjunctions: every non-empty row in a group must match, and a stack
/// stays when any group does (an OR of AND-groups). Text stays free-form —
/// file name, burst label, origin subfolder, or event title — and ANDs
/// with the groups. An empty builder never filters.
///
/// On top of the groups sits one board-level exclusion list, written by
/// the event board's subevent chips: an event struck through there hides
/// its stacks whatever the groups say. The full match is
/// `text ∧ ¬excluded ∧ (no active group ∨ some group matches)`.
struct OrganizeSearchFilter: Equatable, Sendable {
    /// Raw text of the search field — normalized through `needle`.
    var text = ""
    /// The AND-groups of condition rows, ORed at match time. May be
    /// empty; groups whose rows are all empty apply no condition.
    var groups: [OrganizeFilterGroup] = []
    /// Events whose stacks are always hidden — the header chips'
    /// strikethrough. ANDed with the whole filter, never with one group,
    /// so an OR-group added later cannot bring the excluded photos back.
    /// Hand-built "Event is none of" rows stay rows and keep their
    /// per-group meaning; only chip toggles write here.
    var excludedEventIDs: Set<UUID> = []

    /// No filtering at all — empty text, no exclusions, and no active
    /// condition rows. The board shows everything.
    var isEmpty: Bool {
        OrganizeSearch.needle(text).isEmpty && !hasActiveConditions
    }

    /// Nothing to reset — no text, no exclusions, and no rows at all, so
    /// Clear All has nothing to clear (a group of empty rows is still a
    /// row).
    var isUntouched: Bool {
        OrganizeSearch.needle(text).isEmpty && groups.isEmpty && excludedEventIDs.isEmpty
    }

    /// Any board-level exclusion, or any group holding at least one
    /// non-empty row — the builder is actually narrowing the board.
    var hasActiveConditions: Bool {
        !excludedEventIDs.isEmpty || groups.contains { !$0.isEmpty }
    }

    /// Non-empty condition rows across every group, plus the board-level
    /// exclusions — the funnel button's badge count.
    var activeRowCount: Int {
        groups.reduce(excludedEventIDs.count) { $0 + $1.rows.filter { !$0.isEmpty }.count }
    }

    /// Every row carrying picks, in panel order — the board header's
    /// hot-link chips. Paused rows stay listed (they draw as outlines);
    /// a row with no values never chips. Board-level exclusions are not
    /// rows: the subevent chips and the panel's "Always hiding" section
    /// show them.
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

    /// Whether any row tests cameras — boards resolve each frame's camera
    /// only while a Camera row is filtering.
    var needsCameras: Bool {
        groups.contains { group in
            group.rows.contains { $0.property == .camera && !$0.isEmpty }
        }
    }

    /// The Camera row a header chip edits: the first switched-on
    /// "is any of" Camera row, if any.
    private var chipCameraRowPath: (group: Int, row: Int)? {
        for groupIndex in groups.indices {
            if let rowIndex = groups[groupIndex].rows.firstIndex(where: {
                $0.property == .camera && $0.operator == .anyOf && $0.isEnabled
            }) {
                return (groupIndex, rowIndex)
            }
        }
        return nil
    }

    /// Whether a header chip for `cameraID` reads as on — its camera is
    /// picked in the Camera row the chips edit.
    func isCameraChipOn(_ cameraID: String) -> Bool {
        guard let path = chipCameraRowPath else { return false }
        return groups[path.group].rows[path.row].cameraIDs.contains(cameraID)
    }

    /// A camera chip's click: adds the camera to the board's "Camera is
    /// any of" row (creating it, ANDed like any other condition), or takes
    /// it back out — dropping the row once it holds no camera. Other
    /// Camera rows the user built keep their meaning.
    mutating func toggleCameraChip(_ cameraID: String) {
        guard let path = chipCameraRowPath else {
            addCondition(.cameras([cameraID]))
            return
        }
        var row = groups[path.group].rows[path.row]
        if row.cameraIDs.contains(cameraID) {
            row.cameraIDs.remove(cameraID)
        } else {
            row.cameraIDs.insert(cameraID)
        }
        if row.cameraIDs.isEmpty {
            groups[path.group].rows.remove(at: path.row)
            if groups[path.group].rows.isEmpty {
                groups.remove(at: path.group)
            }
        } else {
            groups[path.group].rows[path.row] = row
        }
    }

    /// The same filter with every Event pick outside `familyIDs` removed,
    /// and "Not Sorted Yet" cleared — a family board's stacks all belong to
    /// it, so only in-family picks can narrow it. An Event row left with no
    /// in-family pick stops filtering instead of emptying the board, which
    /// keeps an unsorted board's carried-over picks from blanking it. The
    /// board-level exclusions narrow the same way.
    func scopingEventRows(to familyIDs: Set<UUID>) -> OrganizeSearchFilter {
        var copy = self
        copy.excludedEventIDs.formIntersection(familyIDs)
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

    /// Toggles the board-level exclusion for one event — the header
    /// chips' action. It never edits the condition groups, so rows the
    /// user built by hand keep their meaning and the exclusion keeps
    /// applying to groups added after it.
    mutating func toggleEventExclusion(_ id: UUID) {
        if excludedEventIDs.contains(id) {
            excludedEventIDs.remove(id)
        } else {
            excludedEventIDs.insert(id)
        }
    }

    /// The panel's default add: the row ANDs into the last group (the only
    /// one unless the user deliberately started an "or"), creating it on
    /// the first add. It never opens a new OR branch — each condition
    /// narrows the board.
    mutating func addCondition(_ row: OrganizeFilterRow) {
        if groups.isEmpty {
            groups = [OrganizeFilterGroup(rows: [row])]
        } else {
            groups[groups.count - 1].rows.append(row)
        }
    }

    /// The panel's explicit "or" action — a new group whose match widens
    /// the board rather than narrowing it.
    mutating func addOrGroup(_ row: OrganizeFilterRow) {
        groups.append(OrganizeFilterGroup(rows: [row]))
    }

    /// Drops every condition — the groups and the board-level exclusions —
    /// while keeping the search text. The sidebar's "Filtered — Clear".
    mutating func clearConditions() {
        groups = []
        excludedEventIDs = []
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
        case people, event, media, date, camera

        var title: String {
            switch self {
            case .people: "People"
            case .event: "Event"
            case .media: "Media"
            case .date: "Date"
            case .camera: "Camera"
            }
        }
    }

    /// List-property operators — the four cells of a row's truth table
    /// over its picks. "any" keeps a subject sharing one pick, "all"
    /// keeps only a subject carrying every pick, and the "none"/"not
    /// all" pair negates them. People rows add "is exactly" — the subject's
    /// people are the picks and nobody else — and its negation. Date rows
    /// are always a from/to range and ignore the operator.
    enum Operator: String, CaseIterable, Sendable {
        /// "is any of" — the subject shares a picked value.
        case anyOf
        /// "is all of" — the subject carries every picked value.
        case allOf
        /// "is none of" — the subject drops when it has a picked value.
        case noneOf
        /// "is not all of" — the subject is missing a picked value.
        case notAllOf
        /// "is exactly" — the subject carries every pick and nothing else.
        /// For People, "nothing else" also rules out unnamed groups and
        /// faces never grouped (`OrganizeFilterSubject.hasOtherFaces`).
        case exactly
        /// "is not exactly" — the negation: a pick is missing or someone
        /// else is there too.
        case notExactly

        /// The short form the board header's chips print.
        var title: String {
            switch self {
            case .anyOf: "is any of"
            case .allOf: "is all of"
            case .noneOf: "is none of"
            case .notAllOf: "is not all of"
            case .exactly: "is exactly"
            case .notExactly: "is not exactly"
            }
        }

        /// The operator picker's wording — the exact pair spells out that
        /// nobody else may be in the shot.
        var menuTitle: String {
            switch self {
            case .exactly: "is exactly (only these people)"
            case .notExactly: "is not exactly (not only these people)"
            default: title
            }
        }

        /// The operators a row's picker offers for a property. The exact
        /// pair is People-only: it is what "photos of just these two"
        /// needs, and Event and Media rows have no use for it yet. Date
        /// rows draw no operator picker.
        static func options(for property: Property) -> [Operator] {
            switch property {
            case .people: allCases
            case .event, .media, .date: [.anyOf, .allOf, .noneOf, .notAllOf]
            // A frame has one camera, so "all of" only means something
            // for a mixed burst — the row keeps to any/none.
            case .camera: [.anyOf, .noneOf]
            }
        }

        /// The verdict from the subject's set facts: whether it carries
        /// any pick, whether it carries them all, and whether it carries
        /// the picks and nothing else.
        func matches(hasAny: Bool, hasAll: Bool, isExactly: Bool) -> Bool {
            switch self {
            case .anyOf: hasAny
            case .allOf: hasAll
            case .noneOf: !hasAny
            case .notAllOf: !hasAll
            case .exactly: isExactly
            case .notExactly: !isExactly
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
    /// Values for a Camera row — `OrganizeCamera.id`s, including
    /// `OrganizeCamera.unknownID` for "Unknown camera".
    var cameraIDs: Set<String> = []
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

    /// A Camera row; `exclude: true` makes it "is none of".
    static func cameras(_ ids: Set<String>, exclude: Bool = false) -> Self {
        var row = Self(property: .camera, operator: exclude ? .noneOf : .anyOf)
        row.cameraIDs = ids
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
        case .camera: !cameraIDs.isEmpty
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
    ///
    /// "is exactly" keeps a subject whose people set equals the picks and
    /// that holds no other face — an unnamed group, a "looks like"
    /// suggestion, or a detection never grouped all count as someone
    /// else. A burst is judged on the union of its frames, like every
    /// other operator: frames of A alone and B alone make an "exactly A,
    /// B" burst. A subject with no faces never matches it.
    func matches(subject: OrganizeFilterSubject, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return true }
        switch property {
        case .people:
            guard !peopleIDs.isEmpty else { return true }
            let hasAll = peopleIDs.isSubset(of: subject.personIDs)
            return `operator`.matches(
                hasAny: !subject.personIDs.isDisjoint(with: peopleIDs),
                hasAll: hasAll,
                isExactly: hasAll
                    && subject.personIDs.isSubset(of: peopleIDs)
                    && !subject.hasOtherFaces
            )
        case .event:
            guard !eventIDs.isEmpty || includesUnsorted else { return true }
            // "Not Sorted Yet" counts as a picked value the subject
            // carries only while it has no event at all.
            let hasAll = eventIDs.isSubset(of: subject.eventIDs)
                && (!includesUnsorted || subject.eventIDs.isEmpty)
            return `operator`.matches(
                hasAny: !subject.eventIDs.isDisjoint(with: eventIDs)
                    || (includesUnsorted && subject.eventIDs.isEmpty),
                hasAll: hasAll,
                isExactly: hasAll && subject.eventIDs.isSubset(of: eventIDs)
            )
        case .media:
            guard !mediaKinds.isEmpty else { return true }
            let hasAll = mediaKinds.isSubset(of: subject.mediaKinds)
            return `operator`.matches(
                hasAny: !subject.mediaKinds.isDisjoint(with: mediaKinds),
                hasAll: hasAll,
                isExactly: hasAll && subject.mediaKinds.isSubset(of: mediaKinds)
            )
        case .camera:
            guard !cameraIDs.isEmpty else { return true }
            let hasAll = cameraIDs.isSubset(of: subject.cameraIDs)
            return `operator`.matches(
                hasAny: !subject.cameraIDs.isDisjoint(with: cameraIDs),
                hasAll: hasAll,
                isExactly: hasAll && subject.cameraIDs.isSubset(of: cameraIDs)
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
    /// People on the subject's files — for a board stack, the approved
    /// people with a confirmed face there.
    var personIDs: Set<UUID> = []
    /// Some file also carries a face outside `personIDs` — an unnamed
    /// group, a "looks like" suggestion, or a detection never grouped.
    /// Only "is exactly" reads it. The sidebar's event subjects leave it
    /// false, so there "is exactly" compares approved people only.
    var hasOtherFaces = false
    /// Events the subject's files are assigned to — a partially or
    /// multiply assigned stack carries all of its events; a sidebar event
    /// carries itself. Empty means "Not Sorted Yet".
    var eventIDs: Set<UUID> = []
    /// Media kinds present on the subject's files — stills, RAW, video.
    var mediaKinds: Set<OrganizeMediaKind> = []
    /// Cameras that shot the subject's files — the union over a burst's
    /// frames; a frame with no known camera adds `OrganizeCamera.unknownID`.
    var cameraIDs: Set<String> = []
    /// The subject's capture interval, matched against a Date row's day
    /// bounds. Nil means the subject has no dates and never filters on
    /// one.
    var daySpan: ClosedRange<Date>?

    init(
        personIDs: Set<UUID> = [],
        hasOtherFaces: Bool = false,
        eventIDs: Set<UUID> = [],
        mediaKinds: Set<OrganizeMediaKind> = [],
        cameraIDs: Set<String> = [],
        daySpan: ClosedRange<Date>? = nil
    ) {
        self.personIDs = personIDs
        self.hasOtherFaces = hasOtherFaces
        self.eventIDs = eventIDs
        self.mediaKinds = mediaKinds
        self.cameraIDs = cameraIDs
        self.daySpan = daySpan
    }

    /// A board stack's subject — the same stack facts the old facet
    /// filter read: assigned events and face-catalog people, plus the
    /// item kinds and capture interval the stack itself reports.
    init(stack: OrganizeStack, facts: OrganizeStackFacts) {
        self.init(
            personIDs: facts.personIDs,
            hasOtherFaces: facts.hasOtherFaces,
            eventIDs: facts.eventIDs,
            mediaKinds: Set(stack.items.map(\.kind)),
            cameraIDs: facts.cameraIDs,
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
    /// Approved people with a confirmed face on the stack's files — the
    /// union over a burst's frames. Unnamed groups and Inbox faces are
    /// not listed here (see `EventsWorkspace.boardPeople`).
    var personIDs: Set<UUID> = []
    /// Some frame also carries a face that is not confirmed on an
    /// approved person — the "someone else" fact "is exactly" reads.
    var hasOtherFaces = false
    /// Display names of those people and groups — the text needle's person
    /// match, so typing a roster name finds the same stacks a People row
    /// would.
    var personNames: Set<String> = []
    /// Cameras across the stack's frames (`EventsWorkspace.cameraIDs(for:)`)
    /// — resolved only while a Camera row filters, empty otherwise.
    var cameraIDs: Set<String> = []
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

    /// The builder's structured match: the board-level exclusions ANDed
    /// with an OR of AND-groups. Groups whose
    /// rows are all empty are skipped — a row with no values does not
    /// filter, so an unfinished group must not widen the match either. No
    /// active group passes everything.
    static func matches(
        subject: OrganizeFilterSubject,
        search: OrganizeSearchFilter,
        calendar: Calendar = .current
    ) -> Bool {
        // Board-level exclusions AND with everything: a subject carrying
        // an excluded event drops no matter which group it would match.
        guard subject.eventIDs.isDisjoint(with: search.excludedEventIDs) else { return false }
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
