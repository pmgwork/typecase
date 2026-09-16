import CoreText
import Foundation

/// A font face parsed from a font file or from the installed font set.
///
/// The `installed` flag on the face is a placeholder: the catalog recomputes it
/// from the current activation state when records are applied.
nonisolated struct FaceRecord: Sendable {
    let family: String
    let japaneseName: String?
    let manufacturer: String
    let source: FontSource
    let category: FontCategory
    let supportsJapanese: Bool
    let face: FontFace

    func withInstalled(_ installed: Bool) -> FaceRecord {
        FaceRecord(
            family: family,
            japaneseName: japaneseName,
            manufacturer: manufacturer,
            source: source,
            category: category,
            supportsJapanese: supportsJapanese,
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
    let japaneseNameCache: [URL: [String: String]]
}

nonisolated struct FontScanOutput: Sendable {
    let installedRecords: [FaceRecord]
    let folderRecords: [FaceRecord]
    let files: [URL: CachedFontFile]
    let japaneseNameCache: [URL: [String: String]]
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

    func scan(_ input: FontScanInput) -> FontScanOutput {
        var nameCache = input.japaneseNameCache
        var directoryDates: [String: TimeInterval] = [:]
        var filesByRoot: [URL: [URL]] = [:]
        var currentStamps: [URL: FontFileStamp] = [:]

        for root in input.roots {
            var rawFiles: [URL] = []
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                filesByRoot[root] = []
                continue
            }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
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
                    size: Int64(values?.fileSize ?? 0)
                )
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

        // A changed or removed file invalidates its Japanese name mapping.
        for url in changed { nameCache.removeValue(forKey: url) }
        for url in removed {
            nameCache.removeValue(forKey: url)
            files.removeValue(forKey: url)
        }
        for url in changed {
            guard let stamp = currentStamps[url] else { continue }
            files[url] = parseFontFile(url, stamp: stamp, nameCache: &nameCache)
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
            japaneseNameCache: nameCache,
            changedFiles: changed,
            folderTrees: folderTrees,
            directoryFingerprint: Self.fingerprint(directoryDates),
            hasChanges: hasChanges
        )
    }

    /// A cheap directory-level fingerprint used to catch file system changes that
    /// FSEvents may have missed. Directory modification dates cover added, removed,
    /// renamed, and replaced entries anywhere in the tree.
    func directoryFingerprint(roots: [URL]) -> UInt64 {
        var directoryDates: [String: TimeInterval] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let path = url.standardizedFileURL.path
                guard directoryDates[path] == nil else { continue }
                directoryDates[path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
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
        nameCache: inout [URL: [String: String]]
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
        nameCache: inout [URL: [String: String]]
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
        let japaneseName = supportsJapanese
            ? japaneseFamilyName(for: url, family: family, nameCache: &nameCache)
            : nil
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let category = classify(family: family, style: style, symbolicTraits: symbolic)
        let face = FontFace(
            postScriptName: name,
            styleName: style,
            weight: fallbackWeight,
            fileURL: url,
            isInstalled: false,
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

    private func japaneseFamilyName(
        for url: URL?,
        family: String,
        nameCache: inout [URL: [String: String]]
    ) -> String? {
        guard let url else { return nil }
        let mapping: [String: String]
        if let cached = nameCache[url] {
            mapping = cached
        } else {
            mapping = FontNameTable.japaneseFamilies(inFontAt: url)
            nameCache[url] = mapping
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
