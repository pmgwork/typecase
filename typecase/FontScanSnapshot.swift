import Foundation

/// The results of the last scan, kept on disk so a launch with no font changes
/// shows the library without reparsing every installed face and font file.
///
/// The snapshot is only a cache: the launch scan still checks every file's
/// stamp and the installed font list against it, and anything that differs is
/// parsed again.
nonisolated struct FontScanSnapshot: Codable, Sendable {
    /// Bump when the parsed records change shape or meaning, so snapshots
    /// written by an older build are discarded instead of misread.
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var appBuild = Self.appBuild
    let roots: [URL]
    let manifestNames: [String: Set<String>]
    let installedSeeds: [InstalledFaceSeed]
    let installedRecords: [FaceRecord]
    let folderRecords: [FaceRecord]
    let files: [URL: CachedFontFile]
    let localizedNameCache: [URL: [String: FontNameTable.LocalizedFamily]]
    let folderTrees: [FontFolderNode]

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private static var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "TypeCase", isDirectory: true)
        return folder.appendingPathComponent("FontScanSnapshot.plist")
    }

    /// The saved snapshot, or nil when there is none or it was written by a
    /// build that parses fonts differently.
    static func load() -> FontScanSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let snapshot = try? PropertyListDecoder().decode(FontScanSnapshot.self, from: data),
              snapshot.formatVersion == currentFormatVersion,
              snapshot.appBuild == appBuild else { return nil }
        return snapshot
    }

    fileprivate func write() {
        guard let url = Self.fileURL else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// Writes snapshots off the main actor, one at a time. A snapshot that was
/// requested before the last one written is skipped, so a slow write never
/// replaces newer results.
actor FontScanSnapshotStore {
    private var lastWritten = 0

    func save(_ snapshot: FontScanSnapshot, sequence: Int) {
        guard sequence > lastWritten else { return }
        lastWritten = sequence
        snapshot.write()
    }
}
