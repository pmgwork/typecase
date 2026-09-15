import AppKit
import Combine
import CoreText

@MainActor
final class FontLibraryStore: NSObject, ObservableObject {
    @Published private(set) var families: [FontFamily] = []
    @Published private(set) var folders: [URL] = []
    @Published private(set) var folderTrees: [FontFolderNode] = []
    @Published var selection: Set<FontFamily.ID> = []
    @Published var searchText = ""
    @Published var librarySelection: LibrarySelection = .section(.all)
    @Published var category: FontCategory?
    @Published var activationFilter: ActivationFilter = .all
    @Published var previewText = ""
    @Published var previewSize: Double = 32
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var userTags: [String: Set<String>] = [:]
    @Published private(set) var categoryOverrides: [String: FontCategory] = [:]
    private var activeManagedNames: Set<String> = []
    private var processRegisteredNames: Set<String> = []
    private var japaneseNameCache: [URL: [String: String]] = [:]
    private var folderTimer: Timer?
    private var folderFingerprint = ""
    private var securityScopedURLs: [URL] = []

    override init() {
        super.init()
        favorites = Set(defaults.stringArray(forKey: "favoriteFamilies") ?? [])
        userTags = (defaults.dictionary(forKey: "familyTags") as? [String: [String]] ?? [:])
            .mapValues(Set.init)
        categoryOverrides = (defaults.dictionary(forKey: "categoryOverrides") as? [String: String] ?? [:])
            .compactMapValues(FontCategory.init(rawValue:))
        activeManagedNames = Set(defaults.stringArray(forKey: "activeManagedFonts") ?? [])
        restoreFolders()
        refresh()
        startFolderMonitoring()
    }

    var filteredFamilies: [FontFamily] {
        families.filter { family in
            guard matchesSection(family) else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || family.name.localizedCaseInsensitiveContains(query)
                || family.localizedName.localizedCaseInsensitiveContains(query)
                || family.manufacturer.localizedCaseInsensitiveContains(query)
                || tags(for: family).contains(where: { $0.localizedCaseInsensitiveContains(query) })
            let matchesCategory = category == nil || family.category == category
            let matchesActivation = switch activationFilter {
            case .all: true
            case .enabled: family.isEnabled
            case .disabled: !family.isEnabled
            }
            return matchesSearch && matchesCategory && matchesActivation
        }
    }

    var sectionIsEmpty: Bool {
        !families.contains(where: matchesSection)
    }

    func clearFilters() {
        searchText = ""
        category = nil
        activationFilter = .all
    }

    private func matchesSection(_ family: FontFamily) -> Bool {
        switch librarySelection {
        case .section(.all): true
        case .section(.favorites): favorites.contains(family.id)
        case .section(.system): family.source == .system
        case .section(.local): family.source == .local
        case .section(.adobe): family.source == .adobe
        case .section(.morisawa): family.source == .morisawa
        case .systemScope(let scope): matchesSystemScope(family, scope: scope)
        case .folder(let folder):
            family.faces.contains { face in
                guard face.isManaged, let fileURL = face.fileURL else { return false }
                return fileURL.isContained(in: folder)
            }
        }
    }

    private func matchesSystemScope(_ family: FontFamily, scope: SystemFontScope) -> Bool {
        guard family.source == .system else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let allUsers = URL(fileURLWithPath: "/Library", isDirectory: true)

        return family.faces.contains { face in
            guard let url = face.fileURL else { return scope == .system }
            let belongsToUser = url.isContained(in: home)
            let belongsToAllUsers = url.isContained(in: allUsers)
            return switch scope {
            case .user: belongsToUser
            case .allUsers: belongsToAllUsers
            case .system: !belongsToUser && !belongsToAllUsers
            }
        }
    }

    var selectedFamilies: [FontFamily] {
        families.filter { selection.contains($0.id) }
    }

    var selectedFamily: FontFamily? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return families.first(where: { $0.id == id })
    }

    func previewText(for family: FontFamily) -> String {
        let customText = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customText.isEmpty { return previewText }
        return family.supportsJapanese
            ? "美しい文字は、言葉の表情を豊かにする。"
            : "Typography gives every word a distinct voice."
    }

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
    }

    var allTags: [String] {
        Set(userTags.values.flatMap { $0 }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
        updateFamily(id: family.id)
    }

    func addFolder() {
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
                    Task { @MainActor in self.adoptFolders(from: panel, response: response) }
                }
            } else {
                panel.begin { response in
                    Task { @MainActor in self.adoptFolders(from: panel, response: response) }
                }
            }
        }
    }

    private func adoptFolders(from panel: NSOpenPanel, response: NSApplication.ModalResponse) {
        guard response == .OK else { return }
        addFolders(panel.urls)
    }

    @discardableResult
    func addFolders(_ urls: [URL]) -> Bool {
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

        guard let firstAddedFolder else { return false }
        saveFolderBookmarks()
        refresh()
        librarySelection = .folder(firstAddedFolder)
        return true
    }

    func revealFolder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func removeFolder(_ url: URL) {
        if case .folder(let selectedFolder) = librarySelection,
           selectedFolder.isContained(in: url) {
            librarySelection = .section(.local)
        }
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if let index = securityScopedURLs.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            securityScopedURLs[index].stopAccessingSecurityScopedResource()
            securityScopedURLs.remove(at: index)
        }
        saveFolderBookmarks()
        refresh()
    }

    func refresh() {
        isLoading = true
        errorMessage = nil

        let installed = installedFaces()
        var records = installed
        let installedNames = Set(installed.filter(\.face.isInstalled).map(\.face.postScriptName))
        var filesByFolder: [URL: [URL]] = [:]

        for folder in folders {
            let files = fontFiles(in: folder)
            filesByFolder[folder] = files
            for url in files {
                guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { continue }
                let descriptorNames = Set(descriptors.compactMap { self.attribute($0, key: kCTFontNameAttribute) })
                if !descriptors.isEmpty {
                    var unmanagedError: Unmanaged<CFError>?
                    if descriptorNames.isDisjoint(with: activeManagedNames) {
                        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError) {
                            processRegisteredNames.formUnion(descriptorNames)
                        }
                    } else {
                        // Re-register saved user fonts when TypeCase starts, including after login.
                        CTFontManagerRegisterFontsForURL(url as CFURL, .user, &unmanagedError)
                    }
                }
                for descriptor in descriptors {
                    guard let record = makeRecord(
                        descriptor: descriptor,
                        fallbackURL: url,
                        installedNames: installedNames,
                        managed: true
                    ) else { continue }
                    records.append(record)
                }
            }
        }

        folderTrees = folders
            .map { makeFolderTree(root: $0, fontFiles: filesByFolder[$0] ?? []) }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        families = group(records)
        selection = selection.filter { id in families.contains(where: { $0.id == id }) }
        if selection.isEmpty, let first = families.first?.id {
            selection = [first]
        }
        folderFingerprint = makeFolderFingerprint()
        isLoading = false
    }

    func setEnabled(_ enabled: Bool, family: FontFamily) {
        guard family.isManaged else {
            errorMessage = "Only fonts from an added local folder can be changed here."
            return
        }

        var failures: [String] = []
        let urls = Set(family.faces.filter(\.isManaged).compactMap(\.fileURL))
        for url in urls {
            let affectedNames = Set(family.faces.filter { $0.fileURL == url }.map(\.postScriptName))
            var unmanagedError: Unmanaged<CFError>?
            let succeeded: Bool
            if enabled {
                CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
                succeeded = CTFontManagerRegisterFontsForURL(url as CFURL, .user, &unmanagedError)
                if succeeded {
                    processRegisteredNames.subtract(affectedNames)
                    activeManagedNames.formUnion(affectedNames)
                } else {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            } else {
                succeeded = CTFontManagerUnregisterFontsForURL(url as CFURL, .user, &unmanagedError)
                if succeeded {
                    activeManagedNames.subtract(affectedNames)
                    if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) {
                        processRegisteredNames.formUnion(affectedNames)
                    }
                }
            }
            if !succeeded {
                let message = unmanagedError?.takeRetainedValue().localizedDescription ?? url.lastPathComponent
                failures.append(message)
            }
        }
        defaults.set(Array(activeManagedNames), forKey: "activeManagedFonts")
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
        updateFamily(id: family.id)
    }

    private func updateFamily(id: FontFamily.ID) {
        guard let index = families.firstIndex(where: { $0.id == id }) else { return }
        let family = families[index]
        let faces = family.faces.map { face in
            FontFace(
                postScriptName: face.postScriptName,
                styleName: face.styleName,
                weight: face.weight,
                fileURL: face.fileURL,
                isInstalled: face.isManaged ? activeManagedNames.contains(face.postScriptName) : face.isInstalled,
                isManaged: face.isManaged
            )
        }
        families[index] = FontFamily(
            id: family.id,
            name: family.name,
            localizedName: family.localizedName,
            manufacturer: family.manufacturer,
            source: family.source,
            category: categoryOverrides[family.id] ?? family.category,
            supportsJapanese: family.supportsJapanese,
            faces: faces
        )
    }

    private struct FaceRecord {
        let family: String
        let japaneseName: String?
        let manufacturer: String
        let source: FontSource
        let category: FontCategory
        let supportsJapanese: Bool
        let face: FontFace
    }

    private func installedFaces() -> [FaceRecord] {
        var output: [FaceRecord] = []
        let manager = NSFontManager.shared
        for family in manager.availableFontFamilies {
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            for member in members {
                guard member.count >= 4,
                      let postScriptName = member[0] as? String,
                      let styleName = member[1] as? String,
                      let weight = member[2] as? Int else { continue }
                let descriptor = CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, 0)
                if let record = makeRecord(
                    descriptor: descriptor,
                    fallbackFamily: family,
                    fallbackStyle: styleName,
                    fallbackWeight: weight,
                    installedNames: processRegisteredNames.contains(postScriptName) && !activeManagedNames.contains(postScriptName)
                        ? []
                        : [postScriptName],
                    managed: false
                ) {
                    output.append(record)
                }
            }
        }
        return output
    }

    private func makeRecord(
        descriptor: CTFontDescriptor,
        fallbackURL: URL? = nil,
        fallbackFamily: String? = nil,
        fallbackStyle: String? = nil,
        fallbackWeight: Int = 5,
        installedNames: Set<String>,
        managed: Bool
    ) -> FaceRecord? {
        let family = attribute(descriptor, key: kCTFontFamilyNameAttribute) ?? fallbackFamily
        let name = attribute(descriptor, key: kCTFontNameAttribute)
        guard let family, let name else { return nil }
        let style = attribute(descriptor, key: kCTFontStyleNameAttribute) ?? fallbackStyle ?? "Regular"
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let manufacturer = CTFontCopyName(font, kCTFontManufacturerNameKey) as String? ?? "Unknown"
        let descriptorURL = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
        let fontURL = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
        let url = fallbackURL ?? descriptorURL ?? fontURL
        let source = fontSource(url: url, manufacturer: manufacturer, managed: managed)
        let languages = CTFontDescriptorCopyAttribute(descriptor, kCTFontLanguagesAttribute) as? [String] ?? []
        let supportsJapanese = languages.contains { $0 == "ja" || $0.hasPrefix("ja-") }
        // Only Japanese fonts can carry a Japanese name, so skip the name table for the rest.
        let japaneseName = supportsJapanese ? japaneseFamilyName(for: url, family: family) : nil
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let category = classify(family: family, style: style, symbolicTraits: symbolic)
        let installed = installedNames.contains(name) || activeManagedNames.contains(name)
        let face = FontFace(
            postScriptName: name,
            styleName: style,
            weight: fallbackWeight,
            fileURL: url,
            isInstalled: installed,
            isManaged: managed
        )
        return FaceRecord(
            family: family,
            japaneseName: japaneseName,
            manufacturer: manufacturer,
            source: source,
            category: category,
            supportsJapanese: supportsJapanese,
            face: face
        )
    }

    private func japaneseFamilyName(for url: URL?, family: String) -> String? {
        guard let url else { return nil }
        let mapping: [String: String]
        if let cached = japaneseNameCache[url] {
            mapping = cached
        } else {
            mapping = FontNameTable.japaneseFamilies(inFontAt: url)
            japaneseNameCache[url] = mapping
        }
        return mapping[family.lowercased()]
    }

    private func attribute(_ descriptor: CTFontDescriptor, key: CFString) -> String? {
        CTFontDescriptorCopyAttribute(descriptor, key) as? String
    }

    private func fontSource(url: URL?, manufacturer: String, managed: Bool) -> FontSource {
        let searchable = "\(url?.path ?? "") \(manufacturer)".lowercased()
        if searchable.contains("adobe") || searchable.contains("coresync") || searchable.contains("livetype") {
            return .adobe
        }
        if searchable.contains("/library/fonts/morisawafonts/") {
            return .morisawa
        }
        return managed ? .local : .system
    }

    private func classify(family: String, style: String, symbolicTraits: UInt32) -> FontCategory {
        let searchable = "\(family) \(style)".lowercased()
        if symbolicTraits & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0 || searchable.contains("mono") {
            return .monospaced
        }
        if searchable.contains("serif") || searchable.contains("明朝") {
            return .serif
        }
        if searchable.contains("sans") || searchable.contains("gothic") || searchable.contains("ゴシック") {
            return .sansSerif
        }
        if searchable.contains("display") || searchable.contains("script") || searchable.contains("decorative") {
            return .display
        }
        return .unclassified
    }

    private func group(_ records: [FaceRecord]) -> [FontFamily] {
        Dictionary(grouping: records, by: { $0.family.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
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
                if records.contains(where: { $0.source == .adobe }) {
                    source = .adobe
                } else if records.contains(where: { $0.source == .morisawa }) {
                    source = .morisawa
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

    private func fontFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            ["otf", "ttf", "ttc", "dfont"].contains($0.pathExtension.lowercased())
        }
    }

    private func makeFolderTree(root: URL, fontFiles: [URL]) -> FontFolderNode {
        let normalizedRoot = root.standardizedFileURL
        var childrenByFolder: [URL: Set<URL>] = [:]

        for file in fontFiles {
            var child = file.standardizedFileURL.deletingLastPathComponent()
            while child != normalizedRoot, child.isContained(in: normalizedRoot) {
                let parent = child.deletingLastPathComponent()
                childrenByFolder[parent, default: []].insert(child)
                child = parent
            }
        }

        func makeNode(_ url: URL) -> FontFolderNode {
            let children = (childrenByFolder[url] ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map(makeNode)
            return FontFolderNode(url: url, children: children.isEmpty ? nil : children)
        }

        return makeNode(normalizedRoot)
    }

    private func startFolderMonitoring() {
        folderTimer = Timer.scheduledTimer(
            timeInterval: 3,
            target: self,
            selector: #selector(checkFolderChanges),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func checkFolderChanges() {
        let fingerprint = makeFolderFingerprint()
        if fingerprint != folderFingerprint { refresh() }
    }

    private func makeFolderFingerprint() -> String {
        folders.flatMap(fontFiles).map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        }.sorted().joined(separator: "\n")
    }

    private func saveFolderBookmarks() {
        let bookmarks = folders.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: "fontFolderBookmarks")
    }

    private func saveTags() {
        defaults.set(userTags.mapValues(Array.init), forKey: "familyTags")
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
}

private extension URL {
    func isContained(in directory: URL) -> Bool {
        let fileComponents = standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let directoryComponents = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= directoryComponents.count else { return false }
        return zip(fileComponents, directoryComponents).allSatisfy(==)
    }
}
