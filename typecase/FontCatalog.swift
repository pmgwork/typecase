import AppKit
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
    @Published private(set) var userTags: [String: Set<String>] = [:]
    @Published private(set) var categoryOverrides: [String: FontCategory] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
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
    private var japaneseNameCache: [URL: [String: String]] = [:]
    private var fileCache: [URL: CachedFontFile] = [:]
    private var installedRecords: [FaceRecord] = []
    private var folderRecords: [FaceRecord] = []
    private var installedSeeds: [InstalledFaceSeed] = []
    private var scannedRoots: [URL] = []
    private var metadataCache: [URL: [String: FontNameTable.Metadata]] = [:]
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
        categoryOverrides = (defaults.dictionary(forKey: "categoryOverrides") as? [String: String] ?? [:])
            .compactMapValues(FontCategory.init(rawValue:))
        activeManagedNames = Set(defaults.stringArray(forKey: "activeManagedFonts") ?? [])
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
        refresh()
    }

    // MARK: - User data

    func isFavorite(_ family: FontFamily) -> Bool {
        favorites.contains(family.id)
    }

    func toggleFavorite(_ family: FontFamily) {
        if favorites.contains(family.id) {
            favorites.remove(family.id)
        } else {
            favorites.insert(family.id)
        }
        defaults.set(Array(favorites), forKey: "favoriteFamilies")
        dataRevision += 1
    }

    func tags(for family: FontFamily) -> [String] {
        Array(userTags[family.id] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func addTag(_ tag: String, to family: FontFamily) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        userTags[family.id, default: []].insert(normalized)
        saveTags()
    }

    func removeTag(_ tag: String, from family: FontFamily) {
        userTags[family.id]?.remove(tag)
        if userTags[family.id]?.isEmpty == true { userTags.removeValue(forKey: family.id) }
        saveTags()
    }

    func setCategory(_ category: FontCategory, for family: FontFamily) {
        categoryOverrides[family.id] = category
        defaults.set(categoryOverrides.mapValues(\.rawValue), forKey: "categoryOverrides")
        regroup()
        dataRevision += 1
    }

    private func saveTags() {
        defaults.set(userTags.mapValues(Array.init), forKey: "familyTags")
        rebuildAllTags()
        dataRevision += 1
    }

    private func rebuildAllTags() {
        allTags = Set(userTags.values.flatMap { $0 })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Selection helpers

    func family(for selection: Set<FontFamily.ID>) -> FontFamily? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return familyByID[id]
    }

    /// Returns the unfiltered family count represented by a sidebar destination.
    /// The sidebar requests this only for its selected row.
    func fontCount(for selection: LibrarySelection) -> Int {
        switch selection {
        case .section(let section):
            if let provider = section.provider {
                return families.lazy.filter { $0.source == .provider(provider) }.count
            }
            switch section {
            case .favorites:
                return favorites.intersection(familyIDs).count
            case .system:
                return systemFontCount
            case .local:
                return families.lazy.filter { $0.source == .local }.count
            default:
                return families.count
            }
        case .systemScope(let scope):
            return familySystemScopes.values.lazy.filter { $0.contains(scope) }.count
        case .folder(let folder):
            let standardizedFolder = folder.standardizedFileURL
            return familyFolderAncestors.values.lazy
                .filter { $0.contains(standardizedFolder) }
                .count
        }
    }

    // MARK: - Folders

    func addFolder(onAdded: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose a font folder"
        panel.prompt = "Add Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        // Present after the current menu or toolbar action finishes; a modal panel started from
        // inside a menu tracking session does not appear.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
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
        let seeds = installedFaceSeeds()
        let output = await engine.scan(FontScanInput(
            roots: roots,
            installedSeeds: seeds,
            previousInstalledSeeds: installedSeeds,
            previousInstalledRecords: installedRecords,
            previousFiles: fileCache,
            previousRoots: scannedRoots,
            japaneseNameCache: japaneseNameCache
        ))

        japaneseNameCache = output.japaneseNameCache
        fileCache = output.files
        folderRecords = output.folderRecords
        scannedRoots = roots
        // The seeds of this scan are the baseline for the next one; without storing
        // them the installed set looks changed on every refresh.
        installedSeeds = seeds
        lastDirectoryFingerprint = output.directoryFingerprint

        if !output.changedFiles.isEmpty {
            // Coverage is read from the font files themselves, so replaced
            // files must not keep their cached character sets or metadata.
            let changedFiles = Set(output.changedFiles)
            metadataCache.removeAll()
            Task { await coverage.invalidate(urls: changedFiles) }
        }

        if output.hasChanges || !hasLoadedOnce {
            installedRecords = output.installedRecords
            regroup()
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
            let outcomes = await registrar.synchronize([action])
            if outcomes.contains(where: \.succeeded) { didRegister = true }
        }
        return didRegister
    }

    // MARK: - Activation

    /// Enables or disables every managed file behind the given families,
    /// registering undo when a manager is provided. The row's radio button and
    /// the context menu, including a multi-selection, all come through here.
    func setEnabled(_ enabled: Bool, families: [FontFamily], undoManager: UndoManager? = nil) {
        let states = activationStates(for: families)
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

        let urls = Set(enabledByURL.keys)
        userRegistrationRevision += 1
        Task { [weak self] in
            guard let self else { return }
            await self.registrationQueue.enqueue { [weak self] in
                guard let self else { return }
                let outcomes = await self.registrar.synchronize(actions)
                self.applyToggleOutcomes(outcomes, enabledByURL: enabledByURL)
                // Activation switches a face between the registered font and
                // its file, which can resolve to different coverage data.
                await self.coverage.invalidate(urls: urls)
                self.regroup()
                self.dataRevision += 1
            }
        }
    }

    private func applyToggleOutcomes(_ outcomes: [FontRegistrationOutcome], enabledByURL: [URL: Bool]) {
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
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    private static func activationActionName(for states: [FontActivationState]) -> String {
        if states.allSatisfy(\.enabled) { return "Activate Fonts" }
        if states.allSatisfy({ !$0.enabled }) { return "Deactivate Fonts" }
        return "Change Font Activation"
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
        return await coverage.missingCharacters(
            postScriptName: face.postScriptName,
            fileURL: face.fileURL,
            text: text
        )
    }

    /// The preview face's variable axes, or nil for a static font.
    func variableInfo(for family: FontFamily, size: CGFloat) -> VariableFontInfo? {
        guard let face = family.previewFace else { return nil }
        return FontResolver.shared.variableInfo(
            postScriptName: face.postScriptName,
            fileURL: face.fileURL,
            size: size
        )
    }

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

    /// Rebuilds the family list from the cached records using the current
    /// activation state. Cheap enough to run after a toggle or a category change.
    private func regroup() {
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
            let isInstalled = activeManagedNames.contains(name)
                || (installedNames.contains(name) && !deactivatedManagedNames.contains(name))
            records.append(record.withInstalled(isInstalled))
        }

        families = Self.group(records, categoryOverrides: categoryOverrides)
        rebuildIndexes()
        FontResolver.shared.invalidate()
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

        for family in families {
            byID[family.id] = family
            if family.source == .system {
                systemCount += 1
                var familyScopes: Set<SystemFontScope> = []
                for face in family.faces {
                    familyScopes.formUnion(Self.systemScopes(for: face, home: home, allUsers: allUsers))
                }
                scopes[family.id] = familyScopes
            }
            var familyAncestors: Set<URL> = []
            for face in family.faces where face.isManaged {
                guard let url = face.fileURL else { continue }
                familyAncestors.formUnion(Self.ancestors(of: url, within: roots))
            }
            if !familyAncestors.isEmpty {
                ancestors[family.id] = familyAncestors
            }
        }

        familyByID = byID
        familyIDs = Set(byID.keys)
        familySystemScopes = scopes
        familyFolderAncestors = ancestors
        systemFontCount = systemCount
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
    private static func ancestors(of url: URL, within roots: [URL]) -> Set<URL> {
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

    /// Enumerates installed faces with AppKit (main-actor only). The heavy
    /// metadata extraction happens later on the scan engine.
    private func installedFaceSeeds() -> [InstalledFaceSeed] {
        var seeds: [InstalledFaceSeed] = []
        let manager = NSFontManager.shared
        for family in manager.availableFontFamilies {
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

    private static func group(_ records: [FaceRecord], categoryOverrides: [String: FontCategory]) -> [FontFamily] {
        Dictionary(grouping: records, by: {
            $0.family.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        .compactMap { id, records -> FontFamily? in
            guard let first = records.first else { return nil }
            var facesByName: [String: FontFace] = [:]
            for record in records {
                let existing = facesByName[record.face.postScriptName]
                if existing == nil || record.face.isManaged {
                    facesByName[record.face.postScriptName] = record.face
                }
            }
            let deduplicated = facesByName.values.sorted {
                if $0.weight == $1.weight { return $0.styleName < $1.styleName }
                return $0.weight < $1.weight
            }
            let source: FontSource
            if let provider = records.compactMap(\.source.provider).min(by: { $0.order < $1.order }) {
                source = .provider(provider)
            } else if records.contains(where: { $0.source == .local }) {
                source = .local
            } else {
                source = .system
            }
            return FontFamily(
                id: id,
                name: records.compactMap(\.japaneseName).first ?? first.family,
                localizedName: first.family,
                manufacturer: first.manufacturer,
                source: source,
                category: categoryOverrides[id] ?? first.category,
                supportsJapanese: records.contains(where: \.supportsJapanese),
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
