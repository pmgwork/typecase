import Foundation

/// A font service whose fonts TypeCase can identify but not activate.
///
/// Providers are recognized from the path and the manufacturer of each font
/// file, and from the manifests the service's own app writes. Their titles,
/// sidebar sections, row labels, and empty states all derive from this table,
/// so a new service is one entry in `FontProviderRegistry`.
nonisolated struct FontProvider: Identifiable, Hashable, Sendable {
    /// Stable identifier. Provider sections persist this value in the sidebar
    /// selection, so it must not change once shipped.
    let id: String
    let title: String
    /// The short label shown at the end of a list row.
    let shortTitle: String
    /// A neutral symbol shared by services; brand artwork is not bundled.
    let icon: SourceIcon
    /// Shown for fonts only the provider's own app can activate.
    let managementHint: String
    /// The empty-state description for this provider's sidebar section.
    let emptyMessage: String
    /// Case-insensitive fragments matched against a font file's path.
    let pathMatchers: [String]
    /// Case-insensitive fragments matched against the font's manufacturer
    /// name, for services whose fonts do not live in a recognizable folder.
    /// Leave empty when a match could include fonts the user owns outright.
    let manufacturerMatchers: [String]
    /// Plists in which the provider's app lists the fonts it installed. This
    /// identifies fonts the app copies into a standard font folder, where the
    /// path carries no trace of the service.
    let manifestURLs: [URL]
    /// Providers are listed in this order in the sidebar, and applied in this
    /// order when a family's faces come from more than one service.
    let order: Int

    func matches(path: String, manufacturer: String) -> Bool {
        let path = path.lowercased()
        let manufacturer = manufacturer.lowercased()
        return pathMatchers.contains(where: path.contains)
            || manufacturerMatchers.contains(where: manufacturer.contains)
    }

    /// Whether a font file is one the provider's app recorded as installed.
    func matchesManifest(fileName: String?, names: Set<String>) -> Bool {
        guard !names.isEmpty, let fileName else { return false }
        return names.contains(fileName.lowercased())
    }
}

/// Known font services, in sidebar order. Provider ids stay stable even when
/// their display names change, preserving saved navigation and preferences.
nonisolated enum FontProviderRegistry {
    static let adobe = FontProvider(
        id: "adobe",
        title: "Adobe Fonts",
        shortTitle: "Adobe",
        icon: .symbol("cloud"),
        managementHint: String(localized: "Activate or deactivate in Adobe Creative Cloud"),
        emptyMessage: String(localized: "Fonts activated in Adobe Creative Cloud appear here."),
        pathMatchers: ["/adobe/coresync/", "/coresync/plugins/livetype/"],
        manufacturerMatchers: [],
        manifestURLs: [],
        order: 0
    )

    static let morisawa = FontProvider(
        id: "morisawa",
        title: "Morisawa Fonts",
        shortTitle: "Morisawa",
        icon: .symbol("cloud"),
        managementHint: String(localized: "Activate or deactivate in Morisawa Desktop Manager"),
        emptyMessage: String(localized: "Fonts activated in Morisawa Desktop Manager appear here."),
        pathMatchers: ["/library/fonts/morisawafonts/"],
        manufacturerMatchers: [],
        manifestURLs: [],
        order: 1
    )

    /// Fontworks / Monotype LETS. The desktop app installs activated fonts
    /// directly into `~/Library/Fonts`, so the path never names the service;
    /// the app's own plists list the installed file names instead. Path
    /// matchers stay as a fallback for folders that do carry the service name.
    /// No manufacturer rule: owned Fontworks fonts must stay Local or System.
    static let fontworks = FontProvider(
        id: "fontworks",
        title: "LETS",
        shortTitle: "LETS",
        icon: .symbol("cloud"),
        managementHint: String(localized: "Activate or deactivate in the LETS desktop app"),
        emptyMessage: String(localized: "Fonts activated in the LETS desktop app appear here."),
        pathMatchers: ["/fontworks/", "/lets/"],
        manufacturerMatchers: [],
        manifestURLs: [
            homeURL.appending(path: "Library/Application Support/Fontworks/LETS/LETS.font.plist"),
            homeURL.appending(path: "Library/Application Support/Fontworks/LETS/LETS-device.target.plist"),
            URL(fileURLWithPath: "/Library/Application Support/Fontworks/LETS/LETS.font.plist"),
            URL(fileURLWithPath: "/Library/Application Support/Fontworks/LETS/LETS-device.target.plist"),
            URL(fileURLWithPath: "/Library/Application Support/Fontworks/LETS/LETS-device/LETS-device.target.plist"),
        ],
        order: 2
    )

    static let monotype = FontProvider(
        id: "monotype",
        title: "Monotype Fonts",
        shortTitle: "Monotype",
        icon: .symbol("cloud"),
        managementHint: String(localized: "Activate or deactivate in Monotype Desktop App"),
        emptyMessage: String(localized: "Fonts synced in Monotype Desktop App appear here."),
        // Monotype Desktop App 7.8.1's font service uses a per-user hidden
        // .monotypefonts-* cache under the temporary directory.
        pathMatchers: ["/.monotypefonts-"],
        // A manufacturer's name does not identify the subscription a font
        // came from. Owned and macOS-bundled Monotype faces remain unchanged.
        manufacturerMatchers: [],
        manifestURLs: [],
        order: 3
    )

    static let all: [FontProvider] = [adobe, morisawa, fontworks, monotype]

    private static let homeURL = FileManager.default.homeDirectoryForCurrentUser

    static func provider(withID id: String) -> FontProvider? {
        all.first { $0.id == id }
    }

    /// The provider that owns a font file, or nil for fonts TypeCase manages
    /// itself or that belong to macOS. Providers are tested in sidebar order.
    static func match(
        path: String,
        manufacturer: String,
        manifestNames: [String: Set<String>] = [:],
        fileName: String? = nil
    ) -> FontProvider? {
        all.first { provider in
            provider.matches(path: path, manufacturer: manufacturer)
                || provider.matchesManifest(fileName: fileName, names: manifestNames[provider.id] ?? [])
        }
    }
}

/// Reads the font file names a provider's app records in its manifest plists.
nonisolated enum FontProviderManifests {
    private static let fontExtensions = [".otf", ".ttf", ".ttc", ".dfont"]

    /// The lowercased font file names the provider lists across its manifests.
    static func installedFontFileNames(for provider: FontProvider) -> Set<String> {
        var names: Set<String> = []
        for url in provider.manifestURLs {
            names.formUnion(fontFileNames(inPlistAt: url))
        }
        return names
    }

    /// The lowercased font file names listed in one plist. A string qualifies
    /// when it carries a font extension or sits under a file-name key, so
    /// unrelated values in the same file never match a font.
    static func fontFileNames(inPlistAt url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [] }
        var names: Set<String> = []
        collect(from: plist, key: nil, into: &names)
        return names
    }

    private static func collect(from value: Any, key: String?, into names: inout Set<String>) {
        switch value {
        case let string as String:
            let candidate = string.lowercased()
            guard key == "filename" || fontExtensions.contains(where: candidate.hasSuffix) else { break }
            names.insert(candidate)
            names.insert((candidate as NSString).lastPathComponent)
        case let array as [Any]:
            for item in array { collect(from: item, key: key, into: &names) }
        case let dictionary as [String: Any]:
            for (key, item) in dictionary { collect(from: item, key: key.lowercased(), into: &names) }
        default:
            break
        }
    }
}
