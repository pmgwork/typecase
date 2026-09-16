import Foundation

nonisolated enum FontSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case local
    case adobe
    case morisawa

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .local: "Local"
        case .adobe: "Adobe Fonts"
        case .morisawa: "Morisawa Fonts"
        }
    }

    var shortTitle: String {
        switch self {
        case .system: "OS"
        case .local: "Local"
        case .adobe: "Adobe"
        case .morisawa: "Morisawa"
        }
    }

    var managementHint: String {
        switch self {
        case .system: "Installed on this Mac — deactivate it in Font Book"
        case .local: "Added folder — use the radio button to activate or deactivate"
        case .adobe: "Activate or deactivate in Adobe Creative Cloud"
        case .morisawa: "Activate or deactivate in Morisawa Desktop Manager"
        }
    }
}

nonisolated enum FontCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sansSerif
    case serif
    case monospaced
    case display
    case unclassified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sansSerif: "Sans Serif"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        case .display: "Display"
        case .unclassified: "Unclassified"
        }
    }
}

nonisolated struct FontFace: Identifiable, Hashable, Sendable {
    let postScriptName: String
    let styleName: String
    let weight: Int
    let fileURL: URL?
    let isInstalled: Bool
    let isManaged: Bool

    var id: String { postScriptName }
}

nonisolated struct FontFamily: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let localizedName: String
    let manufacturer: String
    let source: FontSource
    let category: FontCategory
    let supportsJapanese: Bool
    let faces: [FontFace]

    var isEnabled: Bool { faces.contains(where: \.isInstalled) }
    var isPartiallyEnabled: Bool {
        let count = faces.filter(\.isInstalled).count
        return count > 0 && count < faces.count
    }
    var isManaged: Bool { faces.contains(where: \.isManaged) }
    var previewFace: FontFace? {
        faces.first(where: { $0.styleName.localizedCaseInsensitiveContains("regular") }) ?? faces.first
    }
}

nonisolated struct FontFolderNode: Identifiable, Hashable, Sendable {
    let url: URL
    let children: [FontFolderNode]?

    var id: URL { url }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case all
    case favorites
    case system
    case local
    case adobe
    case morisawa

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Fonts"
        case .favorites: "Favorites"
        case .system: "System Fonts"
        case .local: "Local Library"
        case .adobe: "Adobe Fonts"
        case .morisawa: "Morisawa Fonts"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "textformat"
        case .favorites: "star"
        case .system: "desktopcomputer"
        case .local: "folder"
        case .adobe: "cloud"
        case .morisawa: "character.book.closed"
        }
    }
}

enum SystemFontScope: String, CaseIterable, Hashable {
    case user
    case allUsers
    case system

    var title: String {
        switch self {
        case .user: FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        case .allUsers: "All Users"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .user: "person.crop.circle"
        case .allUsers: "person.2"
        case .system: "desktopcomputer"
        }
    }
}

enum LibrarySelection: Hashable {
    case section(LibrarySection)
    case systemScope(SystemFontScope)
    case folder(URL)

    var systemImage: String {
        switch self {
        case .section(let section): section.systemImage
        case .systemScope(let scope): scope.systemImage
        case .folder: "folder"
        }
    }
}

enum ActivationFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case disabled

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated extension URL {
    func isContained(in directory: URL) -> Bool {
        let fileComponents = standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let directoryComponents = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= directoryComponents.count else { return false }
        return zip(fileComponents, directoryComponents).allSatisfy(==)
    }
}
