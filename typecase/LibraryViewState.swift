import Combine
import Foundation

/// Identifies a character-coverage computation: the text to cover and the
/// family list it was computed against.
nonisolated struct PreviewCoverageRequest: Equatable, Sendable {
    let text: String
    let familiesRevision: Int
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
    @Published var previewText = ""
    @Published var previewSize: Double = 32
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
        let catalogRevision: Int
        let coverageRevision: Int
    }

    struct FilterOutput {
        let families: [FontFamily]
        let sectionIsEmpty: Bool
    }

    func filter(catalog: FontCatalog) -> FilterOutput {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = FilterKey(
            query: query,
            librarySelection: librarySelection,
            category: category,
            activationFilter: activationFilter,
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
        selection.formIntersection(catalog.familyIDs)
        if selection.isEmpty, let first = catalog.families.first?.id {
            selection = [first]
        }
    }

    func selectedFamilies(catalog: FontCatalog) -> [FontFamily] {
        catalog.families.filter { selection.contains($0.id) }
    }

    private func matchesSection(_ family: FontFamily, catalog: FontCatalog) -> Bool {
        switch librarySelection {
        case .section(.all): true
        case .section(.favorites): catalog.favorites.contains(family.id)
        case .section(.system): family.source == .system
        case .section(.local): family.source == .local
        case .section(.adobe): family.source == .adobe
        case .section(.morisawa): family.source == .morisawa
        case .systemScope(let scope): catalog.familySystemScopes[family.id]?.contains(scope) ?? false
        case .folder(let folder):
            catalog.familyFolderAncestors[family.id]?.contains(folder.standardizedFileURL) ?? false
        }
    }

    func previewText(for family: FontFamily) -> String {
        let customText = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customText.isEmpty { return previewText }
        return family.supportsJapanese
            ? "美しい文字は、言葉の表情を豊かにする。"
            : "Typography gives every word a distinct voice."
    }
}
