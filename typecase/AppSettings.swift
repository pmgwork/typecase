import AppKit
import Combine
import Foundation
import SwiftUI

/// App-wide preferences, persisted in `UserDefaults`, shared by every window
/// and the Settings scene.
@MainActor
final class AppSettings: ObservableObject {
    static let previewSizeRange: ClosedRange<Double> = 18...72

    @Published var previewSize: Double {
        didSet { defaults.set(previewSize, forKey: Key.previewSize) }
    }
    /// The preview sample text per language. A missing entry means the
    /// language's built-in default.
    @Published private(set) var sampleTexts: [FontLanguage: String] {
        didSet { storeSampleTexts() }
    }
    /// The colors of the font specimens, chosen from the toolbar. `nil` follows
    /// the system appearance; a chosen color stays fixed across appearances.
    @Published var previewBackgroundColor: Color? {
        didSet { store(previewBackgroundColor, forKey: Key.previewBackgroundColor) }
    }
    @Published var previewTextColor: Color? {
        didSet { store(previewTextColor, forKey: Key.previewTextColor) }
    }
    @Published var favoritesFirst: Bool {
        didSet { defaults.set(favoritesFirst, forKey: Key.favoritesFirst) }
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
    /// Provider sidebar visibility, keyed by `FontProvider.id`.
    @Published private(set) var providerSections: [String: Bool] {
        didSet { defaults.set(providerSections, forKey: Key.providerSections) }
    }
    @Published var showTagsSection: Bool {
        didSet { defaults.set(showTagsSection, forKey: Key.showTagsSection) }
    }
    @Published var showMixedSection: Bool {
        didSet { defaults.set(showMixedSection, forKey: Key.showMixedSection) }
    }
    @Published var showDuplicatesSection: Bool {
        didSet { defaults.set(showDuplicatesSection, forKey: Key.showDuplicatesSection) }
    }
    /// Per-face variable-axis adjustments, keyed by PostScript name and the
    /// four-character axis tag.
    @Published private(set) var variableAxes: [String: [String: Double]] {
        didSet { defaults.set(variableAxes, forKey: Key.variableAxes) }
    }

    /// The last non-folder sidebar destination, and the last selection. Kept
    /// here so the startup restore can read them before a window opens.
    // Persistence-only state: publishing it invalidates every font preview on
    // each row click, even though no view displays these stored values.
    private(set) var lastSelection: [String]
    private(set) var lastLocation: String

    private let defaults = UserDefaults.standard

    init() {
        let storedSize = defaults.object(forKey: Key.previewSize) as? Double ?? 32
        previewSize = min(max(storedSize, Self.previewSizeRange.lowerBound), Self.previewSizeRange.upperBound)
        sampleTexts = Self.loadSampleTexts(defaults: defaults)
        previewBackgroundColor = defaults.string(forKey: Key.previewBackgroundColor)
            .flatMap(Color.init(specimenHex:))
        previewTextColor = defaults.string(forKey: Key.previewTextColor)
            .flatMap(Color.init(specimenHex:))
        favoritesFirst = defaults.object(forKey: Key.favoritesFirst) as? Bool ?? false
        showAllSection = defaults.object(forKey: Key.showAllSection) as? Bool ?? true
        showFavoritesSection = defaults.object(forKey: Key.showFavoritesSection) as? Bool ?? true
        showSystemSection = defaults.object(forKey: Key.showSystemSection) as? Bool ?? true
        showLocalSection = defaults.object(forKey: Key.showLocalSection) as? Bool ?? true
        providerSections = Self.loadProviderSections(defaults: defaults)
        showTagsSection = defaults.object(forKey: Key.showTagsSection) as? Bool ?? true
        showMixedSection = defaults.object(forKey: Key.showMixedSection) as? Bool ?? true
        showDuplicatesSection = defaults.object(forKey: Key.showDuplicatesSection) as? Bool ?? true
        variableAxes = (defaults.dictionary(forKey: Key.variableAxes) as? [String: [String: Double]]) ?? [:]
        lastSelection = defaults.stringArray(forKey: Key.lastSelection) ?? []
        lastLocation = defaults.string(forKey: Key.lastLocation) ?? ""
    }

    // MARK: - Preview

    /// The sample text stored for a language; empty when the default is used.
    func sampleText(for language: FontLanguage) -> String {
        sampleTexts[language] ?? ""
    }

    /// Stores a language's sample text; an empty string restores the default.
    func setSampleText(_ text: String, for language: FontLanguage) {
        if text.isEmpty {
            sampleTexts.removeValue(forKey: language)
        } else {
            sampleTexts[language] = text
        }
    }

    /// The sample text a preview shows for a language: the stored text or its
    /// built-in default.
    func sample(for language: FontLanguage) -> String {
        sampleTexts[language] ?? language.sampleDefault
    }

    /// The text a preview shows: the entered text, or the language sample.
    func effectivePreviewText(for family: FontFamily, entered: String) -> String {
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return entered }
        return sample(for: family.previewLanguage)
    }

    /// The built-in mixed specimen, shown while the preview text field is
    /// empty. It mixes Japanese, English, digits, and symbols so each part's
    /// width and balance can be compared.
    static let mixedSampleDefault = "Typography は、文字を読むための技術であり、Design の一部でもあります。日本語・English・0123456789 に加えて、「」『』（）［］！？：；、。& / + − = % ¥ $ @ # などの記号が混ざると、Font ごとの字幅やバランスを確認しやすくなります。"

    /// The text a mixed specimen shows: the entered text, or the mixed sample
    /// while the field is empty.
    func effectiveMixedText(entered: String) -> String {
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return entered }
        return Self.mixedSampleDefault
    }

    func resetSampleText() {
        sampleTexts = [:]
    }

    /// Loads the per-language sample texts, migrating the Japanese and Latin
    /// fields that predated the other languages.
    private static func loadSampleTexts(defaults: UserDefaults) -> [FontLanguage: String] {
        if let stored = defaults.dictionary(forKey: Key.sampleTexts) as? [String: String] {
            return stored.reduce(into: [:]) { texts, entry in
                if let language = FontLanguage(rawValue: entry.key), !entry.value.isEmpty {
                    texts[language] = entry.value
                }
            }
        }
        var migrated: [FontLanguage: String] = [:]
        if let japanese = defaults.string(forKey: Key.legacyJapaneseSample), !japanese.isEmpty {
            migrated[.japanese] = japanese
        }
        if let latin = defaults.string(forKey: Key.legacyLatinSample), !latin.isEmpty {
            migrated[.latin] = latin
        }
        return migrated
    }

    private func storeSampleTexts() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: sampleTexts.map { ($0.key.rawValue, $0.value) }),
            forKey: Key.sampleTexts
        )
    }

    // MARK: - Specimen colors

    /// Applies a specimen color pair; `nil` keeps the system colors.
    func setPreviewColors(background: Color?, text: Color?) {
        previewBackgroundColor = background
        previewTextColor = text
    }

    // MARK: - Variable axes

    /// The stored axis adjustments for a face; empty when its preview still
    /// uses the face's own coordinates.
    func variationValues(for postScriptName: String) -> [UInt32: Double] {
        guard let stored = variableAxes[postScriptName] else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            VariationTag.tag(from: key).map { ($0, value) }
        })
    }

    /// The stored adjustments of a family's faces, omitting unchanged faces.
    func variationValues(for faces: [FontFace]) -> [FontFace.ID: [UInt32: Double]] {
        var result: [FontFace.ID: [UInt32: Double]] = [:]
        for face in faces {
            let values = variationValues(for: face.postScriptName)
            if !values.isEmpty { result[face.id] = values }
        }
        return result
    }

    func variationValues(for face: FontFace?) -> [UInt32: Double]? {
        guard let face else { return nil }
        let values = variationValues(for: face.postScriptName)
        return values.isEmpty ? nil : values
    }

    func setVariation(_ value: Double, tag: UInt32, for postScriptName: String) {
        variableAxes[postScriptName, default: [:]][VariationTag.string(from: tag)] = value
    }

    func resetVariations(for postScriptName: String) {
        guard variableAxes[postScriptName] != nil else { return }
        variableAxes.removeValue(forKey: postScriptName)
    }

    // MARK: - Sidebar visibility

    /// The sidebar destinations the visibility settings leave visible, in
    /// sidebar order.
    var visibleSidebarSections: [LibrarySection] {
        var sections: [LibrarySection] = []
        if showAllSection { sections.append(.all) }
        if showFavoritesSection { sections.append(.favorites) }
        if showMixedSection { sections.append(.mixed) }
        if showSystemSection { sections.append(.system) }
        if showLocalSection { sections.append(.local) }
        if showDuplicatesSection { sections.append(.duplicates) }
        for provider in FontProviderRegistry.all where isProviderSectionVisible(provider.id) {
            sections.append(.provider(provider))
        }
        return sections
    }

    func isSidebarItemVisible(_ selection: LibrarySelection) -> Bool {
        switch selection {
        case .section(let section):
            if let provider = section.provider { return isProviderSectionVisible(provider.id) }
            switch section {
            case .all: return showAllSection
            case .favorites: return showFavoritesSection
            case .system: return showSystemSection
            case .local: return showLocalSection
            case .mixed: return showMixedSection
            case .duplicates: return showDuplicatesSection
            default: return false
            }
        case .systemScope: return showSystemSection
        case .folder: return true
        case .tag: return showTagsSection
        }
    }

    // MARK: - Provider sections

    /// Whether a provider's sidebar row is shown. Providers default to visible.
    func isProviderSectionVisible(_ id: String) -> Bool {
        providerSections[id] ?? true
    }

    func setProviderSection(_ id: String, visible: Bool) {
        providerSections[id] = visible
    }

    /// Loads provider visibility, migrating the per-provider toggles that
    /// predated the provider table.
    private static func loadProviderSections(defaults: UserDefaults) -> [String: Bool] {
        if let stored = defaults.dictionary(forKey: Key.providerSections) as? [String: Bool] {
            return stored
        }
        var migrated: [String: Bool] = [:]
        for provider in FontProviderRegistry.all {
            migrated[provider.id] = defaults.object(forKey: legacyVisibilityKey(for: provider.id)) as? Bool ?? true
        }
        return migrated
    }

    private static func legacyVisibilityKey(for providerID: String) -> String {
        "show\(providerID.capitalized)Section"
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
        case .tag(let tag): encoded = "tag:\(tag)"
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
        case "section":
            let section = LibrarySection(rawValue: parts[1])
            return section.isKnown ? LibrarySelection.section(section) : nil
        case "scope": return SystemFontScope(rawValue: parts[1]).map(LibrarySelection.systemScope)
        case "tag": return LibrarySelection.tag(parts[1])
        default: return nil
        }
    }

    private enum Key {
        static let previewSize = "previewSize"
        static let sampleTexts = "sampleTexts"
        /// Keys used before the sample texts became per-language.
        static let legacyJapaneseSample = "japaneseSampleText"
        static let legacyLatinSample = "latinSampleText"
        static let previewBackgroundColor = "previewBackgroundColor"
        static let previewTextColor = "previewTextColor"
        static let favoritesFirst = "favoritesFirst"
        static let showAllSection = "showAllSection"
        static let showFavoritesSection = "showFavoritesSection"
        static let showSystemSection = "showSystemSection"
        static let showLocalSection = "showLocalSection"
        static let providerSections = "providerSections"
        static let showTagsSection = "showTagsSection"
        static let showMixedSection = "showMixedSection"
        static let showDuplicatesSection = "showDuplicatesSection"
        static let variableAxes = "variableAxes"
        static let lastSelection = "lastSelection"
        static let lastLocation = "lastLocation"
    }
}

private extension AppSettings {
    /// Stores a specimen color as an sRGB hex string; `nil` (or a color with
    /// no sRGB representation) removes the stored value.
    func store(_ color: Color?, forKey key: String) {
        guard let hex = color?.specimenHexString else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(hex, forKey: key)
    }
}

private extension Color {
    /// The color as an sRGB hex string, or `nil` when it cannot be converted.
    var specimenHexString: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let components = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
        let digits = components.map { component in
            String(format: "%02X", min(max(Int((component * 255).rounded()), 0), 255))
        }
        return "#" + digits.joined()
    }

    init?(specimenHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
