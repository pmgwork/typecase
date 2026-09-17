import CoreText
import Foundation

/// A font face parsed from a font file or from the installed font set.
///
/// The `installed` flag on the face is a placeholder: the catalog recomputes it
/// from the current activation state when records are applied.
nonisolated struct FaceRecord: Sendable {
    let family: String
    /// The localized family names the face's file provides for the languages
    /// the face declares, by language.
    let localizedNames: [FontLanguage: String]
    let manufacturer: String
    let source: FontSource
    let category: FontCategory
    /// The CJK languages the face declares; empty for Latin-only faces.
    let languages: Set<FontLanguage>
    let face: FontFace

    func withInstalled(_ installed: Bool) -> FaceRecord {
        FaceRecord(
            family: family,
            localizedNames: localizedNames,
            manufacturer: manufacturer,
            source: source,
            category: category,
            languages: languages,
            face: FontFace(
                postScriptName: face.postScriptName,
                styleName: face.styleName,
                weight: face.weight,
                fileURL: face.fileURL,
                isInstalled: installed,
                isManaged: face.isManaged
            )
        )
    }
}

/// A lightweight description of an installed face, produced on the main actor by `NSFontManager`.
nonisolated struct InstalledFaceSeed: Hashable, Sendable {
    let family: String
    let postScriptName: String
    let styleName: String
    let weight: Int
}

nonisolated struct FontFileStamp: Hashable, Sendable {
    let modification: TimeInterval
    /// When the file was created, which is when a font was added to a folder.
    /// `0` when the file system does not report it.
    let creation: TimeInterval
    let size: Int64
}

nonisolated struct CachedFontFile: Sendable {
    let stamp: FontFileStamp
    let descriptorNames: Set<String>
    let records: [FaceRecord]
}

nonisolated struct FontScanInput: Sendable {
    let roots: [URL]
    let installedSeeds: [InstalledFaceSeed]
    let previousInstalledSeeds: [InstalledFaceSeed]
    let previousInstalledRecords: [FaceRecord]
    let previousFiles: [URL: CachedFontFile]
    let previousRoots: [URL]
    let localizedNameCache: [URL: [String: FontNameTable.LocalizedFamily]]
}

nonisolated struct FontScanOutput: Sendable {
    let installedRecords: [FaceRecord]
    let folderRecords: [FaceRecord]
    let files: [URL: CachedFontFile]
    let localizedNameCache: [URL: [String: FontNameTable.LocalizedFamily]]
    /// Files that were added or whose modification date or size changed; these need registration.
    let changedFiles: [URL]
    let folderTrees: [FontFolderNode]
    let directoryFingerprint: UInt64
    let hasChanges: Bool
}

/// Parses font files and folder trees away from the main actor.
///
/// The engine keeps no state between scans. Callers pass in the previous file
/// cache and receive an updated one, so unchanged files are never re-parsed and
/// a scan never blocks the UI.
actor FontScanEngine {
    private static let fontExtensions: Set<String> = ["otf", "ttf", "ttc", "dfont"]

    private var manifestCache: [String: (stamp: [Date?], names: Set<String>)] = [:]

    /// The font file names each provider's app records, reread only when a
    /// manifest's modification date changes.
    private func providerManifestNames() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for provider in FontProviderRegistry.all where !provider.manifestURLs.isEmpty {
            let stamp: [Date?] = provider.manifestURLs.map { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            if let cached = manifestCache[provider.id], cached.stamp == stamp {
                result[provider.id] = cached.names
                continue
            }
            let names = FontProviderManifests.installedFontFileNames(for: provider)
            manifestCache[provider.id] = (stamp, names)
            result[provider.id] = names
        }
        return result
    }

    func scan(_ input: FontScanInput) -> FontScanOutput {
        var nameCache = input.localizedNameCache
        var directoryDates: [String: TimeInterval] = [:]
        var filesByRoot: [URL: [URL]] = [:]
        var currentStamps: [URL: FontFileStamp] = [:]
        let manifestNames = providerManifestNames()

        for root in input.roots {
            // The enumerator reports a directory's contents, never the directory
            // itself; include the root so entries added directly in it are seen.
            let rootPath = root.standardizedFileURL.path
            if directoryDates[rootPath] == nil {
                directoryDates[rootPath] = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
            }

            var rawFiles: [URL] = []
            if let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey,
                    ])
                    if values?.isDirectory == true {
                        let path = url.standardizedFileURL.path
                        if directoryDates[path] == nil {
                            directoryDates[path] = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                        }
                        continue
                    }
                    guard values?.isRegularFile == true,
                          Self.fontExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    rawFiles.append(url)
                    currentStamps[url] = FontFileStamp(
                        modification: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        creation: values?.creationDate?.timeIntervalSince1970 ?? 0,
                        size: Int64(values?.fileSize ?? 0)
                    )
                }
            }
            filesByRoot[root] = rawFiles
        }

        var files = input.previousFiles
        var changed: [URL] = []
        var removed: [URL] = []
        let currentURLs = Set(currentStamps.keys)
        for url in files.keys where !currentURLs.contains(url) {
            removed.append(url)
        }
        for (url, stamp) in currentStamps {
            if let cached = files[url], cached.stamp == stamp { continue }
            changed.append(url)
        }
        changed.sort { $0.path < $1.path }
        removed.sort { $0.path < $1.path }

        // A changed or removed file invalidates its localized name mapping.
        for url in changed { nameCache.removeValue(forKey: url) }
        for url in removed {
            nameCache.removeValue(forKey: url)
            files.removeValue(forKey: url)
        }
        for url in changed {
            guard let stamp = currentStamps[url] else { continue }
            files[url] = parseFontFile(url, stamp: stamp, manifestNames: manifestNames, nameCache: &nameCache)
        }

        let installedChanged = input.previousInstalledSeeds != input.installedSeeds
        let rootsChanged = input.previousRoots != input.roots
        let hasChanges = installedChanged || rootsChanged || !changed.isEmpty || !removed.isEmpty

        // Installed metadata is reparsed when the installed set changes or when a file changed,
        // because a file's faces can also appear in the installed font list.
        let installedRecords: [FaceRecord]
        if installedChanged || !changed.isEmpty || !removed.isEmpty {
            installedRecords = input.installedSeeds.compactMap { seed in
                let descriptor = CTFontDescriptorCreateWithNameAndSize(seed.postScriptName as CFString, 0)
                return makeRecord(
                    descriptor: descriptor,
                    fallbackURL: nil,
                    fallbackFamily: seed.family,
                    fallbackStyle: seed.styleName,
                    fallbackWeight: seed.weight,
                    managed: false,
                    manifestNames: manifestNames,
                    nameCache: &nameCache
                )
            }
        } else {
            installedRecords = input.previousInstalledRecords
        }

        var folderRecords: [FaceRecord] = []
        for root in input.roots {
            for url in filesByRoot[root] ?? [] {
                if let cached = files[url] {
                    folderRecords.append(contentsOf: cached.records)
                }
            }
        }

        let folderTrees = input.roots
            .map { makeFolderTree(root: $0, fontFiles: filesByRoot[$0] ?? []) }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        return FontScanOutput(
            installedRecords: installedRecords,
            folderRecords: folderRecords,
            files: files,
            localizedNameCache: nameCache,
            changedFiles: changed,
            folderTrees: folderTrees,
            directoryFingerprint: Self.fingerprint(directoryDates),
            hasChanges: hasChanges
        )
    }

    /// A cheap directory-level fingerprint used to catch file system changes that
    /// FSEvents may have missed. Directory modification dates cover added, removed,
    /// renamed, and replaced entries anywhere in the tree, including each root
    /// itself. An in-place edit that touches no directory entry still relies on
    /// FSEvents.
    func directoryFingerprint(roots: [URL]) -> UInt64 {
        var directoryDates: [String: TimeInterval] = [:]
        for root in roots {
            // The enumerator reports a directory's contents, never the directory
            // itself; include the root so entries added directly in it are seen.
            let rootPath = root.standardizedFileURL.path
            if directoryDates[rootPath] == nil {
                directoryDates[rootPath] = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory == true else { continue }
                let path = url.standardizedFileURL.path
                guard directoryDates[path] == nil else { continue }
                directoryDates[path] = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            }
        }
        return Self.fingerprint(directoryDates)
    }

    private static func fingerprint(_ directoryDates: [String: TimeInterval]) -> UInt64 {
        var hasher = Hasher()
        for path in directoryDates.keys.sorted() {
            hasher.combine(path)
            hasher.combine(directoryDates[path] ?? 0)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    // MARK: - Parsing

    private func parseFontFile(
        _ url: URL,
        stamp: FontFileStamp,
        manifestNames: [String: Set<String>],
        nameCache: inout [URL: [String: FontNameTable.LocalizedFamily]]
    ) -> CachedFontFile {
        var names: Set<String> = []
        var records: [FaceRecord] = []
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
            for descriptor in descriptors {
                if let name = attribute(descriptor, key: kCTFontNameAttribute) {
                    names.insert(name)
                }
                if let record = makeRecord(
                    descriptor: descriptor,
                    fallbackURL: url,
                    managed: true,
                    manifestNames: manifestNames,
                    nameCache: &nameCache
                ) {
                    records.append(record)
                }
            }
        }
        return CachedFontFile(stamp: stamp, descriptorNames: names, records: records)
    }

    private func makeRecord(
        descriptor: CTFontDescriptor,
        fallbackURL: URL? = nil,
        fallbackFamily: String? = nil,
        fallbackStyle: String? = nil,
        fallbackWeight: Int = 5,
        managed: Bool,
        manifestNames: [String: Set<String>],
        nameCache: inout [URL: [String: FontNameTable.LocalizedFamily]]
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
        let source = fontSource(url: url, manufacturer: manufacturer, managed: managed, manifestNames: manifestNames)
        let languageCodes = CTFontDescriptorCopyAttribute(descriptor, kCTFontLanguagesAttribute) as? [String] ?? []
        let declaredLanguages = FontLanguage.detected(in: languageCodes)
        // Only fonts that declare a CJK language can carry localized family
        // names, so skip the name table for the rest. The design languages
        // decide what the font is for when the file records them; a Chinese
        // font with a Japanese alias name is told apart this way.
        let localization = declaredLanguages.isEmpty
            ? nil
            : localizedFamily(for: url, family: family, nameCache: &nameCache)
        let languages = localization.flatMap { $0.designLanguages.isEmpty ? nil : $0.designLanguages }
            ?? declaredLanguages
        let localizedNames = (localization?.names ?? [:]).filter { languages.contains($0.key) }
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let category = classify(family: family, style: style, symbolicTraits: symbolic)
        // Core Text normalizes weight to [-1, 1]; scale it so styles sort
        // light-to-heavy no matter where the face came from.
        let normalizedWeight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue
        let weight = normalizedWeight.map { Int(($0 * 1000).rounded()) } ?? fallbackWeight
        let face = FontFace(
            postScriptName: name,
            styleName: style,
            weight: weight,
            fileURL: url,
            isInstalled: false,
            isManaged: managed
        )
        return FaceRecord(
            family: family,
            localizedNames: localizedNames,
            manufacturer: manufacturer,
            source: source,
            category: category,
            languages: languages,
            face: face
        )
    }

    /// The localized family names and design languages the face's file carries
    /// for the requested family name.
    private func localizedFamily(
        for url: URL?,
        family: String,
        nameCache: inout [URL: [String: FontNameTable.LocalizedFamily]]
    ) -> FontNameTable.LocalizedFamily? {
        guard let url else { return nil }
        let mapping: [String: FontNameTable.LocalizedFamily]
        if let cached = nameCache[url] {
            mapping = cached
        } else {
            mapping = FontNameTable.localizedFamilies(inFontAt: url)
            nameCache[url] = mapping
        }
        return mapping[family.lowercased()]
    }

    private func attribute(_ descriptor: CTFontDescriptor, key: CFString) -> String? {
        CTFontDescriptorCopyAttribute(descriptor, key) as? String
    }

    private func fontSource(
        url: URL?,
        manufacturer: String,
        managed: Bool,
        manifestNames: [String: Set<String>]
    ) -> FontSource {
        if let provider = FontProviderRegistry.match(
            path: url?.path ?? "",
            manufacturer: manufacturer,
            manifestNames: manifestNames,
            fileName: url?.lastPathComponent
        ) {
            return .provider(provider)
        }
        return managed ? .local : .system
    }

    private func classify(family: String, style: String, symbolicTraits: UInt32) -> FontCategory {
        let searchable = "\(family) \(style)".lowercased()
        if symbolicTraits & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0 || searchable.contains("mono") {
            return .monospaced
        }
        if searchable.contains("serif") || searchable.contains("明朝") || searchable.contains("宋")
            || searchable.contains("myeongjo") || searchable.contains("batang") || searchable.contains("바탕") {
            return .serif
        }
        if searchable.contains("sans") || searchable.contains("gothic") || searchable.contains("ゴシック")
            || searchable.contains("黑") || searchable.contains("고딕") || searchable.contains("dotum")
            || searchable.contains("돋움") {
            return .sansSerif
        }
        if searchable.contains("display") || searchable.contains("script") || searchable.contains("decorative") {
            return .display
        }
        return .unclassified
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
}
