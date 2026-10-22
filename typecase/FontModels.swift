import Darwin
import Foundation

/// Where a font family comes from: the Mac itself, an added folder, or a
/// subscription service that manages its own fonts.
nonisolated struct FontSource: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: String

    static let system = FontSource(rawValue: "system")
    static let local = FontSource(rawValue: "local")

    static func provider(_ provider: FontProvider) -> FontSource {
        FontSource(rawValue: provider.id)
    }

    var id: String { rawValue }

    /// The service this source represents, or nil for System and Local.
    var provider: FontProvider? {
        FontProviderRegistry.provider(withID: rawValue)
    }

    var title: String {
        if let provider { return provider.title }
        return self == .local ? String(localized: "Local") : String(localized: "System")
    }

    var shortTitle: String {
        if let provider { return provider.shortTitle }
        return self == .local ? String(localized: "Local") : "OS"
    }

    var managementHint: String {
        if let provider { return provider.managementHint }
        return self == .local
            ? String(localized: "Added folder — use the radio button to activate or deactivate")
            : String(localized: "Installed on this Mac — deactivate it in Font Book")
    }
}

nonisolated struct FontFace: Identifiable, Hashable, Codable, Sendable {
    let postScriptName: String
    let styleName: String
    /// Core Text weight scaled to an integer so style lists sort light to heavy.
    let weight: Int
    let fileURL: URL?
    let isInstalled: Bool
    let isManaged: Bool

    var id: String { postScriptName }
}

/// An explicit activation state for one font file. Core Text registers font
/// files as a unit, so activation is applied and undone per file.
nonisolated struct FontActivationState: Sendable, Hashable {
    let url: URL
    let names: Set<String>
    let enabled: Bool
}

/// One axis of a variable font with the range Core Text reports.
nonisolated struct VariableFontAxis: Identifiable, Hashable, Sendable {
    /// The four-character axis tag, such as `wght`.
    let tag: UInt32
    let name: String
    let minimum: Double
    let maximum: Double
    let defaultValue: Double

    var id: UInt32 { tag }
    var tagString: String { VariationTag.string(from: tag) }
}

/// A variable font's axes and the coordinates of the instance in use.
nonisolated struct VariableFontInfo: Sendable {
    let axes: [VariableFontAxis]
    let currentValues: [UInt32: Double]
}

/// Converts between Core Text's four-character axis tags and the strings used
/// to persist them.
nonisolated enum VariationTag {
    static func string(from tag: UInt32) -> String {
        let bytes = [
            UInt8((tag >> 24) & 0xFF), UInt8((tag >> 16) & 0xFF),
            UInt8((tag >> 8) & 0xFF), UInt8(tag & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(tag)
    }

    static func tag(from string: String) -> UInt32? {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | $1.value }
    }
}

nonisolated struct FontFamily: Identifiable, Hashable, Sendable {
    let id: String
    /// The English family name Core Text reports, shown as the secondary name.
    let localizedName: String
    /// The CJK languages the family's faces declare. Latin-only fonts have an
    /// empty set.
    let languages: Set<FontLanguage>
    /// The localized family names found in the faces' name tables, limited to
    /// the languages the faces declare.
    let localizedNames: [FontLanguage: String]
    let manufacturer: String
    let source: FontSource
    /// Automatically detected from the font's metadata, names, and outlines.
    let category: FontCategory
    let faces: [FontFace]

    /// The display name: the family's name in its highest-priority language,
    /// or the English name when the file carries no localized name.
    var name: String {
        localizedNames[previewLanguage] ?? localizedName
    }

    /// The language whose sample text and display name the family uses. A
    /// localized name is the strongest signal of the script a family targets;
    /// the declared languages decide when no localized name exists.
    var previewLanguage: FontLanguage {
        FontLanguage.previewPriority.first { localizedNames[$0] != nil }
            ?? FontLanguage.previewPriority.first { languages.contains($0) }
            ?? .latin
    }

    /// The languages listed in the inspector, in preview priority order.
    var languageDescription: String {
        let named = FontLanguage.previewPriority.filter { localizedNames[$0] != nil }
        let described = named.isEmpty
            ? FontLanguage.previewPriority.filter { languages.contains($0) }
            : named
        guard !described.isEmpty else { return FontLanguage.latin.title }
        return described.map(\.title).joined(separator: ", ")
    }

    var isEnabled: Bool { faces.contains(where: \.isInstalled) }
    var isPartiallyEnabled: Bool {
        let count = faces.filter(\.isInstalled).count
        return count > 0 && count < faces.count
    }
    var isManaged: Bool { faces.contains(where: \.isManaged) }
    /// Whether the row's activation menu can enable every managed style.
    var canActivate: Bool { isManaged && (!isEnabled || isPartiallyEnabled) }
    /// Whether the row's activation menu can disable the managed styles.
    var canDeactivate: Bool { isManaged && isEnabled }
    /// The files the family's faces come from, in face order and without
    /// repeats, so Finder and path actions name each file once.
    var fileURLs: [URL] {
        var seen: Set<URL> = []
        return faces.compactMap(\.fileURL).filter { seen.insert($0.standardizedFileURL).inserted }
    }
    var previewFace: FontFace? {
        faces.first(where: { $0.styleName.localizedCaseInsensitiveContains("regular") }) ?? faces.first
    }
    /// Fallback for a mixed pair when its preferred script-specific style is
    /// missing: Regular, or the face whose weight is closest to 400.
    var defaultMixedFace: FontFace? {
        if let regular = faces.first(where: { $0.styleName.localizedCaseInsensitiveContains("regular") }) {
            return regular
        }
        return faces.min { abs($0.weight - 400) < abs($1.weight - 400) }
    }

    /// The starting style for a part of a new mixed pair. Japanese uses W5;
    /// English, numbers, and symbols use Medium when those styles are present.
    func defaultMixedFace(for script: MixedScript) -> FontFace? {
        let preferredStyle = script == .japanese ? "W5" : "Medium"
        return faces.first {
            $0.styleName.localizedCaseInsensitiveCompare(preferredStyle) == .orderedSame
        } ?? defaultMixedFace
    }
}

/// One file that provides a face whose PostScript name another file also uses.
nonisolated struct FontFileCopy: Identifiable, Hashable, Sendable {
    let url: URL
    let source: FontSource
    /// Whether this is the file Core Text resolved the name to at the last
    /// scan, i.e. the copy applications get when they ask for the name.
    let isInUse: Bool

    var id: URL { url }
}

/// A face whose PostScript name is provided by more than one font file. Apps
/// address fonts by that name, so only one of the copies can be used.
nonisolated struct FontDuplicate: Identifiable, Hashable, Sendable {
    let postScriptName: String
    let styleName: String
    /// The copies in a stable order: the one in use first, then by path.
    let copies: [FontFileCopy]

    var id: String { postScriptName }
}

nonisolated struct FontFolderNode: Identifiable, Hashable, Codable, Sendable {
    let url: URL
    let children: [FontFolderNode]?

    var id: URL { url }
}

/// A sidebar destination for a source of fonts. Provider sections come from
/// `FontProviderRegistry`, so the raw value is a provider id ("adobe"), which
/// keeps persisted selections stable.
nonisolated struct LibrarySection: Hashable, Identifiable, Sendable {
    let rawValue: String

    static let all = LibrarySection(rawValue: "all")
    static let favorites = LibrarySection(rawValue: "favorites")
    static let system = LibrarySection(rawValue: "system")
    static let local = LibrarySection(rawValue: "local")
    /// The saved Japanese + Latin combinations.
    static let mixed = LibrarySection(rawValue: "mixed")
    /// Families with a face that more than one font file provides.
    static let duplicates = LibrarySection(rawValue: "duplicates")

    static func provider(_ provider: FontProvider) -> LibrarySection {
        LibrarySection(rawValue: provider.id)
    }

    var id: String { rawValue }

    var provider: FontProvider? { FontProviderRegistry.provider(withID: rawValue) }

    /// Whether this raw value names a section this build can show. A persisted
    /// selection from an older or newer build must not become a blank row.
    var isKnown: Bool {
        provider != nil || [.all, .favorites, .system, .local, .mixed, .duplicates].contains(self)
    }

    var title: String {
        if let provider { return provider.title }
        switch self {
        case .all: return String(localized: "All Fonts")
        case .favorites: return String(localized: "Favorites")
        case .system: return String(localized: "System Fonts")
        case .local: return String(localized: "Local Library")
        case .mixed: return String(localized: "Mixed Fonts")
        case .duplicates: return String(localized: "Duplicates")
        default: return rawValue
        }
    }

    var icon: SourceIcon {
        if let provider { return provider.icon }
        switch self {
        case .all: return .symbol("textformat")
        case .favorites: return .symbol("star")
        case .system: return .symbol("macbook")
        case .local: return .symbol("folder")
        case .mixed: return .symbol("rectangle.on.rectangle")
        case .duplicates: return .symbol("square.on.square")
        default: return .symbol("textformat")
        }
    }
}

enum SystemFontScope: String, CaseIterable, Hashable {
    case user
    case allUsers
    case system

    /// The account's home directory. A sandboxed build reports its container here
    /// ("…/Library/Containers/<bundle>/Data"), which would label the user scope
    /// "Data" and file the fonts under the real ~/Library as System; the passwd
    /// database still reports the home directory outside the container.
    static let homeDirectory: URL = {
        guard let passwd = getpwuid(getuid()), let directory = passwd.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }()

    var title: String {
        switch self {
        case .user: Self.homeDirectory.lastPathComponent
        case .allUsers: String(localized: "All Users")
        case .system: String(localized: "System")
        }
    }

    var icon: SourceIcon {
        switch self {
        case .user: .symbol("person.crop.circle")
        case .allUsers: .symbol("person.2")
        case .system: .symbol("macbook")
        }
    }
}

enum LibrarySelection: Hashable {
    case section(LibrarySection)
    case systemScope(SystemFontScope)
    case folder(URL)
    case tag(String)

    var icon: SourceIcon {
        switch self {
        case .section(let section): section.icon
        case .systemScope(let scope): scope.icon
        case .folder: .symbol("folder")
        case .tag: .symbol("tag")
        }
    }
}

enum ActivationFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case disabled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .enabled: String(localized: "Enabled")
        case .disabled: String(localized: "Disabled")
        }
    }
}

nonisolated extension URL {
    func isContained(in directory: URL) -> Bool {
        let fileComponents = standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let directoryComponents = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= directoryComponents.count else { return false }
        return zip(fileComponents, directoryComponents).allSatisfy(==)
    }
}
