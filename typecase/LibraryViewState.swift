import Combine
import Foundation

/// Identifies a character-coverage computation: the text to cover and the
/// family list it was computed against.
nonisolated struct PreviewCoverageRequest: Equatable, Sendable {
    let text: String
    let familiesRevision: Int
}

/// The base order. Enabled-first and favorites-first layer on top independently.
nonisolated enum LibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case manufacturer
    case dateAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .manufacturer: String(localized: "Manufacturer")
        case .dateAdded: String(localized: "Recently Added")
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
        let activatedFirst: Bool
        let catalogRevision: Int
        let coverageRevision: Int
    }

    struct FilterOutput {
        let families: [FontFamily]
        let ids: [FontFamily.ID]
        let sectionIsEmpty: Bool
    }

    func filter(catalog: FontCatalog, favoritesFirst: Bool, activatedFirst: Bool) -> FilterOutput {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = FilterKey(
            query: query,
            librarySelection: librarySelection,
            category: category,
            activationFilter: activationFilter,
            sortOrder: sortOrder,
            favoritesFirst: favoritesFirst,
            activatedFirst: activatedFirst,
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

        let selectedFolder: URL? = {
            if case .folder(let folder) = librarySelection { return folder.standardizedFileURL }
            return nil
        }()
        let selectedTagIDs: Set<FontFamily.ID>? = {
            if case .tag(let tag) = librarySelection {
                return catalog.taggedFamilyIDs[tag.lowercased()] ?? []
            }
            return nil
        }()

        var matches: [FontFamily] = []
        var sectionMatches = 0
        for family in catalog.families {
            guard matchesSection(family, catalog: catalog, folder: selectedFolder, tagIDs: selectedTagIDs) else { continue }
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

        // The catalog is already in name order. Other base orders retain a
        // name tiebreaker, then stable partitions add independent priorities.
        if sortOrder != .name {
            matches.sort { lhs, rhs in
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
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        if activatedFirst {
            matches = matches.filter(\.isEnabled) + matches.filter { !$0.isEnabled }
        }
        if favoritesFirst {
            // Favorites retain priority over enabled status, as before.
            matches = matches.filter { catalog.favorites.contains($0.id) }
                + matches.filter { !catalog.favorites.contains($0.id) }
        }

        let output = FilterOutput(
            families: matches,
            ids: matches.map(\.id),
            sectionIsEmpty: sectionMatches == 0
        )
        cachedOutput = (key, output)
        return output
    }

    func clearFilters() {
        searchText = ""
        category = nil
        activationFilter = .all
    }

    /// Keep the inspector in sync with the rows currently shown in the list.
    func reconcileVisibleSelection(with ids: [FontFamily.ID]) {
        let retained = selection.intersection(ids)
        if retained != selection {
            selection = retained.isEmpty ? ids.first.map { [$0] } ?? [] : retained
        } else if selection.isEmpty, let first = ids.first {
            selection = [first]
        }
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
    func reconcile(with catalog: FontCatalog, settings: AppSettings) {
        // Before the first scan finishes there is nothing to reconcile against;
        // a restored selection must survive until the families arrive.
        reconcileDestination(with: catalog, settings: settings)
        guard !catalog.familyIDs.isEmpty else { return }
        // A saved pair is selected from its own section, so its id stays valid
        // alongside the family ids.
        let selectable = catalog.familyIDs.union(catalog.mixedPairs.map(\.selectionID))
        selection.formIntersection(selectable)
        if selection.isEmpty, let first = catalog.families.first?.id {
            selection = [first]
        }
    }

    /// A completed scan may remove the last font of the selected service.
    /// Keep restored navigation during loading, then select a visible fallback.
    func reconcileDestination(with catalog: FontCatalog, settings: AppSettings) {
        guard catalog.hasCompletedInitialScan, !catalog.isLoading else { return }
        let missingProvider: Bool
        if case .section(let section) = librarySelection, let provider = section.provider {
            missingProvider = !catalog.availableProviders.contains(where: { $0.id == provider.id })
        } else {
            missingProvider = false
        }
        let missingTag: Bool
        if case .tag(let tag) = librarySelection {
            missingTag = !catalog.hasTag(tag)
        } else {
            missingTag = false
        }
        guard missingProvider || missingTag else { return }
        if let fallback = settings.visibleSidebarSections.first(where: { section in
            guard let provider = section.provider else { return true }
            return catalog.availableProviders.contains(where: { $0.id == provider.id })
        }) {
            librarySelection = .section(fallback)
        } else if let folder = catalog.folders.first {
            librarySelection = .folder(folder)
        } else {
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

    private func matchesSection(
        _ family: FontFamily, catalog: FontCatalog,
        folder: URL?, tagIDs: Set<FontFamily.ID>?
    ) -> Bool {
        switch librarySelection {
        case .section(let section):
            if let provider = section.provider { return family.source == .provider(provider) }
            switch section {
            case .all: return true
            case .favorites: return catalog.favorites.contains(family.id)
            case .system: return family.source == .system
            case .local: return family.source == .local
            case .duplicates: return catalog.duplicatesByFamily[family.id] != nil
            default: return false
            }
        case .systemScope(let scope):
            return catalog.familySystemScopes[family.id]?.contains(scope) ?? false
        case .folder:
            guard let folder else { return false }
            return catalog.familyFolderAncestors[family.id]?.contains(folder) ?? false
        case .tag:
            return tagIDs?.contains(family.id) ?? false
        }
    }
}
