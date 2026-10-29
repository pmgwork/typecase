import AppKit
import CoreText
import Combine

/// The shared, app-lifetime font library.
///
/// Owns scanning, Core Text registration, folder monitoring, and user data so
/// every window sees the same catalog and only one scan runs at a time. Window
/// state (selection, filters, preview settings) lives in `LibraryViewState`.
@MainActor
final class FontCatalog: ObservableObject {
    @Published private(set) var families: [FontFamily] = []
    @Published private(set) var folders: [URL] = []
    @Published private(set) var folderTrees: [FontFolderNode] = []
    @Published private(set) var favorites: Set<String> = []
    /// Saved Japanese + Latin combinations, in the order they were created.
    @Published private(set) var mixedPairs: [FontPair] = []
    @Published private(set) var userTags: [String: Set<String>] = [:]
    /// Tag names the user created. A tag stays in the sidebar while no font
    /// carries it, so it can be prepared before it is assigned.
    @Published private(set) var knownTags: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var activationCompletedFiles = 0
    @Published private(set) var activationTotalFiles = 0
    @Published private(set) var isUpdatingActivation = false
    private var pendingActivationOperations = 0
    private static let registrationBatchSize = 32
    /// Increments whenever catalog or user data changes; invalidates derived caches.
    @Published private(set) var dataRevision = 0
    /// Increments when the family list changes; windows use it to reconcile selection.
    @Published private(set) var familiesRevision = 0

    private(set) var familyByID: [FontFamily.ID: FontFamily] = [:]
    private(set) var familyIDs: Set<FontFamily.ID> = []
    private(set) var familySystemScopes: [FontFamily.ID: Set<SystemFontScope>] = [:]
    private(set) var familyFolderAncestors: [FontFamily.ID: Set<URL>] = [:]
    private(set) var allTags: [String] = []
    private(set) var systemFontCount = 0
    private var favoriteCount = 0
    private var sourceCounts: [FontSource: Int] = [:]
    private var scopeCounts: [SystemFontScope: Int] = [:]
    private var folderCounts: [URL: Int] = [:]
    private var folderActivationFiles: [URL: [FontActivationState]] = [:]
    private var tagCounts: [String: Int] = [:]
    private(set) var taggedFamilyIDs: [String: Set<FontFamily.ID>] = [:]
    /// The faces of each family that more than one font file provides, in
    /// face order. Families without duplicates have no entry.
    private(set) var duplicatesByFamily: [FontFamily.ID: [FontDuplicate]] = [:]

    private let defaults = UserDefaults.standard
    private let engine = FontScanEngine()
    private let registrar = FontRegistrar()
    private let folderMonitor = FolderMonitor()
    private let registrationQueue = SerialWorkQueue()
    private let coverage = FontCoverage()

    private var activeManagedNames: Set<String> = []
    /// Names the user deactivated since the last installed-font scan. The scan's
    /// installed records may still list them, so they are masked when regrouping.
    private var deactivatedManagedNames: Set<String> = []
    private var localizedNameCache: [URL: [String: FontNameTable.LocalizedFamily]] = [:]
    private var fileCache: [URL: CachedFontFile] = [:]
    private var installedRecords: [FaceRecord] = []
    private var folderRecords: [FaceRecord] = []
    private var installedSeeds: [InstalledFaceSeed] = []
    private var scannedRoots: [URL] = []
    /// The provider manifest names the cached records were classified with.
    private var manifestNames: [String: Set<String>]?
    private let snapshotStore = FontScanSnapshotStore()
    private var snapshotSequence = 0
    /// Whether the snapshot on disk matches the current scan results.
    private var snapshotIsCurrent = false
    private var metadataCache: [URL: [String: FontNameTable.Metadata]] = [:]
    /// Each face's variable axes by PostScript name; nil marks a static face.
    private var variableInfoCache: [String: VariableFontInfo?] = [:]
    private var lastDirectoryFingerprint: UInt64 = 0
    private var securityScopedURLs: [URL] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var userRegistrationRevision = 0
    private var hasLoadedOnce = false
    private var hasStarted = false
    private var backstopTimer: Timer?

    init() {
        favorites = Set(defaults.stringArray(forKey: "favoriteFamilies") ?? [])
        userTags = (defaults.dictionary(forKey: "familyTags") as? [String: [String]] ?? [:])
            .mapValues(Set.init)
        migrateTags(storedNames: defaults.stringArray(forKey: "tagNames") ?? [])
        activeManagedNames = Set(defaults.stringArray(forKey: "activeManagedFonts") ?? [])
        mixedPairs = Self.loadMixedPairs(defaults: defaults)
        rebuildAllTags()
        folderMonitor.onChanges = { [weak self] in self?.refresh() }
    }

    /// Restores bookmarks and starts the first scan and folder monitoring.
    /// Safe to call once per app launch; later calls are ignored.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        restoreFolders()
        startBackstopTimer()
        isLoading = true
        // Show the last launch's library first; the scan then checks it against
        // the fonts on disk and reparses only what changed.
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                FontScanSnapshot.load()
            }.value
            guard let self else { return }
            if let snapshot { await self.adopt(snapshot) }
            self.refresh()
        }
    }

    // MARK: - User data

    func isFavorite(_ family: FontFamily) -> Bool {
        favorites.contains(family.id)
    }

    func toggleFavorite(_ family: FontFamily) {
        setFavorite(!isFavorite(family), families: [family])
    }

    /// Apply one state to the selection, persisting and invalidating the list
    /// once even when hundreds of families are selected.
    func setFavorite(_ enabled: Bool, families: [FontFamily]) {
        let ids = Set(families.map(\.id))
        let updated = enabled ? favorites.union(ids) : favorites.subtracting(ids)
        guard updated != favorites else { return }
        favorites = updated
        favoriteCount = favorites.intersection(familyIDs).count
        defaults.set(Array(favorites), forKey: "favoriteFamilies")
        dataRevision += 1
    }

    // MARK: - Tags

    func hasTag(_ tag: String, in family: FontFamily) -> Bool {
        let key = Self.tagKey(tag)
        return userTags[family.id]?.contains { Self.tagKey($0) == key } ?? false
    }

    /// Whether the tag exists. A tag is an entity of its own, so it stays
    /// valid while no font carries it.
    func hasTag(_ tag: String) -> Bool {
        let key = Self.tagKey(tag)
        return knownTags.contains { Self.tagKey($0) == key }
    }

    /// Creates a tag without assigning it, so it can be prepared in the
    /// sidebar before it is used. An existing name that differs only by case
    /// or whitespace is reused. Returns the stored name, or nil when the name
    /// is empty.
    @discardableResult
    func createTag(_ tag: String) -> String? {
        guard let normalized = Self.normalizedTag(tag) else { return nil }
        let key = Self.tagKey(normalized)
        let canonical = canonicalTag(forKey: key) ?? normalized
        guard !knownTags.contains(canonical) else { return canonical }
        knownTags.insert(canonical)
        saveTags()
        return canonical
    }

    /// Adds a tag to the family, creating the tag if it does not exist yet.
    /// Returns whether anything changed.
    @discardableResult
    func addTag(_ tag: String, to family: FontFamily) -> Bool {
        guard let normalized = Self.normalizedTag(tag) else { return false }
        let key = Self.tagKey(normalized)
        let canonical = canonicalTag(forKey: key) ?? normalized
        var didChange = false
        if !knownTags.contains(canonical) {
            knownTags.insert(canonical)
            didChange = true
        }
        if !(userTags[family.id]?.contains(where: { Self.tagKey($0) == key }) ?? false) {
            userTags[family.id, default: []].insert(canonical)
            didChange = true
        }
        guard didChange else { return false }
        saveTags()
        return true
    }

    /// Removes the tag from the family. The tag itself stays in the sidebar,
    /// where it can be renamed or deleted.
    func removeTag(_ tag: String, from family: FontFamily) {
        let key = Self.tagKey(tag)
        guard let tags = userTags[family.id],
              tags.contains(where: { Self.tagKey($0) == key }) else { return }
        let remaining = tags.filter { Self.tagKey($0) != key }
        if remaining.isEmpty {
            userTags.removeValue(forKey: family.id)
        } else {
            userTags[family.id] = remaining
        }
        saveTags()
    }

    /// Removes the tag from the sidebar and from every family that carries it.
    func deleteTag(_ tag: String) {
        let key = Self.tagKey(tag)
        var didChange = false
        let knownMatches = knownTags.filter { Self.tagKey($0) == key }
        if !knownMatches.isEmpty {
            knownTags.subtract(knownMatches)
            didChange = true
        }
        for (familyID, tags) in userTags where tags.contains(where: { Self.tagKey($0) == key }) {
            let remaining = tags.filter { Self.tagKey($0) != key }
            if remaining.isEmpty {
                userTags.removeValue(forKey: familyID)
            } else {
                userTags[familyID] = remaining
            }
            didChange = true
        }
        guard didChange else { return }
        saveTags()
    }

    /// Renames the tag in the sidebar and on every family that carries it and
    /// returns the stored name, or nil when there was nothing to rename.
    /// Renaming a tag to one that already exists merges the two.
    @discardableResult
    func renameTag(_ tag: String, to newName: String) -> String? {
        guard let normalized = Self.normalizedTag(newName) else { return nil }
        let oldKey = Self.tagKey(tag)
        let newKey = Self.tagKey(normalized)
        var didChange = false

        let knownMatches = knownTags.filter { Self.tagKey($0) == oldKey }
        if !knownMatches.isEmpty {
            knownTags.subtract(knownMatches)
            didChange = true
        }
        for (familyID, tags) in userTags where tags.contains(where: { Self.tagKey($0) == oldKey }) {
            var updated = tags.filter { Self.tagKey($0) != oldKey }
            if !updated.contains(where: { Self.tagKey($0) == newKey }) {
                updated.insert(normalized)
            }
            userTags[familyID] = updated
            didChange = true
        }
        if didChange, !knownTags.contains(where: { Self.tagKey($0) == newKey }) {
            knownTags.insert(normalized)
        }
        guard didChange else { return nil }
        saveTags()
        return normalized
    }

    /// Trims and collapses whitespace; empty names are rejected.
    private static func normalizedTag(_ raw: String) -> String? {
        let parts = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    /// The case-insensitive identity of a tag.
    private static func tagKey(_ tag: String) -> String {
        tag.lowercased()
    }

    /// The spelling already stored for a tag identity, so adding "logo" while
    /// "Logo" exists keeps the existing name.
    private func canonicalTag(forKey key: String) -> String? {
        if let match = knownTags.first(where: { Self.tagKey($0) == key }) { return match }
        for tags in userTags.values {
            if let match = tags.first(where: { Self.tagKey($0) == key }) { return match }
        }
        return nil
    }

    /// Restores stored tags to one spelling per name, adds tags older versions
    /// only kept per font to the tag list, and drops empty entries. Names that
    /// differ only by case or whitespace are merged, keeping the most used
    /// spelling. Runs once at launch.
    private func migrateTags(storedNames: [String]) {
        var usage: [String: [String: Int]] = [:]
        var known: Set<String> = []
        for raw in storedNames {
            guard let tag = Self.normalizedTag(raw) else { continue }
            known.insert(tag)
            usage[Self.tagKey(tag), default: [:]][tag, default: 0] += 1
        }
        var normalizedFamilies: [String: Set<String>] = [:]
        for (familyID, tags) in userTags {
            let cleaned = Set(tags.compactMap(Self.normalizedTag))
            guard !cleaned.isEmpty else { continue }
            normalizedFamilies[familyID] = cleaned
            known.formUnion(cleaned)
            for tag in cleaned {
                usage[Self.tagKey(tag), default: [:]][tag, default: 0] += 1
            }
        }

        var canonical: [String: String] = [:]
        for (key, spellings) in usage {
            canonical[key] = spellings
                .sorted {
                    $0.value == $1.value
                        ? $0.key.localizedStandardCompare($1.key) == .orderedAscending
                        : $0.value > $1.value
                }
                .first?.key
        }

        let migratedFamilies = normalizedFamilies.mapValues { tags in
            Set(tags.map { canonical[Self.tagKey($0)] ?? $0 })
        }
        let migratedKnown = Set(known.map { canonical[Self.tagKey($0)] ?? $0 })

        if migratedFamilies != userTags {
            userTags = migratedFamilies
            defaults.set(userTags.mapValues(Array.init), forKey: "familyTags")
        }
        if migratedKnown != knownTags {
            knownTags = migratedKnown
            defaults.set(Array(knownTags), forKey: "tagNames")
        }
    }

    private func saveTags() {
        defaults.set(userTags.mapValues(Array.init), forKey: "familyTags")
        defaults.set(Array(knownTags), forKey: "tagNames")
        rebuildAllTags()
        rebuildTagCounts()
        dataRevision += 1
    }

    /// The sidebar's tag list, sorted for display. Tags are user data, so an
    /// unassigned tag keeps its row until it is deleted.
    private func rebuildAllTags() {
        allTags = knownTags.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func rebuildTagCounts() {
        var ids: [String: Set<FontFamily.ID>] = [:]
        for (familyID, tags) in userTags where familyIDs.contains(familyID) {
            for tag in tags { ids[Self.tagKey(tag), default: []].insert(familyID) }
        }
        taggedFamilyIDs = ids
        tagCounts = ids.mapValues(\.count)
    }

    // MARK: - Mixed pairs

    /// The pair a list selection names, or nil when the selection is not a
    /// single pair.
    func mixedPair(for selection: Set<FontFamily.ID>) -> FontPair? {
        guard selection.count == 1, let id = selection.first, FontPair.isSelectionID(id) else { return nil }
        return mixedPairs.first { $0.selectionID == id }
    }

    /// The one Japanese and one Latin family a new pair can be built from, or
    /// nil while the families do not supply both sides.
    func mixedPairSources(in families: [FontFamily]) -> (japanese: FontFamily, latin: FontFamily)? {
        guard let japanese = families.first(where: \.usesJapaneseScript),
              let latin = families.first(where: { !$0.usesJapaneseScript }) else { return nil }
        return (japanese, latin)
    }

    /// The families that can fill one part of a specimen, in name order. The
    /// Japanese part lists the Japanese fonts; every part that draws letters,
    /// digits, or symbols can take any face. Families without a face cannot be
    /// referenced, so they are left out.
    func families(for script: MixedScript) -> [FontFamily] {
        families.filter { family in
            guard family.previewFace != nil else { return false }
            switch script {
            case .japanese:
                return family.usesJapaneseScript
            case .latin, .numbers, .symbols:
                return true
            }
        }
    }

    /// Saves a mixed-font combination. Returns nil when the Japanese or Latin
    /// family has no face to reference; the other parts are optional.
    @discardableResult
    func addMixedPair(_ families: [MixedScript: FontFamily]) -> FontPair? {
        var references: [MixedScript: FontFaceReference] = [:]
        for (script, family) in families {
            guard let reference = FontFaceReference(family: family) else {
                if script == .japanese || script == .latin { return nil }
                continue
            }
            references[script] = reference
        }
        return addMixedPair(references: references)
    }

    /// Saves a mixed-font combination from explicit faces. Returns nil when
    /// the Japanese or Latin face is missing.
    @discardableResult
    func addMixedPair(
        references: [MixedScript: FontFaceReference],
        typesetting: TypesettingOptions? = nil
    ) -> FontPair? {
        guard let japanese = references[.japanese], let latin = references[.latin] else { return nil }
        let pair = FontPair(
            japanese: japanese,
            latin: latin,
            numbers: references[.numbers],
            symbols: references[.symbols],
            typesetting: typesetting
        )
        mixedPairs.append(pair)
        saveMixedPairs()
        return pair
    }

    /// The fonts a new pair starts with: the macOS standard for each part of
    /// the mix, as far as it is installed. Each part starts from the family's
    /// preferred style (W5 for Japanese, Medium for the other parts), when available.
    func defaultMixedPairFamilies() -> [MixedScript: FontFaceReference] {
        var result: [MixedScript: FontFaceReference] = [:]
        for script in MixedScript.allCases {
            guard let family = family(matching: Self.defaultMixedFontNames[script] ?? []),
                  let face = family.defaultMixedFace(for: script) else { continue }
            result[script] = FontFaceReference(familyID: family.id, postScriptName: face.postScriptName)
        }
        return result
    }

    /// The Japanese face used by a blank PlayGround type scale. Look it up in
    /// the catalog so the inspector and the specimen resolve the same font.
    func defaultPlaygroundFace() -> FontFaceReference? {
        guard let family = family(matching: [
            "Hiragino Sans", "ヒラギノ角ゴシック",
            "Hiragino Kaku Gothic ProN", "ヒラギノ角ゴ ProN",
        ]), let face = family.defaultMixedFace(for: .japanese) else { return nil }
        return FontFaceReference(familyID: family.id, postScriptName: face.postScriptName)
    }

    /// The first installed family whose name matches one of the candidates,
    /// comparing both the family id and the names the library shows.
    private func family(matching candidates: [String]) -> FontFamily? {
        for candidate in candidates {
            let folded = Self.fold(candidate)
            if let family = familyByID[folded] { return family }
            if let family = families.first(where: {
                Self.fold($0.localizedName) == folded || Self.fold($0.name) == folded
            }) { return family }
        }
        return nil
    }

    private static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// The macOS fonts a new pair starts from, per part of the mix.
    private static let defaultMixedFontNames: [MixedScript: [String]] = [
        .japanese: [
            "Hiragino Sans", "ヒラギノ角ゴシック",
            "Hiragino Kaku Gothic ProN", "ヒラギノ角ゴ ProN",
            "YuGothic", "游ゴシック体",
        ],
        .latin: ["Helvetica Neue", "Helvetica", "SF Pro Text"],
        .numbers: ["Helvetica Neue", "Helvetica", "SF Pro Text"],
        .symbols: ["Helvetica Neue", "Helvetica", "Apple Symbols", "SF Pro Text"],
    ]

    func removeMixedPair(_ pair: FontPair) {
        mixedPairs.removeAll { $0.id == pair.id }
        saveMixedPairs()
    }

    /// Whether a saved reference still resolves to a drawable face.
    func canResolve(_ reference: FontFaceReference) -> Bool {
        FontResolver.shared.isResolvable(
            postScriptName: reference.postScriptName,
            fileURL: face(for: reference)?.fileURL
        )
    }

    private func saveMixedPairs() {
        defaults.set(try? JSONEncoder().encode(mixedPairs), forKey: Self.mixedPairsKey)
        dataRevision += 1
    }

    private static func loadMixedPairs(defaults: UserDefaults) -> [FontPair] {
        guard let data = defaults.data(forKey: mixedPairsKey) else { return [] }
        return (try? JSONDecoder().decode([FontPair].self, from: data)) ?? []
    }

    private static let mixedPairsKey = "mixedPairs"

    // MARK: - Selection helpers

    func family(for selection: Set<FontFamily.ID>) -> FontFamily? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return familyByID[id]
    }

    /// The face a saved reference names, or the family's preview face when the
    /// stored style is gone. `nil` when the family itself is gone.
    func face(for reference: FontFaceReference) -> FontFace? {
        guard let family = familyByID[reference.familyID] else { return nil }
        return family.faces.first { $0.postScriptName == reference.postScriptName } ?? family.previewFace
    }

    /// Only services represented by fonts in the catalog get navigation rows.
    var hasCompletedInitialScan: Bool { hasLoadedOnce }

    var availableProviders: [FontProvider] {
        FontProviderRegistry.all.filter { fontCount(for: .section(.provider($0))) > 0 }
    }

    /// Returns the unfiltered family count represented by a sidebar destination.
    /// The sidebar requests this only for its selected row.
    func fontCount(for selection: LibrarySelection) -> Int {
        switch selection {
        case .section(let section):
            if let provider = section.provider {
                return sourceCounts[.provider(provider), default: 0]
            }
            switch section {
            case .favorites:
                return favoriteCount
            case .system:
                return systemFontCount
            case .local:
                return sourceCounts[.local, default: 0]
            case .mixed:
                return mixedPairs.count
            case .duplicates:
                return duplicatesByFamily.count
            default:
                return families.count
            }
        case .systemScope(let scope):
            return scopeCounts[scope, default: 0]
        case .folder(let folder):
            return folderCounts[folder.standardizedFileURL, default: 0]
        case .tag(let tag):
            return tagCounts[Self.tagKey(tag), default: 0]
        }
    }

    // MARK: - Folders

    /// Asks for ~/Library/Fonts, so its copies can be cleaned up.
    func addUserFontsFolder(onAdded: ((URL) -> Void)? = nil) {
        addFolder(
            startingAt: Self.userFontsFolder,
            message: String(localized: "Add your Fonts folder so TypeCase can move duplicate copies in it to Trash."),
            onAdded: onAdded
        )
    }

    func addFolder(startingAt directory: URL? = nil, message: String? = nil, onAdded: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a font folder")
        panel.prompt = String(localized: "Add Folder")
        panel.directoryURL = directory
        panel.message = message ?? ""
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        // Present after the current menu or toolbar action finishes; a modal panel started from
        // inside a menu tracking session does not appear.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
            // A window already showing a sheet queues another one out of view,
            // so present on the frontmost sheet, such as the cleanup sheet.
            while let sheet = window?.attachedSheet { window = sheet }
            if let window {
                panel.beginSheetModal(for: window) { response in
                    Task { @MainActor in self.adoptFolders(from: panel, response: response, onAdded: onAdded) }
                }
            } else {
                panel.begin { response in
                    Task { @MainActor in self.adoptFolders(from: panel, response: response, onAdded: onAdded) }
                }
            }
        }
    }

    private func adoptFolders(from panel: NSOpenPanel, response: NSApplication.ModalResponse, onAdded: ((URL) -> Void)?) {
        guard response == .OK else { return }
        if let added = addFolders(panel.urls) {
            onAdded?(added)
        }
    }

    /// Adds folders and returns the first folder that was actually added.
    @discardableResult
    func addFolders(_ urls: [URL]) -> URL? {
        var firstAddedFolder: URL?
        for candidate in urls where candidate.isFileURL {
            let url = candidate.standardizedFileURL
            let startedAccess = url.startAccessingSecurityScopedResource()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let isDuplicate = folders.contains { $0.standardizedFileURL == url }

            guard isDirectory, !isDuplicate else {
                if startedAccess { url.stopAccessingSecurityScopedResource() }
                continue
            }

            if startedAccess {
                securityScopedURLs.append(url)
            }
            folders.append(url)
            if firstAddedFolder == nil { firstAddedFolder = url }
        }

        guard let firstAddedFolder else { return nil }
        saveFolderBookmarks()
        refresh()
        return firstAddedFolder
    }

    func revealFolder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reveals the given font files in Finder, selecting them all.
    func revealFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Only inactive local files in added folders can be cleaned up here.
    /// System and provider files remain under their original app's control.
    private static let userFontsFolder = SystemFontScope.homeDirectory
        .appending(path: "Library/Fonts", directoryHint: .isDirectory).standardizedFileURL

    func duplicateCleanupFiles() -> [DuplicateCleanupFile] {
        var namesByURL: [URL: Set<String>] = [:]
        var protectedURLs: Set<URL> = []
        for record in installedRecords + folderRecords {
            guard let url = record.face.fileURL?.standardizedFileURL else { continue }
            namesByURL[url, default: []].insert(record.face.postScriptName)
            // Installed records read as .system even for a folder copy Core
            // Text resolved, so only a provider's files count as theirs.
            if record.source.provider != nil { protectedURLs.insert(url) }
        }
        let inUse = Set(installedRecords.compactMap { $0.face.fileURL?.standardizedFileURL })
        return namesByURL.map { url, names in
            let cached = fileCache[url]
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            let scope = CTFontManagerGetScopeForURL(url as CFURL)
            let isInFolder = folders.contains(where: { url.isContained(in: $0) })
            let isActive = inUse.contains(url) || scope != .none
            // A copy TypeCase activated from a folder can be turned off; one
            // installed or loaded some other way stays.
            let activatedHere = scope == .user && isInFolder
                && !(cached?.descriptorNames ?? names).isDisjoint(with: activeManagedNames)
            let isMovable = values?.isRegularFile == true && values?.isSymbolicLink != true
                && url.resolvingSymlinksInPath() == url && FileManager.default.isDeletableFile(atPath: url.path)
            let reason: String?
            if isActive && !activatedHere {
                reason = String(localized: "In Use")
            } else if protectedURLs.contains(url) || !isInFolder {
                reason = String(localized: "Managed by another app")
            } else if cached == nil || !isMovable {
                reason = String(localized: "Unavailable")
            } else {
                reason = nil
            }
            // The person may unlock a copy in use that sits in one of their
            // folders or in ~/Library/Fonts; a provider's or the system's stays.
            // The sandbox can move a ~/Library/Fonts file only once that
            // folder is added, which isMovable reflects.
            let isUnlockable = reason != nil && isActive && !activatedHere && isMovable
                && !protectedURLs.contains(url)
                && (isInFolder || url.isContained(in: Self.userFontsFolder))
            return DuplicateCleanupFile(
                url: url, names: cached?.descriptorNames ?? names, protectionReason: reason,
                size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate,
                isActive: isActive, isUnlockable: isUnlockable,
                needsFolderAccess: reason != nil && !isInFolder && !isMovable && values?.isRegularFile == true
                    && !protectedURLs.contains(url) && url.isContained(in: Self.userFontsFolder)
            )
        }.sorted { $0.url.path < $1.url.path }
    }

    /// Revalidates the reviewed files and the unique-face warning immediately
    /// before moving anything. Active copies are unregistered file by file,
    /// leaving the remembered activation of their faces to the copy that stays.
    func trashDuplicateFiles(
        _ selected: Set<URL>, unlocked: Set<URL> = [], reviewed: [DuplicateCleanupFile]
    ) async throws {
        let changed = NSError(domain: "TypeCase.DuplicateCleanup", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "The font files changed. Review the list again before cleaning up.")
        ])
        guard !isLoading, !isUpdatingActivation else { throw changed }
        let files = DuplicateCleanupPolicy.unlocking(unlocked, in: duplicateCleanupFiles())
        guard DuplicateCleanupPolicy.canRemove(selected, from: files),
              DuplicateCleanupPolicy.missingNames(afterRemoving: selected, from: files)
                == DuplicateCleanupPolicy.missingNames(afterRemoving: selected, from: reviewed),
              selected.allSatisfy({ url in files.first(where: { $0.url == url }) == reviewed.first(where: { $0.url == url }) })
        else { throw changed }

        func currentNames(at url: URL) -> Set<String> {
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            return Set(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String })
        }
        let removing = files.filter { selected.contains($0.url) }
        for file in removing {
            guard currentNames(at: file.url) == file.names else { throw changed }
        }

        // Not through applyActivation: that records the faces as off, and the
        // surviving copy shares their names.
        // Only registered copies are turned off and, on failure, back on. An
        // installed one in ~/Library/Fonts goes out of use when it moves.
        let active = removing.filter { $0.isActive && CTFontManagerGetScopeForURL($0.url as CFURL) == .user }
        func register(_ enabled: Bool, _ files: [DuplicateCleanupFile]) async -> [FontRegistrationOutcome] {
            guard !files.isEmpty else { return [] }
            let actions = files.map {
                FontRegistrationAction(url: $0.url, names: $0.names, enabled: enabled, skipIfAlreadyScoped: true)
            }
            let outcomes = await registrationQueue.enqueue { [registrar] in await registrar.synchronize(actions) }
            let urls = Set(files.map(\.url))
            await coverage.invalidate(urls: urls)
            FontResolver.shared.invalidate(names: Set(files.flatMap(\.names)), urls: urls)
            return outcomes
        }

        var moved: Set<URL> = []
        // Whatever stays behind is turned back on, so a failure leaves the
        // library as it was.
        defer {
            if !active.isEmpty || !moved.isEmpty {
                let restore = active.filter { !moved.contains($0.url) }
                Task { @MainActor in
                    _ = await register(true, restore)
                    refresh()
                }
            }
        }
        if let failure = await register(false, active).first(where: { !$0.succeeded }) {
            throw NSError(domain: "TypeCase.DuplicateCleanup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: failure.errorDescription ?? failure.url.lastPathComponent
            ])
        }
        // An installed copy still resolves until it moves; every other copy
        // must already be out of Core Text's way.
        let registered = Set(active.map(\.url))
        for file in removing where !file.isActive || registered.contains(file.url) {
            for name in file.names {
                let font = CTFontCreateWithName(name as CFString, 12, nil)
                let resolved = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
                guard resolved?.standardizedFileURL != file.url else { throw changed }
            }
        }
        for file in removing {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            moved.insert(file.url)
        }
    }

    /// Puts the given file paths on the general pasteboard, one per line.
    func copyPaths(_ urls: [URL]) {
        copyStrings(urls.map(\.path))
    }

    /// Puts the given strings on the general pasteboard, one per line.
    func copyStrings(_ strings: [String]) {
        guard !strings.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(strings.joined(separator: "\n"), forType: .string)
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if let index = securityScopedURLs.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            securityScopedURLs[index].stopAccessingSecurityScopedResource()
            securityScopedURLs.remove(at: index)
        }
        saveFolderBookmarks()
        refresh()
    }

    private func saveFolderBookmarks() {
        let bookmarks = folders.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: "fontFolderBookmarks")
    }

    private func restoreFolders() {
        let bookmarks = defaults.array(forKey: "fontFolderBookmarks") as? [Data] ?? []
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            if url.startAccessingSecurityScopedResource() {
                securityScopedURLs.append(url)
            }
            folders.append(url)
        }
        if !bookmarks.isEmpty { saveFolderBookmarks() }
    }

    // MARK: - Loading

    /// Seeds the caches from the saved snapshot and publishes its library, unless
    /// a scan has already started.
    private func adopt(_ snapshot: FontScanSnapshot) async {
        guard !hasLoadedOnce, refreshTask == nil else { return }
        localizedNameCache = snapshot.localizedNameCache
        fileCache = snapshot.files
        installedSeeds = snapshot.installedSeeds
        installedRecords = snapshot.installedRecords
        scannedRoots = snapshot.roots
        manifestNames = snapshot.manifestNames
        snapshotIsCurrent = true
        // Folder records are only valid for the folders they were scanned from;
        // otherwise the scan publishes the library once it has the new folders.
        guard snapshot.roots == folders else { return }

        let activeNames = activeManagedNames
        let deactivatedNames = deactivatedManagedNames
        let grouped = await Task.detached(priority: .userInitiated) {
            Self.group(
                installedRecords: snapshot.installedRecords,
                folderRecords: snapshot.folderRecords,
                activeNames: activeNames,
                deactivatedNames: deactivatedNames
            )
        }.value
        guard !hasLoadedOnce, refreshTask == nil else { return }
        folderRecords = snapshot.folderRecords
        families = grouped
        rebuildIndexes()
        folderTrees = snapshot.folderTrees
        hasLoadedOnce = true
        dataRevision += 1
        familiesRevision += 1
    }

    /// Saves the current scan results for the next launch, off the main actor.
    private func saveSnapshot() {
        snapshotSequence += 1
        let sequence = snapshotSequence
        let snapshot = FontScanSnapshot(
            roots: scannedRoots,
            manifestNames: manifestNames ?? [:],
            installedSeeds: installedSeeds,
            installedRecords: installedRecords,
            folderRecords: folderRecords,
            files: fileCache,
            localizedNameCache: localizedNameCache,
            folderTrees: folderTrees
        )
        let store = snapshotStore
        Task.detached(priority: .utility) {
            await store.save(snapshot, sequence: sequence)
        }
    }

    /// Requests a rescan. Requests that arrive while a scan is running are coalesced
    /// into a single follow-up scan.
    func refresh() {
        if refreshTask != nil {
            refreshQueued = true
            return
        }
        isLoading = true
        errorMessage = nil
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh()
            }
        }
    }

    private func performRefresh() async {
        let roots = folders
        let seeds = await installedFaceSeeds()
        let output = await engine.scan(FontScanInput(
            roots: roots,
            installedSeeds: seeds,
            previousInstalledSeeds: installedSeeds,
            previousInstalledRecords: installedRecords,
            previousFiles: fileCache,
            previousRoots: scannedRoots,
            previousManifestNames: manifestNames,
            localizedNameCache: localizedNameCache
        ))

        // Grouping and localized name sorting can be expensive for large font
        // libraries. Only apply the snapshot if activation has not
        // changed while the background work was running.
        let registrationRevision = userRegistrationRevision
        let activeNames = activeManagedNames
        let deactivatedNames = deactivatedManagedNames
        let grouped: [FontFamily]? = output.hasChanges || !hasLoadedOnce
            ? await Task.detached(priority: .userInitiated) {
                Self.group(
                    installedRecords: output.installedRecords,
                    folderRecords: output.folderRecords,
                    activeNames: activeNames,
                    deactivatedNames: deactivatedNames
                )
            }.value
            : nil

        localizedNameCache = output.localizedNameCache
        fileCache = output.files
        folderRecords = output.folderRecords
        scannedRoots = roots
        // The seeds of this scan are the baseline for the next one; without storing
        // them the installed set looks changed on every refresh.
        installedSeeds = seeds
        manifestNames = output.manifestNames
        lastDirectoryFingerprint = output.directoryFingerprint

        if !output.changedFiles.isEmpty {
            // Coverage is read from the font files themselves, so replaced
            // files must not keep their cached character sets or metadata.
            let changedFiles = Set(output.changedFiles)
            metadataCache.removeAll()
            variableInfoCache.removeAll()
            Task { await coverage.invalidate(urls: changedFiles) }
        }

        if output.hasChanges || !hasLoadedOnce {
            installedRecords = output.installedRecords
            if registrationRevision == userRegistrationRevision,
               let grouped {
                families = grouped
                rebuildIndexes()
                FontResolver.shared.invalidate()
            } else {
                regroup()
            }
            folderTrees = output.folderTrees
            hasLoadedOnce = true
            dataRevision += 1
            familiesRevision += 1

            // Re-registering activated fonts can take a while for large libraries, so the
            // list is published first. A user toggle interrupts the batch at the next file.
            let changedFiles = output.changedFiles
            let files = output.files
            Task { [weak self] in
                guard let self else { return }
                let revision = self.userRegistrationRevision
                let didRegister = await self.registrationQueue.enqueue { [weak self] in
                    guard let self else { return false }
                    return await self.synchronizeFolderRegistration(
                        changedFiles,
                        files: files,
                        abortingWhen: { self.userRegistrationRevision != revision }
                    )
                }
                if didRegister {
                    FontResolver.shared.invalidate()
                    self.dataRevision += 1
                }
            }
        }
        if output.hasChanges || !snapshotIsCurrent {
            saveSnapshot()
            snapshotIsCurrent = true
        }
        isLoading = false
        folderMonitor.update(roots: folders)
    }

    /// Re-registers changed fonts that are activated for the user. Deactivated
    /// fonts are previewed directly from their files by `FontResolver`, so they
    /// are never registered with Core Text. Returns whether any registration
    /// call actually succeeded.
    @discardableResult
    private func synchronizeFolderRegistration(
        _ changedFiles: [URL],
        files: [URL: CachedFontFile],
        abortingWhen shouldAbort: () -> Bool
    ) async -> Bool {
        var didRegister = false
        var actions: [FontRegistrationAction] = []
        for url in changedFiles {
            if shouldAbort() { break }
            guard let cached = files[url], !cached.descriptorNames.isEmpty,
                  !cached.descriptorNames.isDisjoint(with: activeManagedNames) else { continue }
            let action = FontRegistrationAction(
                url: url,
                names: cached.descriptorNames,
                enabled: true,
                skipIfAlreadyScoped: false
            )
            actions.append(action)
        }
        for start in stride(from: 0, to: actions.count, by: Self.registrationBatchSize) {
            if shouldAbort() { break }
            let end = min(start + Self.registrationBatchSize, actions.count)
            let outcomes = await registrar.synchronize(Array(actions[start..<end]))
            if outcomes.contains(where: \.succeeded) { didRegister = true }
        }
        return didRegister
    }

    // MARK: - Activation

    /// Enables or disables every managed file behind the given families,
    /// registering undo when a manager is provided. The row's radio button and
    /// the context menu, including a multi-selection, all come through here.
    func setEnabled(_ enabled: Bool, families: [FontFamily], undoManager: UndoManager? = nil) {
        guard !isUpdatingActivation else { return }
        let states = activationStates(for: families)
            .filter { $0.enabled != enabled }
            .map { FontActivationState(url: $0.url, names: $0.names, enabled: enabled) }
        applyActivation(states, undoManager: undoManager)
    }

    /// Uses file paths rather than family membership: a family's other styles
    /// may live outside this folder. Descendants and collection files count once.
    func activationStates(in folder: URL) -> [FontActivationState] {
        folderActivationFiles[folder.standardizedFileURL] ?? []
    }

    func setEnabled(_ enabled: Bool, in folder: URL, undoManager: UndoManager? = nil) {
        guard !isUpdatingActivation else { return }
        let states = activationStates(in: folder)
            .filter { $0.enabled != enabled }
            .map { FontActivationState(url: $0.url, names: $0.names, enabled: enabled) }
        applyActivation(states, undoManager: undoManager)
    }

    /// Toggles the file shared by the given faces. Core Text registers and
    /// unregisters whole font files, so a style toggles together with every
    /// face that shares its file — the members of a collection, for example.
    func setEnabled(
        _ enabled: Bool,
        faces: [FontFace],
        in family: FontFamily,
        undoManager: UndoManager? = nil
    ) {
        guard !isUpdatingActivation else { return }
        let urls = Set(faces.compactMap(\.fileURL?.standardizedFileURL))
        let states = activationStates(for: [family])
            .filter { urls.contains($0.url.standardizedFileURL) && $0.enabled != enabled }
            .map { FontActivationState(url: $0.url, names: $0.names, enabled: enabled) }
        applyActivation(states, undoManager: undoManager)
    }

    /// Applies explicit per-file activation states and registers an undo that
    /// restores the previous state. Undoing re-registers the reverse, so Redo
    /// works as well.
    func applyActivation(_ states: [FontActivationState], undoManager: UndoManager? = nil) {
        guard !states.isEmpty else { return }
        let previous = activationStates(for: states.map(\.url))
        performActivation(states)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] catalog in
            catalog.applyActivation(previous, undoManager: undoManager)
        }
        undoManager.setActionName(Self.activationActionName(for: states))
    }

    /// The current activation state of every managed file behind the families.
    func activationStates(for families: [FontFamily]) -> [FontActivationState] {
        var states: [FontActivationState] = []
        var seen: Set<URL> = []
        for family in families {
            for face in family.faces where face.isManaged {
                guard let url = face.fileURL, seen.insert(url.standardizedFileURL).inserted else { continue }
                states.append(activationState(for: url, in: family))
            }
        }
        return states
    }

    /// The current activation state of the given files.
    func activationStates(for urls: [URL]) -> [FontActivationState] {
        var states: [FontActivationState] = []
        var seen: Set<URL> = []
        for url in urls {
            guard seen.insert(url.standardizedFileURL).inserted,
                  let match = managedFile(at: url) else { continue }
            states.append(activationState(for: match.url, in: match.family))
        }
        return states
    }

    /// The most recent time a family's files were added to a folder, used by the
    /// "Recently Added" list order. Installed fonts are not in the folder cache
    /// and report 0, so they sort last.
    func addedTime(for family: FontFamily) -> TimeInterval {
        family.faces.compactMap { face -> TimeInterval? in
            guard let url = face.fileURL, let file = fileCache[url] else { return nil }
            return file.stamp.creation > 0 ? file.stamp.creation : file.stamp.modification
        }.max() ?? 0
    }

    private func activationState(for url: URL, in family: FontFamily) -> FontActivationState {
        // The cached descriptor names cover every face of a file, which keeps the
        // recorded activation state in step with the file-level registration. The
        // family's faces are the fallback for a file the cache no longer holds.
        let faces = family.faces.filter { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
        return FontActivationState(
            url: url,
            names: fileCache[url]?.descriptorNames ?? Set(faces.map(\.postScriptName)),
            enabled: faces.contains(where: \.isInstalled)
        )
    }

    /// The managed family and the stored URL behind a file.
    private func managedFile(at url: URL) -> (family: FontFamily, url: URL)? {
        for family in families {
            for face in family.faces where face.isManaged {
                guard let fileURL = face.fileURL,
                      fileURL.standardizedFileURL == url.standardizedFileURL else { continue }
                return (family, fileURL)
            }
        }
        return nil
    }

    private func performActivation(_ states: [FontActivationState]) {
        var enabledByURL: [URL: Bool] = [:]
        var actions: [FontRegistrationAction] = []
        for state in states where enabledByURL[state.url] == nil {
            enabledByURL[state.url] = state.enabled
            actions.append(FontRegistrationAction(
                url: state.url,
                names: state.names,
                enabled: state.enabled,
                skipIfAlreadyScoped: true
            ))
        }
        guard !actions.isEmpty else { return }

        // Publish before starting work so the first click immediately gets
        // feedback. Undo/Redo may enqueue another operation; retain serial order.
        if pendingActivationOperations == 0 {
            activationCompletedFiles = 0
            activationTotalFiles = 0
        }
        pendingActivationOperations += 1
        activationTotalFiles += actions.count
        isUpdatingActivation = true
        userRegistrationRevision += 1
        Task { [weak self] in
            guard let self else { return }
            await self.registrationQueue.enqueue { [weak self] in
                guard let self else { return }
                defer {
                    self.pendingActivationOperations -= 1
                    self.isUpdatingActivation = self.pendingActivationOperations > 0
                }
                var failures: [String] = []
                for start in stride(from: 0, to: actions.count, by: Self.registrationBatchSize) {
                    let end = min(start + Self.registrationBatchSize, actions.count)
                    let batch = Array(actions[start..<end])
                    let outcomes = await self.registrar.synchronize(batch)
                    self.applyToggleOutcomes(outcomes, enabledByURL: enabledByURL, reportErrors: false)
                    failures += outcomes.filter { !$0.succeeded }.map { $0.errorDescription ?? $0.url.lastPathComponent }
                    let successful = outcomes.filter(\.succeeded)
                    let urls = Set(successful.map(\.url))
                    await self.coverage.invalidate(urls: urls)
                    let changedNames = Set(successful.flatMap(\.names))
                    if !changedNames.isEmpty {
                        self.regroup(affectedBy: changedNames)
                        FontResolver.shared.invalidate(names: changedNames, urls: urls)
                    }
                    self.activationCompletedFiles += batch.count
                    self.dataRevision += 1
                }
                if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n") }
            }
        }
    }

    private func applyToggleOutcomes(_ outcomes: [FontRegistrationOutcome], enabledByURL: [URL: Bool], reportErrors: Bool = true) {
        var failures: [String] = []
        for outcome in outcomes {
            let enabled = enabledByURL[outcome.url] ?? true
            if outcome.succeeded {
                if enabled {
                    activeManagedNames.formUnion(outcome.names)
                    deactivatedManagedNames.subtract(outcome.names)
                } else {
                    activeManagedNames.subtract(outcome.names)
                    deactivatedManagedNames.formUnion(outcome.names)
                }
            } else {
                failures.append(outcome.errorDescription ?? outcome.url.lastPathComponent)
            }
        }
        defaults.set(Array(activeManagedNames), forKey: "activeManagedFonts")
        if reportErrors && !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    private static func activationActionName(for states: [FontActivationState]) -> String {
        if states.allSatisfy(\.enabled) { return String(localized: "Activate Fonts") }
        if states.allSatisfy({ !$0.enabled }) { return String(localized: "Deactivate Fonts") }
        return String(localized: "Change Font Activation")
    }

    // MARK: - Character coverage

    /// The families whose preview face can display every character of
    /// `scalars`.
    func coverageMatches(
        families: [CoverageFaceQuery],
        scalars: [Unicode.Scalar]
    ) async -> Set<FontFamily.ID> {
        await coverage.matchingFamilies(families, scalars: scalars)
    }

    /// The characters of `text` the family's preview face cannot display.
    func missingCharacters(in text: String, for family: FontFamily) async -> [String] {
        guard let face = family.previewFace else { return [] }
        return await missingCharacters(in: text, for: face)
    }

    /// The characters of `text` the face cannot display. The family's version
    /// checks the preview face; the PlayGround checks the style a block uses.
    func missingCharacters(in text: String, for face: FontFace) async -> [String] {
        await coverage.missingCharacters(
            postScriptName: face.postScriptName,
            fileURL: face.fileURL,
            text: text
        )
    }

    /// The face's drawable characters grouped for the glyph browser. Reading
    /// and grouping a CJK font's tens of thousands of code points stays off
    /// the main actor.
    func glyphInventory(for face: FontFace) async -> GlyphInventory {
        let codePoints = await coverage.coveredCodePoints(
            postScriptName: face.postScriptName,
            fileURL: face.fileURL
        )
        return await Task.detached(priority: .userInitiated) {
            GlyphInventory(codePoints: codePoints)
        }.value
    }

    /// The preview face's variable axes, or nil for a static font.
    func variableInfo(for family: FontFamily, size: CGFloat) async -> VariableFontInfo? {
        guard let face = family.previewFace else { return nil }
        return await Task.detached(priority: .userInitiated) {
            FontResolver.backgroundVariableInfo(
                postScriptName: face.postScriptName, fileURL: face.fileURL, size: size
            )
        }.value
    }

    /// A face's variable axes and its own coordinates, or nil for a static
    /// face. Cached per face, so expanding a list row again reads nothing.
    func variableInfo(for face: FontFace) async -> VariableFontInfo? {
        if let cached = variableInfoCache[face.postScriptName] { return cached }
        let info = await Task.detached(priority: .userInitiated) {
            FontResolver.backgroundVariableInfo(
                postScriptName: face.postScriptName, fileURL: face.fileURL, size: FontCatalog.variableInfoSize
            )
        }.value
        variableInfoCache[face.postScriptName] = info
        return info
    }

    /// The point size cached axis values are read at; optical-size axes
    /// report their coordinate for this size.
    nonisolated static let variableInfoSize: CGFloat = 40

    /// A face's descriptive metadata, read from its font file off the main
    /// thread and cached per file. Returns nil when the file cannot be read.
    func fontMetadata(forPostScriptName name: String?, fileURL: URL?) async -> FontNameTable.Metadata? {
        guard let fileURL else { return nil }
        let key = (name ?? "").lowercased()
        if let cached = metadataCache[fileURL]?[key] { return cached }
        let metadata = await Task.detached(priority: .userInitiated) {
            FontNameTable.metadata(forPostScriptName: name, inFontAt: fileURL)
        }.value
        guard let metadata else { return nil }
        metadataCache[fileURL, default: [:]][key] = metadata
        return metadata
    }

    // MARK: - Indexes

    /// Rebuilds the full family list from cached records after a scan when the
    /// activation state changed during background grouping.
    private func regroup() {
        families = Self.group(
            installedRecords: installedRecords,
            folderRecords: folderRecords,
            activeNames: activeManagedNames,
            deactivatedNames: deactivatedManagedNames
        )
        rebuildIndexes()
        FontResolver.shared.invalidate()
    }

    nonisolated private static func group(
        installedRecords: [FaceRecord],
        folderRecords: [FaceRecord],
        activeNames: Set<String>,
        deactivatedNames: Set<String>
    ) -> [FontFamily] {
        var installedNames: Set<String> = []
        var records: [FaceRecord] = []
        records.reserveCapacity(installedRecords.count + folderRecords.count)

        for record in installedRecords {
            installedNames.insert(record.face.postScriptName)
            records.append(record.withInstalled(true))
        }
        for record in folderRecords {
            let name = record.face.postScriptName
            // The installed records may still list a font the user deactivated since
            // the last scan, so recently deactivated names are masked until then.
            let isInstalled = activeNames.contains(name)
                || (installedNames.contains(name) && !deactivatedNames.contains(name))
            records.append(record.withInstalled(isInstalled))
        }
        return group(records)
    }

    /// Registration changes only the installed flag of faces in the affected
    /// families. Keep every other row (and its indexes) intact on a click.
    private func regroup(affectedBy names: Set<String>) {
        let affectedIDs = Set(families.lazy.filter { family in
            family.faces.contains { names.contains($0.postScriptName) }
        }.map(\.id))
        guard !affectedIDs.isEmpty else { return }

        let installedNames = Set(installedRecords.map { $0.face.postScriptName })
        var records: [FaceRecord] = []
        for record in installedRecords {
            if affectedIDs.contains(Self.familyID(for: record.family)) {
                records.append(record.withInstalled(true))
            }
        }
        for record in folderRecords {
            guard affectedIDs.contains(Self.familyID(for: record.family)) else { continue }
            let name = record.face.postScriptName
            let installed = activeManagedNames.contains(name)
                || (installedNames.contains(name) && !deactivatedManagedNames.contains(name))
            records.append(record.withInstalled(installed))
        }
        let updated = Dictionary(uniqueKeysWithValues: Self.group(records)
            .map { ($0.id, $0) })
        for index in families.indices {
            if let family = updated[families[index].id] {
                families[index] = family
                familyByID[family.id] = family
            }
        }
        // Activation updates families without rebuilding the full library indexes.
        // Refresh the folder cache too, including ancestors, so indicators and
        // the next toggle use the completed operation's state.
        folderActivationFiles = Self.folderActivationIndex(
            activationStates(for: families), roots: folders.map(\.standardizedFileURL)
        )
    }

    nonisolated private static func familyID(for name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func rebuildIndexes() {
        let roots = folders.map(\.standardizedFileURL)
        let home = SystemFontScope.homeDirectory
        let allUsers = URL(fileURLWithPath: "/Library", isDirectory: true)

        var byID: [FontFamily.ID: FontFamily] = [:]
        byID.reserveCapacity(families.count)
        var scopes: [FontFamily.ID: Set<SystemFontScope>] = [:]
        var ancestors: [FontFamily.ID: Set<URL>] = [:]
        var systemCount = 0
        var sources: [FontSource: Int] = [:]
        var scopeTotals: [SystemFontScope: Int] = [:]
        var folderTotals: [URL: Int] = [:]
        let copiesByName = Self.duplicateCopies(installedRecords: installedRecords, folderRecords: folderRecords)
        var duplicates: [FontFamily.ID: [FontDuplicate]] = [:]

        for family in families {
            byID[family.id] = family
            if !copiesByName.isEmpty {
                let familyDuplicates: [FontDuplicate] = family.faces.compactMap { face in
                    copiesByName[face.postScriptName].map {
                        FontDuplicate(postScriptName: face.postScriptName, styleName: face.styleName, copies: $0)
                    }
                }
                if !familyDuplicates.isEmpty { duplicates[family.id] = familyDuplicates }
            }
            sources[family.source, default: 0] += 1
            if family.source == .system {
                systemCount += 1
                var familyScopes: Set<SystemFontScope> = []
                for face in family.faces {
                    familyScopes.formUnion(Self.systemScopes(for: face, home: home, allUsers: allUsers))
                }
                scopes[family.id] = familyScopes
                for scope in familyScopes { scopeTotals[scope, default: 0] += 1 }
            }
            var familyAncestors: Set<URL> = []
            for face in family.faces where face.isManaged {
                guard let url = face.fileURL else { continue }
                familyAncestors.formUnion(Self.ancestors(of: url, within: roots))
            }
            if !familyAncestors.isEmpty {
                ancestors[family.id] = familyAncestors
                for folder in familyAncestors { folderTotals[folder, default: 0] += 1 }
            }
        }

        // Cache per-folder file states once per catalog revision, keeping the
        // sidebar inexpensive even with a large expanded directory tree.
        folderActivationFiles = Self.folderActivationIndex(activationStates(for: families), roots: roots)

        familyByID = byID
        familyIDs = Set(byID.keys)
        favoriteCount = favorites.intersection(familyIDs).count
        familySystemScopes = scopes
        familyFolderAncestors = ancestors
        systemFontCount = systemCount
        sourceCounts = sources
        scopeCounts = scopeTotals
        folderCounts = folderTotals
        duplicatesByFamily = duplicates
        rebuildTagCounts()
    }

    nonisolated static func folderActivationIndex(
        _ states: [FontActivationState], roots: [URL]
    ) -> [URL: [FontActivationState]] {
        var index: [URL: [FontActivationState]] = [:]
        var seen: Set<URL> = []
        for state in states where seen.insert(state.url.standardizedFileURL).inserted {
            for folder in ancestors(of: state.url, within: roots) {
                index[folder, default: []].append(state)
            }
        }
        return index
    }

    /// The files of every PostScript name that more than one file provides.
    ///
    /// The installed records name the file Core Text resolves each name to,
    /// so that copy is the one in use; a folder font TypeCase activated is the
    /// same file in both lists and is not a duplicate of itself. Two installed
    /// files with one name are invisible here, because the installed font list
    /// reports each name once.
    private static func duplicateCopies(
        installedRecords: [FaceRecord],
        folderRecords: [FaceRecord]
    ) -> [String: [FontFileCopy]] {
        var inUse: [String: URL] = [:]
        var copies: [String: [URL: FontSource]] = [:]
        for record in installedRecords {
            guard let url = record.face.fileURL?.standardizedFileURL else { continue }
            inUse[record.face.postScriptName] = url
            copies[record.face.postScriptName, default: [:]][url] = record.source
        }
        for record in folderRecords {
            guard let url = record.face.fileURL?.standardizedFileURL else { continue }
            if copies[record.face.postScriptName]?[url] == nil {
                copies[record.face.postScriptName, default: [:]][url] = record.source
            }
        }
        return copies.reduce(into: [:]) { result, entry in
            guard entry.value.count > 1 else { return }
            let name = entry.key
            result[name] = entry.value
                .map { FontFileCopy(url: $0.key, source: $0.value, isInUse: inUse[name] == $0.key) }
                .sorted {
                    if $0.isInUse != $1.isInUse { return $0.isInUse }
                    return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
        }
    }

    private static func systemScopes(for face: FontFace, home: URL, allUsers: URL) -> Set<SystemFontScope> {
        guard let url = face.fileURL else { return [.system] }
        let belongsToUser = url.isContained(in: home)
        let belongsToAllUsers = url.isContained(in: allUsers)
        var result: Set<SystemFontScope> = []
        if belongsToUser { result.insert(.user) }
        if belongsToAllUsers { result.insert(.allUsers) }
        if !belongsToUser && !belongsToAllUsers { result.insert(.system) }
        return result
    }

    /// Every directory between a font file and the outermost added folder that
    /// contains it. Folder sections match against this set instead of resolving
    /// paths while filtering.
    nonisolated private static func ancestors(of url: URL, within roots: [URL]) -> Set<URL> {
        let file = url.standardizedFileURL
        let components = file.pathComponents

        var matchedRoot: URL?
        var matchedDepth = Int.max
        for root in roots {
            let rootComponents = root.pathComponents
            guard components.count >= rootComponents.count,
                  zip(components, rootComponents).allSatisfy(==) else { continue }
            if rootComponents.count < matchedDepth {
                matchedRoot = root
                matchedDepth = rootComponents.count
            }
        }
        guard let matchedRoot else { return [] }

        var result: Set<URL> = []
        var current = file.deletingLastPathComponent()
        while true {
            result.insert(current)
            if current == matchedRoot { break }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return result
    }

    // MARK: - Installed fonts

    /// Enumerates installed faces with AppKit. The heavy metadata extraction
    /// happens later on the scan engine.
    ///
    /// `NSFontManager` is main-actor only and listing every family's members
    /// takes a few hundred milliseconds, so the work yields to the run loop
    /// every few milliseconds instead of freezing the window. The family names
    /// come from Core Text, which lists the same families off the main actor.
    private func installedFaceSeeds() async -> [InstalledFaceSeed] {
        let familyNames = await Task.detached(priority: .userInitiated) {
            CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        }.value
        var seeds: [InstalledFaceSeed] = []
        let manager = NSFontManager.shared
        var sliceStart = CFAbsoluteTimeGetCurrent()
        for family in familyNames {
            if CFAbsoluteTimeGetCurrent() - sliceStart > Self.seedSliceDuration {
                await Task.yield()
                sliceStart = CFAbsoluteTimeGetCurrent()
            }
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            for member in members {
                guard member.count >= 4,
                      let postScriptName = member[0] as? String,
                      let styleName = member[1] as? String,
                      let weight = member[2] as? Int else { continue }
                seeds.append(InstalledFaceSeed(
                    family: family,
                    postScriptName: postScriptName,
                    styleName: styleName,
                    weight: weight
                ))
            }
        }
        return seeds
    }

    /// How long the installed-font listing may hold the main actor at a time:
    /// half a frame, so scrolling and typing stay smooth while it runs.
    private static let seedSliceDuration: CFAbsoluteTime = 0.008

    nonisolated private static func group(_ records: [FaceRecord]) -> [FontFamily] {
        Dictionary(grouping: records, by: {
            familyID(for: $0.family)
        })
        .compactMap { id, records -> FontFamily? in
            guard let first = records.first else { return nil }
            var facesByName: [String: FontFace] = [:]
            var categoriesByName: [String: FontCategory] = [:]
            for record in records {
                let existing = facesByName[record.face.postScriptName]
                if existing == nil || record.face.isManaged {
                    facesByName[record.face.postScriptName] = record.face
                    categoriesByName[record.face.postScriptName] = record.category
                }
            }
            // The PostScript name settles faces with the same weight and style
            // name (e.g. a static and a variable file), so the order does not
            // depend on dictionary iteration.
            let deduplicated = facesByName.values.sorted {
                if $0.weight != $1.weight { return $0.weight < $1.weight }
                if $0.styleName != $1.styleName { return $0.styleName < $1.styleName }
                return $0.postScriptName < $1.postScriptName
            }
            let source: FontSource
            if let provider = records.compactMap(\.source.provider).min(by: { $0.order < $1.order }) {
                source = .provider(provider)
            } else if records.contains(where: { $0.source == .local }) {
                source = .local
            } else {
                source = .system
            }
            let languages = Set(records.flatMap(\.languages))
            let localizedNames = records.reduce(into: [FontLanguage: String]()) { names, record in
                for (language, name) in record.localizedNames where names[language] == nil {
                    names[language] = name
                }
            }
            let detectedCategory = FontClassifier.familyCategory(Array(categoriesByName.values))
            return FontFamily(
                id: id,
                localizedName: first.family,
                languages: languages,
                localizedNames: localizedNames,
                manufacturer: first.manufacturer,
                source: source,
                category: detectedCategory,
                faces: deduplicated
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Backstop

    /// A low-frequency directory check that catches changes FSEvents may have missed.
    private func startBackstopTimer() {
        backstopTimer?.invalidate()
        backstopTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDirectoryFingerprint()
            }
        }
        backstopTimer?.tolerance = 15
    }

    private func checkDirectoryFingerprint() async {
        guard hasLoadedOnce, !folders.isEmpty, refreshTask == nil else { return }
        let fingerprint = await engine.directoryFingerprint(roots: folders)
        guard fingerprint != lastDirectoryFingerprint else { return }
        refresh()
    }
}

/// Serializes asynchronous work that must not interleave on the main actor.
@MainActor
private final class SerialWorkQueue {
    private var tail: Task<Void, Never> = Task {}

    func enqueue<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () async -> T in
            await previous.value
            return await work()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}
