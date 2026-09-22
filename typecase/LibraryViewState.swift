import Combine
import Foundation

/// Identifies a character-coverage computation: the text to cover and the
/// family list it was computed against.
nonisolated struct PreviewCoverageRequest: Equatable, Sendable {
    let text: String
    let familiesRevision: Int
}

/// How the library list is ordered. Favorites-first stays a separate setting,
/// so it layers on top of every order.
nonisolated enum LibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case manufacturer
    case dateAdded
    case activation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .manufacturer: "Manufacturer"
        case .dateAdded: "Recently Added"
        case .activation: "Activated First"
        }
    }
}

/// A window's library UI state: selection, filters, and preview settings.
///
/// Window state is separate from the shared catalog so a window can browse with
/// its own filters, and so preview changes do not invalidate catalog observers.
@MainActor
final class LibraryViewState: ObservableObject {
    @Published var selection: Set<FontFamily.ID> = []
    @Published var searchText = ""
    @Published var librarySelection: LibrarySelection = .section(.all)
    @Published var category: FontCategory?
    @Published var activationFilter: ActivationFilter = .all
    @Published var sortOrder: LibrarySortOrder = .name
    @Published var previewText = ""
    @Published private(set) var coverageRevision = 0

    private var cachedOutput: (key: FilterKey, output: FilterOutput)?
    private var appliedCoverage: AppliedCoverage?
    private var coverageTask: Task<Void, Never>?

    private struct AppliedCoverage {
        let text: String
        let familiesRevision: Int
        let matches: Set<FontFamily.ID>
    }

    private struct FilterKey: Equatable {
        let query: String
        let librarySelection: LibrarySelection
        let category: FontCategory?
        let activationFilter: ActivationFilter
        let sortOrder: LibrarySortOrder
        let favoritesFirst: Bool
        let catalogRevision: Int
        let coverageRevision: Int
    }

    struct FilterOutput {
        let families: [FontFamily]
        let sectionIsEmpty: Bool
    }

    func filter(catalog: FontCatalog, favoritesFirst: Bool) -> FilterOutput {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = FilterKey(
            query: query,
            librarySelection: librarySelection,
            category: category,
            activationFilter: activationFilter,
            sortOrder: sortOrder,
            favoritesFirst: favoritesFirst,
            catalogRevision: catalog.dataRevision,
            coverageRevision: coverageRevision
        )
        if let cachedOutput, cachedOutput.key == key {
            return cachedOutput.output
        }

        // Coverage stays inactive until a result for the current text and family
        // list is available, so the list never flickers empty while checking.
        let coverageFilter: Set<FontFamily.ID>? = {
            guard !previewCoverageText.isEmpty,
                  let applied = appliedCoverage,
                  applied.text == previewCoverageText,
                  applied.familiesRevision == catalog.familiesRevision else { return nil }
            return applied.matches
        }()

        var matches: [FontFamily] = []
        var sectionMatches = 0
        for family in catalog.families {
            guard matchesSection(family, catalog: catalog) else { continue }
            sectionMatches += 1
            if let coverageFilter, !coverageFilter.contains(family.id) { continue }
            if !query.isEmpty {
                let matchesSearch = family.name.localizedCaseInsensitiveContains(query)
                    || family.localizedName.localizedCaseInsensitiveContains(query)
                    || family.localizedNames.values.contains { $0.localizedCaseInsensitiveContains(query) }
                    || family.manufacturer.localizedCaseInsensitiveContains(query)
                    || (catalog.userTags[family.id]?.contains { $0.localizedCaseInsensitiveContains(query) } ?? false)
                guard matchesSearch else { continue }
            }
            if let category, family.category != category { continue }
            switch activationFilter {
            case .all:
                break
            case .enabled:
                guard family.isEnabled else { continue }
            case .disabled:
                guard !family.isEnabled else { continue }
            }
            matches.append(family)
        }

        // The catalog order is by name; every order keeps a name tiebreaker so
        // equal entries stay predictable. Favorites-first is layered on top.
        matches.sort { lhs, rhs in
            if favoritesFirst {
                let lhsFavorite = catalog.favorites.contains(lhs.id)
                let rhsFavorite = catalog.favorites.contains(rhs.id)
                if lhsFavorite != rhsFavorite { return lhsFavorite }
            }
            switch sortOrder {
            case .name:
                break
            case .manufacturer:
                let comparison = lhs.manufacturer.localizedStandardCompare(rhs.manufacturer)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .dateAdded:
                let lhsTime = catalog.addedTime(for: lhs)
                let rhsTime = catalog.addedTime(for: rhs)
                if lhsTime != rhsTime { return lhsTime > rhsTime }
            case .activation:
                if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let output = FilterOutput(families: matches, sectionIsEmpty: sectionMatches == 0)
        cachedOutput = (key, output)
        return output
    }

    func clearFilters() {
        searchText = ""
        category = nil
        activationFilter = .all
    }

    // MARK: - Character coverage

    /// The state changes that require a new coverage computation.
    func coverageRequest(catalog: FontCatalog) -> PreviewCoverageRequest {
        PreviewCoverageRequest(
            text: previewCoverageText,
            familiesRevision: catalog.familiesRevision
        )
    }

    /// Recomputes which fonts can display the preview text. Called by the
    /// library view whenever `coverageRequest(catalog:)` changes. Non-empty
    /// preview text always filters the list.
    func updateCoverage(catalog: FontCatalog) {
        let request = coverageRequest(catalog: catalog)
        guard !request.text.isEmpty else {
            coverageTask?.cancel()
            coverageTask = nil
            if appliedCoverage != nil {
                appliedCoverage = nil
                coverageRevision += 1
            }
            return
        }

        if appliedCoverage?.text == request.text,
           appliedCoverage?.familiesRevision == request.familiesRevision {
            return
        }

        coverageTask?.cancel()
        let scalars = CoverageText.requiredScalars(in: request.text)
        let queries = catalog.families.compactMap { family -> CoverageFaceQuery? in
            guard let face = family.previewFace else { return nil }
            return CoverageFaceQuery(
                familyID: family.id,
                postScriptName: face.postScriptName,
                fileURL: face.fileURL
            )
        }
        coverageTask = Task { [weak self] in
            let matches = await catalog.coverageMatches(families: queries, scalars: scalars)
            guard !Task.isCancelled, let self else { return }
            self.appliedCoverage = AppliedCoverage(
                text: request.text,
                familiesRevision: request.familiesRevision,
                matches: matches
            )
            self.coverageRevision += 1
        }
    }

    private var previewCoverageText: String {
        previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps the selection valid after the catalog changes and selects the first
    /// font when nothing is selected, matching the behavior of a fresh library.
    func reconcile(with catalog: FontCatalog) {
        // Before the first scan finishes there is nothing to reconcile against;
        // a restored selection must survive until the families arrive.
        guard !catalog.familyIDs.isEmpty else { return }
        reconcileDestination(with: catalog)
        // A saved pair is selected from its own section, so its id stays valid
        // alongside the family ids.
        let selectable = catalog.familyIDs.union(catalog.mixedPairs.map(\.selectionID))
        selection.formIntersection(selectable)
        if selection.isEmpty, let first = catalog.families.first?.id {
            selection = [first]
        }
    }

    /// Keeps the sidebar destination valid when the tag it names disappears,
    /// so the window never shows an invisible selection.
    func reconcileDestination(with catalog: FontCatalog) {
        guard !catalog.familyIDs.isEmpty else { return }
        if case .tag(let tag) = librarySelection, !catalog.hasTag(tag) {
            librarySelection = .section(.all)
        }
    }

    /// Applies the startup preferences once, before the first reconcile.
    func restoreStartupState(from settings: AppSettings) {
        if !settings.lastSelection.isEmpty {
            selection = Set(settings.lastSelection)
        }
        if let location = settings.lastLibrarySelection {
            librarySelection = location
        }
        // A hidden destination has no sidebar row to select.
        if !settings.isSidebarItemVisible(librarySelection),
           let fallback = settings.visibleSidebarSections.first {
            librarySelection = .section(fallback)
        }
    }

    func selectedFamilies(catalog: FontCatalog) -> [FontFamily] {
        catalog.families.filter { selection.contains($0.id) }
    }

    /// Saves a pair from two families — one Japanese and one Latin — and moves
    /// the window to it so a new pair is immediately visible in the Mixed
    /// Fonts section.
    func createMixedPair(_ first: FontFamily, _ second: FontFamily, catalog: FontCatalog) {
        guard let sources = catalog.mixedPairSources(in: [first, second]),
              let pair = catalog.addMixedPair([.japanese: sources.japanese, .latin: sources.latin]) else { return }
        librarySelection = .section(.mixed)
        selection = [pair.selectionID]
    }

    private func matchesSection(_ family: FontFamily, catalog: FontCatalog) -> Bool {
        switch librarySelection {
        case .section(let section):
            if let provider = section.provider { return family.source == .provider(provider) }
            switch section {
            case .all: return true
            case .favorites: return catalog.favorites.contains(family.id)
            case .system: return family.source == .system
            case .local: return family.source == .local
            default: return false
            }
        case .systemScope(let scope):
            return catalog.familySystemScopes[family.id]?.contains(scope) ?? false
        case .folder(let folder):
            return catalog.familyFolderAncestors[family.id]?.contains(folder.standardizedFileURL) ?? false
        case .tag(let tag):
            return catalog.hasTag(tag, in: family)
        }
    }
}
