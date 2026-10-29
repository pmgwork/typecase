import AppKit
import CoreText
import SwiftUI

/// One OpenType feature TypeCase offers as a toggle.
nonisolated struct OpenTypeFeature: Identifiable, Hashable, Sendable {
    /// The groups the toggles are listed under.
    enum Group: String, CaseIterable, Sendable {
        case japanese
        case letters
        case figures
        case stylisticSets

        var title: String {
            switch self {
            case .japanese: String(localized: "Japanese")
            case .letters: String(localized: "Letters")
            case .figures: String(localized: "Figures")
            case .stylisticSets: String(localized: "Stylistic Sets")
            }
        }
    }

    let tag: String
    let title: String
    let group: Group
    /// Core Text turns these on by itself; the toggle starts checked and
    /// switching it off stores an explicit `0`.
    let isOnByDefault: Bool

    var id: String { tag }

    init(_ tag: String, _ title: String, _ group: Group, onByDefault: Bool = false) {
        self.tag = tag
        self.title = title
        self.group = group
        self.isOnByDefault = onByDefault
    }

    /// Every feature TypeCase can toggle, in menu order. A face only lists the
    /// ones its `GSUB` or `GPOS` table carries.
    static let catalog: [OpenTypeFeature] = [
        OpenTypeFeature("palt", String(localized: "Proportional Metrics"), .japanese),
        OpenTypeFeature("halt", String(localized: "Half-Width Metrics"), .japanese),
        OpenTypeFeature("chws", String(localized: "Contextual Half-Width Spacing"), .japanese),
        OpenTypeFeature("pkna", String(localized: "Proportional Kana"), .japanese),
        OpenTypeFeature("hwid", String(localized: "Half Widths"), .japanese),
        OpenTypeFeature("fwid", String(localized: "Full Widths"), .japanese),
        OpenTypeFeature("jp78", String(localized: "JIS78 Forms"), .japanese),
        OpenTypeFeature("jp90", String(localized: "JIS90 Forms"), .japanese),
        OpenTypeFeature("jp04", String(localized: "JIS2004 Forms"), .japanese),
        OpenTypeFeature("nlck", String(localized: "NLC Kanji Forms"), .japanese),
        OpenTypeFeature("expt", String(localized: "Expert Forms"), .japanese),

        OpenTypeFeature("kern", String(localized: "Kerning"), .letters, onByDefault: true),
        OpenTypeFeature("liga", String(localized: "Standard Ligatures"), .letters, onByDefault: true),
        OpenTypeFeature("calt", String(localized: "Contextual Alternates"), .letters, onByDefault: true),
        OpenTypeFeature("dlig", String(localized: "Discretionary Ligatures"), .letters),
        OpenTypeFeature("case", String(localized: "Case-Sensitive Forms"), .letters),
        OpenTypeFeature("smcp", String(localized: "Small Capitals"), .letters),
        OpenTypeFeature("c2sc", String(localized: "Capitals to Small Capitals"), .letters),
        OpenTypeFeature("salt", String(localized: "Stylistic Alternates"), .letters),
        OpenTypeFeature("swsh", String(localized: "Swash"), .letters),

        OpenTypeFeature("lnum", String(localized: "Lining Figures"), .figures),
        OpenTypeFeature("onum", String(localized: "Oldstyle Figures"), .figures),
        OpenTypeFeature("pnum", String(localized: "Proportional Figures"), .figures),
        OpenTypeFeature("tnum", String(localized: "Tabular Figures"), .figures),
        OpenTypeFeature("frac", String(localized: "Fractions"), .figures),
        OpenTypeFeature("zero", String(localized: "Slashed Zero"), .figures),
        OpenTypeFeature("sups", String(localized: "Superscript"), .figures),
        OpenTypeFeature("subs", String(localized: "Subscript"), .figures),
        OpenTypeFeature("ordn", String(localized: "Ordinals"), .figures),
    ] + (1...20).map { index in
        OpenTypeFeature(String(format: "ss%02d", index), String(localized: "Stylistic Set \(index)"), .stylisticSets)
    }
}

/// The typesetting choices a mixed pair carries on top
/// of its fonts: OpenType feature overrides, the space between Japanese and
/// Latin text (和欧間のアキ), and the Character panel settings Illustrator
/// uses — kerning, tracking in 1/1000 em, and tsume (文字ツメ).
nonisolated struct TypesettingOptions: Codable, Hashable, Sendable {
    /// The largest Japanese–Latin space the controls offer, in em.
    static let spacingRange: ClosedRange<Double> = 0...0.5
    /// Illustrator's tracking range, in 1/1000 em.
    static let trackingRange: ClosedRange<Double> = -1000...10000

    /// Illustrator's kerning methods that Core Text can reproduce. Optical
    /// kerning has no Core Text equivalent, so it is not offered.
    enum Kerning: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The font's own kerning pairs (Illustrator's Auto, or メトリクス).
        case auto
        /// The font's kerning for Latin text only; Japanese text is set solid.
        case romanOnly
        /// No kerning.
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: String(localized: "Auto")
            case .romanOnly: String(localized: "Metrics – Roman Only")
            case .none: "0"
            }
        }
    }

    /// Explicit feature states by tag. A feature that is not listed keeps the
    /// font's own default, so only the user's changes are stored.
    var features: [String: Bool]
    /// Extra space between Japanese and Latin letters or figures, in em.
    var japaneseLatinSpacing: Double
    var kerning: Kerning
    /// Space added after every character, in 1/1000 em like Illustrator.
    var tracking: Double
    /// How much of each glyph's side bearings is removed, 0–1 (文字ツメ).
    var tsume: Double

    init(
        features: [String: Bool] = [:],
        japaneseLatinSpacing: Double = 0,
        kerning: Kerning = .auto,
        tracking: Double = 0,
        tsume: Double = 0
    ) {
        self.features = features
        self.japaneseLatinSpacing = japaneseLatinSpacing
        self.kerning = kerning
        self.tracking = tracking
        self.tsume = tsume
    }

    private enum CodingKeys: String, CodingKey {
        case features, japaneseLatinSpacing, kerning, tracking, tsume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = (try? container.decodeIfPresent([String: Bool].self, forKey: .features)) ?? [:]
        let spacing = (try? container.decodeIfPresent(Double.self, forKey: .japaneseLatinSpacing)) ?? 0
        japaneseLatinSpacing = min(max(spacing, Self.spacingRange.lowerBound), Self.spacingRange.upperBound)
        kerning = (try? container.decodeIfPresent(Kerning.self, forKey: .kerning)) ?? .auto
        let tracking = (try? container.decodeIfPresent(Double.self, forKey: .tracking)) ?? 0
        self.tracking = min(max(tracking, Self.trackingRange.lowerBound), Self.trackingRange.upperBound)
        let tsume = (try? container.decodeIfPresent(Double.self, forKey: .tsume)) ?? 0
        self.tsume = min(max(tsume, 0), 1)
    }

    /// The feature settings for the faces drawing one part of a mix: the
    /// kerning method switches `kern` off everywhere, or only for Japanese.
    func features(for script: MixedScript) -> [String: Bool] {
        var result = features
        switch kerning {
        case .auto: break
        case .romanOnly where script == .japanese: result["kern"] = false
        case .romanOnly: break
        case .none: result["kern"] = false
        }
        return result
    }

    /// Whether anything adds space between characters beyond the fonts' own
    /// advances.
    var adjustsSpacing: Bool {
        japaneseLatinSpacing != 0 || tracking != 0 || tsume != 0
    }

    func isOn(_ feature: OpenTypeFeature) -> Bool {
        features[feature.tag] ?? feature.isOnByDefault
    }

    /// Stores a feature state, dropping it again when it matches the default.
    mutating func set(_ feature: OpenTypeFeature, on: Bool) {
        features[feature.tag] = on == feature.isOnByDefault ? nil : on
    }

    /// The space in points for a given font size.
    func spacing(at size: CGFloat) -> CGFloat {
        size * CGFloat(japaneseLatinSpacing)
    }
}

/// Finds where Japanese text meets Latin letters or figures, the places the
/// Japanese–Latin space is inserted. Punctuation and spaces on either side
/// never take it, matching how Japanese composition rules treat 約物.
nonisolated enum JapaneseLatinSpacing {
    /// Kana and ideographs, not Japanese punctuation or full-width forms.
    static func isJapaneseLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              MixedText.isJapanese(scalar),
              !(0xFF00...0xFFEF).contains(scalar.value) else { return false }
        switch scalar.properties.generalCategory {
        case .otherLetter, .modifierLetter: return true
        default: return false
        }
    }

    /// Latin (or any non-Japanese) letters and figures.
    static func isLatinWord(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              !MixedText.isJapanese(scalar) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    static func isBoundary(_ first: Character, _ second: Character) -> Bool {
        (isJapaneseLetter(first) && isLatinWord(second)) || (isLatinWord(first) && isJapaneseLetter(second))
    }

    /// The UTF-16 ranges of the characters followed by a boundary. The space
    /// is added after these characters as extra kerning.
    static func boundaryRanges(in string: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        var previous: Character?
        var previousLength = 0
        for character in string {
            if let previous, isBoundary(previous, character) {
                ranges.append(NSRange(location: location - previousLength, length: previousLength))
            }
            previous = character
            previousLength = character.utf16.count
            location += previousLength
        }
        return ranges
    }

    /// Adds the space to an AppKit string whose characters already carry
    /// `baseKern` (the tracking). Characters inside `skipping` (IME marked
    /// text) are left alone.
    static func apply(
        to storage: NSMutableAttributedString,
        spacing: CGFloat,
        baseKern: CGFloat = 0,
        skipping marked: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        guard spacing != 0 else { return }
        for range in boundaryRanges(in: storage.string) {
            if marked.location != NSNotFound, NSIntersectionRange(range, marked).length > 0 { continue }
            storage.addAttribute(.kern, value: baseKern + spacing, range: range)
        }
    }

    /// The same space for a SwiftUI string, as kerning after each boundary
    /// character. SwiftUI adds it to any tracking the text view applies.
    static func apply(to attributed: inout AttributedString, spacing: CGFloat) {
        guard spacing != 0 else { return }
        var index = attributed.startIndex
        while index < attributed.endIndex {
            let next = attributed.characters.index(after: index)
            guard next < attributed.endIndex else { break }
            if isBoundary(attributed.characters[index], attributed.characters[next]) {
                attributed[index..<next].swiftUI.kern = spacing
            }
            index = next
        }
    }

    static func attributed(_ text: String, spacing: CGFloat) -> AttributedString {
        var attributed = AttributedString(text)
        apply(to: &attributed, spacing: spacing)
        return attributed
    }
}

/// Illustrator-style character spacing: tracking after every character, tsume
/// trimming each glyph's side bearings, and the Japanese–Latin space, all
/// expressed as kerning after each character.
nonisolated enum CharacterSpacing {
    /// The kerning after each character, by UTF-16 range. `font` returns the
    /// font drawing a character; tsume needs its glyph's side bearings.
    static func kerns(
        in string: String,
        size: CGFloat,
        options: TypesettingOptions,
        font: (Character) -> CTFont?
    ) -> [(range: NSRange, kern: CGFloat)] {
        guard options.adjustsSpacing else { return [] }
        let tracking = size * CGFloat(options.tracking) / 1000
        let japaneseLatin = size * CGFloat(options.japaneseLatinSpacing)
        let tsume = CGFloat(options.tsume)
        var bearings: [String: (left: CGFloat, right: CGFloat)] = [:]

        func sideBearings(of character: Character) -> (left: CGFloat, right: CGFloat) {
            guard tsume != 0, let ctFont = font(character) else { return (0, 0) }
            let key = "\(CTFontCopyPostScriptName(ctFont))|\(CTFontGetSize(ctFont))|\(character)"
            if let cached = bearings[key] { return cached }
            let utf16 = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            var result: (CGFloat, CGFloat) = (0, 0)
            if CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count), glyphs[0] != 0 {
                var glyph = glyphs[0]
                let advance = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, nil, 1)
                let bounds = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, nil, 1)
                // Spaces have no outline; their whole advance is not a bearing.
                if !bounds.isEmpty {
                    result = (max(0, bounds.minX), max(0, advance - bounds.maxX))
                }
            }
            bearings[key] = result
            return result
        }

        func advance(of character: Character) -> CGFloat? {
            guard let ctFont = font(character) else { return nil }
            let utf16 = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            guard CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count) else { return nil }
            return CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyphs, nil, 1)
        }

        var kerns: [(range: NSRange, kern: CGFloat)] = []
        let characters = Array(string)
        var location = 0
        for (index, character) in characters.enumerated() {
            let length = character.utf16.count
            var kern = tracking
            if index + 1 < characters.count {
                let next = characters[index + 1]
                if japaneseLatin != 0, JapaneseLatinSpacing.isBoundary(character, next) {
                    kern += japaneseLatin
                } else if japaneseLatin != 0, character == " ", index > 0,
                          JapaneseLatinSpacing.isBoundary(characters[index - 1], next),
                          let spaceWidth = advance(of: character) {
                    // A space typed at the boundary takes the chosen width,
                    // so the setting also reads in text spaced by hand.
                    kern += japaneseLatin - spaceWidth
                }
                if tsume != 0 {
                    kern -= tsume * (sideBearings(of: character).right + sideBearings(of: next).left)
                }
            }
            if kern != 0 {
                kerns.append((NSRange(location: location, length: length), kern))
            }
            location += length
        }
        return kerns
    }

    /// Applies the kerning to an AppKit string, leaving IME marked text alone.
    static func apply(
        to storage: NSMutableAttributedString,
        size: CGFloat,
        options: TypesettingOptions,
        skipping marked: NSRange = NSRange(location: NSNotFound, length: 0),
        font: (Character) -> CTFont?
    ) {
        for entry in kerns(in: storage.string, size: size, options: options, font: font) {
            if marked.location != NSNotFound, NSIntersectionRange(entry.range, marked).length > 0 { continue }
            storage.addAttribute(.kern, value: entry.kern, range: entry.range)
        }
    }

    /// Applies the kerning to a SwiftUI string.
    static func apply(
        to attributed: inout AttributedString,
        size: CGFloat,
        options: TypesettingOptions,
        font: (Character) -> CTFont?
    ) {
        let kerns = kerns(in: String(attributed.characters), size: size, options: options, font: font)
        guard !kerns.isEmpty else { return }
        var byLocation: [Int: CGFloat] = [:]
        for entry in kerns { byLocation[entry.range.location] = entry.kern }
        var index = attributed.startIndex
        var location = 0
        while index < attributed.endIndex {
            let next = attributed.characters.index(after: index)
            let character = attributed.characters[index]
            if let kern = byLocation[location] {
                attributed[index..<next].swiftUI.kern = kern
            }
            location += character.utf16.count
            index = next
        }
    }
}

/// Reads which OpenType features a face carries from its `GSUB` and `GPOS`
/// feature lists, plus `kern` for a legacy `kern` table. Results are cached
/// per face for the session.
@MainActor
enum OpenTypeFeatureReader {
    private static var cache: [String: Set<String>] = [:]

    static func tags(postScriptName: String, fileURL: URL?) -> Set<String> {
        let key = "\(postScriptName)|\(fileURL?.path ?? "")"
        if let cached = cache[key] { return cached }
        guard FontResolver.shared.isResolvable(postScriptName: postScriptName, fileURL: fileURL) else {
            return []
        }
        let font = FontResolver.shared.nsFont(postScriptName: postScriptName, fileURL: fileURL, size: 12) as CTFont
        var tags = Set<String>()
        for table in [kCTFontTableGSUB, kCTFontTableGPOS] {
            if let data = CTFontCopyTable(font, CTFontTableTag(table), []) as Data? {
                tags.formUnion(featureTags(in: data))
            }
        }
        if CTFontCopyTable(font, CTFontTableTag(kCTFontTableKern), []) != nil {
            tags.insert("kern")
        }
        cache[key] = tags
        return tags
    }

    /// The tags of a `GSUB`/`GPOS` FeatureList. The header's fourth field is
    /// the list's offset; each record is a four-byte tag and a two-byte offset.
    nonisolated static func featureTags(in data: Data) -> Set<String> {
        let bytes = [UInt8](data)
        func uint16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        guard let listOffset = uint16(6), let count = uint16(listOffset) else { return [] }
        var tags = Set<String>()
        for index in 0..<count {
            let record = listOffset + 2 + index * 6
            guard record + 4 <= bytes.count,
                  let tag = String(bytes: bytes[record..<record + 4], encoding: .ascii) else { break }
            tags.insert(tag)
        }
        return tags
    }

    /// The catalog's features a set of faces carries, in catalog order.
    static func features(for faces: [(postScriptName: String, fileURL: URL?)]) -> [OpenTypeFeature] {
        let tags = faces.reduce(into: Set<String>()) { result, face in
            result.formUnion(Self.tags(postScriptName: face.postScriptName, fileURL: face.fileURL))
        }
        return OpenTypeFeature.catalog.filter { tags.contains($0.tag) }
    }
}

/// The feature toggles as checkboxes grouped under small headings, for an
/// inspector with room to list them.
struct OpenTypeFeatureList: View {
    let features: [OpenTypeFeature]
    @Binding var options: TypesettingOptions

    var body: some View {
        if features.isEmpty {
            Text(String(localized: "This style has no OpenType features to switch."))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(OpenTypeFeature.Group.allCases, id: \.self) { group in
                    let items = features.filter { $0.group == group }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            ForEach(items) { feature in
                                Toggle(isOn: binding(for: feature)) {
                                    HStack(spacing: 6) {
                                        Text(feature.title)
                                        Text(feature.tag)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
        }
    }

    private func binding(for feature: OpenTypeFeature) -> Binding<Bool> {
        Binding(
            get: { options.isOn(feature) },
            set: { options.set(feature, on: $0) }
        )
    }
}

/// The feature toggles as a native pull-down menu with a checkmark per
/// feature, for places too narrow to list them.
struct OpenTypeFeatureMenu: View {
    let features: [OpenTypeFeature]
    @Binding var options: TypesettingOptions
    /// Features another control already owns, such as `kern` under Kerning.
    var excluding: Set<String> = []

    private var listed: [OpenTypeFeature] {
        features.filter { !excluding.contains($0.tag) }
    }

    private var changedCount: Int {
        options.features.keys.filter { !excluding.contains($0) }.count
    }

    var body: some View {
        Menu {
            ForEach(OpenTypeFeature.Group.allCases, id: \.self) { group in
                let items = listed.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { feature in
                            Toggle("\(feature.title) (\(feature.tag))", isOn: Binding(
                                get: { options.isOn(feature) },
                                set: { options.set(feature, on: $0) }
                            ))
                        }
                    }
                }
            }
            if changedCount > 0 {
                Divider()
                Button(String(localized: "Reset Features")) {
                    options.features = options.features.filter { excluding.contains($0.key) }
                }
            }
        } label: {
            Text(changedCount > 0
                ? String(localized: "OpenType Features (\(changedCount) changed)")
                : String(localized: "OpenType Features"))
        }
        .disabled(listed.isEmpty)
        .help(listed.isEmpty
            ? String(localized: "These fonts have no OpenType features to switch")
            : String(localized: "Switch OpenType features of the pair's fonts"))
    }
}
