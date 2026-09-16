import Combine
import Foundation

/// App-wide preferences, persisted in `UserDefaults`, shared by every window
/// and the Settings scene.
@MainActor
final class AppSettings: ObservableObject {
    static let japaneseSampleDefault = "美しい文字は、言葉の表情を豊かにする。"
    static let latinSampleDefault = "Typography gives every word a distinct voice."
    static let previewSizeRange: ClosedRange<Double> = 18...72

    @Published var previewSize: Double {
        didSet { defaults.set(previewSize, forKey: Key.previewSize) }
    }
    @Published var japaneseSampleText: String {
        didSet { defaults.set(japaneseSampleText, forKey: Key.japaneseSample) }
    }
    @Published var latinSampleText: String {
        didSet { defaults.set(latinSampleText, forKey: Key.latinSample) }
    }
    @Published var favoritesFirst: Bool {
        didSet { defaults.set(favoritesFirst, forKey: Key.favoritesFirst) }
    }
    @Published var startHidden: Bool {
        didSet { defaults.set(startHidden, forKey: Key.startHidden) }
    }
    @Published var showAllSection: Bool {
        didSet { defaults.set(showAllSection, forKey: Key.showAllSection) }
    }
    @Published var showFavoritesSection: Bool {
        didSet { defaults.set(showFavoritesSection, forKey: Key.showFavoritesSection) }
    }
    @Published var showSystemSection: Bool {
        didSet { defaults.set(showSystemSection, forKey: Key.showSystemSection) }
    }
    @Published var showLocalSection: Bool {
        didSet { defaults.set(showLocalSection, forKey: Key.showLocalSection) }
    }
    @Published var showAdobeSection: Bool {
        didSet { defaults.set(showAdobeSection, forKey: Key.showAdobeSection) }
    }
    @Published var showMorisawaSection: Bool {
        didSet { defaults.set(showMorisawaSection, forKey: Key.showMorisawaSection) }
    }
    @Published var showTagsSection: Bool {
        didSet { defaults.set(showTagsSection, forKey: Key.showTagsSection) }
    }

    /// The last non-folder sidebar destination, and the last selection. Kept
    /// here so the startup restore can read them before a window opens.
    @Published private(set) var lastSelection: [String]
    @Published private(set) var lastLocation: String

    private let defaults = UserDefaults.standard

    init() {
        let storedSize = defaults.object(forKey: Key.previewSize) as? Double ?? 32
        previewSize = min(max(storedSize, Self.previewSizeRange.lowerBound), Self.previewSizeRange.upperBound)
        japaneseSampleText = defaults.string(forKey: Key.japaneseSample) ?? ""
        latinSampleText = defaults.string(forKey: Key.latinSample) ?? ""
        favoritesFirst = defaults.object(forKey: Key.favoritesFirst) as? Bool ?? false
        startHidden = defaults.object(forKey: Key.startHidden) as? Bool ?? false
        showAllSection = defaults.object(forKey: Key.showAllSection) as? Bool ?? true
        showFavoritesSection = defaults.object(forKey: Key.showFavoritesSection) as? Bool ?? true
        showSystemSection = defaults.object(forKey: Key.showSystemSection) as? Bool ?? true
        showLocalSection = defaults.object(forKey: Key.showLocalSection) as? Bool ?? true
        showAdobeSection = defaults.object(forKey: Key.showAdobeSection) as? Bool ?? true
        showMorisawaSection = defaults.object(forKey: Key.showMorisawaSection) as? Bool ?? true
        showTagsSection = defaults.object(forKey: Key.showTagsSection) as? Bool ?? true
        lastSelection = defaults.stringArray(forKey: Key.lastSelection) ?? []
        lastLocation = defaults.string(forKey: Key.lastLocation) ?? ""
    }

    // MARK: - Preview

    var japaneseSample: String {
        japaneseSampleText.isEmpty ? Self.japaneseSampleDefault : japaneseSampleText
    }

    var latinSample: String {
        latinSampleText.isEmpty ? Self.latinSampleDefault : latinSampleText
    }

    /// The text a preview shows: the entered text, or the language sample.
    func effectivePreviewText(for family: FontFamily, entered: String) -> String {
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return entered }
        return family.supportsJapanese ? japaneseSample : latinSample
    }

    func resetSampleText() {
        japaneseSampleText = ""
        latinSampleText = ""
    }

    // MARK: - Sidebar visibility

    /// The sidebar destinations the visibility settings leave visible, in
    /// sidebar order.
    var visibleSidebarSections: [LibrarySection] {
        var sections: [LibrarySection] = []
        if showAllSection { sections.append(.all) }
        if showFavoritesSection { sections.append(.favorites) }
        if showSystemSection { sections.append(.system) }
        if showLocalSection { sections.append(.local) }
        if showAdobeSection { sections.append(.adobe) }
        if showMorisawaSection { sections.append(.morisawa) }
        return sections
    }

    func isSidebarItemVisible(_ selection: LibrarySelection) -> Bool {
        switch selection {
        case .section(.all): showAllSection
        case .section(.favorites): showFavoritesSection
        case .section(.system), .systemScope: showSystemSection
        case .section(.local): showLocalSection
        case .section(.adobe): showAdobeSection
        case .section(.morisawa): showMorisawaSection
        case .folder: true
        }
    }

    // MARK: - Startup state

    func remember(selection: Set<FontFamily.ID>) {
        let sorted = selection.sorted()
        guard sorted != lastSelection else { return }
        lastSelection = sorted
        defaults.set(sorted, forKey: Key.lastSelection)
    }

    func remember(location: LibrarySelection) {
        let encoded: String?
        switch location {
        case .section(let section): encoded = "section:\(section.rawValue)"
        case .systemScope(let scope): encoded = "scope:\(scope.rawValue)"
        case .folder: encoded = nil
        }
        guard let encoded, encoded != lastLocation else { return }
        lastLocation = encoded
        defaults.set(encoded, forKey: Key.lastLocation)
    }

    var lastLibrarySelection: LibrarySelection? {
        let parts = lastLocation.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "section": return LibrarySection(rawValue: parts[1]).map(LibrarySelection.section)
        case "scope": return SystemFontScope(rawValue: parts[1]).map(LibrarySelection.systemScope)
        default: return nil
        }
    }

    private enum Key {
        static let previewSize = "previewSize"
        static let japaneseSample = "japaneseSampleText"
        static let latinSample = "latinSampleText"
        static let favoritesFirst = "favoritesFirst"
        static let startHidden = "startHidden"
        static let showAllSection = "showAllSection"
        static let showFavoritesSection = "showFavoritesSection"
        static let showSystemSection = "showSystemSection"
        static let showLocalSection = "showLocalSection"
        static let showAdobeSection = "showAdobeSection"
        static let showMorisawaSection = "showMorisawaSection"
        static let showTagsSection = "showTagsSection"
        static let lastSelection = "lastSelection"
        static let lastLocation = "lastLocation"
    }
}
