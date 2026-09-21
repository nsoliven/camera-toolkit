import CameraToolkitCore
import Foundation

/// The structured filters behind the board's search field — the chip
/// panel that opens under it. Each facet is a set or a range: picks
/// inside one facet are OR (a "Dad + Phil" people filter keeps stacks
/// with either), while the facets themselves AND together. An empty
/// facet never filters. Text stays free-form — file name, burst label,
/// origin subfolder, or event title.
struct OrganizeSearchFilter: Equatable, Sendable {
    /// Raw text of the search field — normalized through `needle`.
    var text = ""
    /// Roster people or unnamed face groups whose faces sit on the stack.
    var peopleIDs: Set<UUID> = []
    /// Inclusive day bounds, matched at the camera wall clock's day
    /// granularity — the same day bucketing `OrganizeStacker.days` uses.
    /// A stack matches when its capture range overlaps the range's days.
    var dayStart: Date?
    var dayEnd: Date?
    /// Events a stack must be sorted into; `includeUnsorted` adds the
    /// "Not Sorted Yet" bucket — stacks carrying no assignment at all.
    var eventIDs: Set<UUID> = []
    var includeUnsorted = false
    /// Media kinds a stack must contain — stills, RAW, video.
    var mediaKinds: Set<OrganizeMediaKind> = []

    /// Empty text and no active facets — the board shows everything.
    var isEmpty: Bool {
        OrganizeSearch.needle(text).isEmpty
            && peopleIDs.isEmpty
            && dayStart == nil && dayEnd == nil
            && eventIDs.isEmpty && !includeUnsorted
            && mediaKinds.isEmpty
    }

    /// Facets filtering right now — the funnel button's badge count.
    var activeFacetCount: Int {
        (peopleIDs.isEmpty ? 0 : 1)
            + (dayStart == nil && dayEnd == nil ? 0 : 1)
            + (eventIDs.isEmpty && !includeUnsorted ? 0 : 1)
            + (mediaKinds.isEmpty ? 0 : 1)
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
    /// match, so typing a roster name finds the same stacks a People chip
    /// would.
    var personNames: Set<String> = []
}

/// Lowercase-contains text matching for the Events sidebar and the organize
/// board. Everything runs over already-scanned data — no filesystem access.
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

    /// The full board match: the text needle plus every structured facet,
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

        if !search.peopleIDs.isEmpty, facts.personIDs.isDisjoint(with: search.peopleIDs) {
            return false
        }

        if !search.eventIDs.isEmpty || search.includeUnsorted {
            let inEvent = !facts.eventIDs.isDisjoint(with: search.eventIDs)
            let unsorted = search.includeUnsorted && facts.eventIDs.isEmpty
            guard inEvent || unsorted else { return false }
        }

        if !search.mediaKinds.isEmpty,
           !stack.items.contains(where: { search.mediaKinds.contains($0.kind) }) {
            return false
        }

        if search.dayStart != nil || search.dayEnd != nil {
            let lower = search.dayStart.map { calendar.startOfDay(for: $0) } ?? .distantPast
            let upper = search.dayEnd.map {
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) ?? .distantFuture
            } ?? .distantFuture
            guard stack.captureDate < upper, stack.endDate >= lower else { return false }
        }

        return true
    }
}
