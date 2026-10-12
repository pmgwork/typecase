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
            case .japanese: "Japanese"
            case .letters: "Letters"
            case .figures: "Figures"
            case .stylisticSets: "Stylistic Sets"
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
        OpenTypeFeature("palt", "Proportional Metrics", .japanese),
        OpenTypeFeature("halt", "Half-Width Metrics", .japanese),
        OpenTypeFeature("chws", "Contextual Half-Width Spacing", .japanese),
        OpenTypeFeature("pkna", "Proportional Kana", .japanese),
        OpenTypeFeature("hwid", "Half Widths", .japanese),
        OpenTypeFeature("fwid", "Full Widths", .japanese),
        OpenTypeFeature("jp78", "JIS78 Forms", .japanese),
        OpenTypeFeature("jp90", "JIS90 Forms", .japanese),
        OpenTypeFeature("jp04", "JIS2004 Forms", .japanese),
        OpenTypeFeature("nlck", "NLC Kanji Forms", .japanese),
        OpenTypeFeature("expt", "Expert Forms", .japanese),

        OpenTypeFeature("kern", "Kerning", .letters, onByDefault: true),
        OpenTypeFeature("liga", "Standard Ligatures", .letters, onByDefault: true),
        OpenTypeFeature("calt", "Contextual Alternates", .letters, onByDefault: true),
        OpenTypeFeature("dlig", "Discretionary Ligatures", .letters),
        OpenTypeFeature("case", "Case-Sensitive Forms", .letters),
        OpenTypeFeature("smcp", "Small Capitals", .letters),
        OpenTypeFeature("c2sc", "Capitals to Small Capitals", .letters),
        OpenTypeFeature("salt", "Stylistic Alternates", .letters),
        OpenTypeFeature("swsh", "Swash", .letters),

        OpenTypeFeature("lnum", "Lining Figures", .figures),
        OpenTypeFeature("onum", "Oldstyle Figures", .figures),
        OpenTypeFeature("pnum", "Proportional Figures", .figures),
        OpenTypeFeature("tnum", "Tabular Figures", .figures),
        OpenTypeFeature("frac", "Fractions", .figures),
        OpenTypeFeature("zero", "Slashed Zero", .figures),
        OpenTypeFeature("sups", "Superscript", .figures),
        OpenTypeFeature("subs", "Subscript", .figures),
        OpenTypeFeature("ordn", "Ordinals", .figures),
    ] + (1...20).map { index in
        OpenTypeFeature(String(format: "ss%02d", index), "Stylistic Set \(index)", .stylisticSets)
    }
}

/// The typesetting choices a PlayGround block or a mixed pair carries on top
/// of its fonts: OpenType feature overrides and the space between Japanese
/// and Latin text (和欧間のアキ).
nonisolated struct TypesettingOptions: Codable, Hashable, Sendable {
    /// The largest Japanese–Latin space the controls offer, in em.
    static let spacingRange: ClosedRange<Double> = 0...0.5

    /// Explicit feature states by tag. A feature that is not listed keeps the
    /// font's own default, so only the user's changes are stored.
    var features: [String: Bool]
    /// Extra space between Japanese and Latin letters or figures, in em.
    var japaneseLatinSpacing: Double

    init(features: [String: Bool] = [:], japaneseLatinSpacing: Double = 0) {
        self.features = features
        self.japaneseLatinSpacing = japaneseLatinSpacing
    }

    private enum CodingKeys: String, CodingKey {
        case features, japaneseLatinSpacing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = (try? container.decodeIfPresent([String: Bool].self, forKey: .features)) ?? [:]
        let spacing = (try? container.decodeIfPresent(Double.self, forKey: .japaneseLatinSpacing)) ?? 0
        japaneseLatinSpacing = min(max(spacing, Self.spacingRange.lowerBound), Self.spacingRange.upperBound)
    }

    func isOn(_ feature: OpenTypeFeature) -> Bool {
        features[feature.tag] ?? feature.isOnByDefault
    }

    /// Stores a feature state, dropping it again when it matches the default.
    mutating func set(_ feature: OpenTypeFeature, on: Bool) {
        features[feature.tag] = on == feature.isOnByDefault ? nil : on
    }

    /// The tags switched away from their defaults, for the "N on" summaries.
    var changedFeatureCount: Int { features.count }

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
            Text("This style has no OpenType features to switch.")
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

    var body: some View {
        Menu {
            ForEach(OpenTypeFeature.Group.allCases, id: \.self) { group in
                let items = features.filter { $0.group == group }
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
            if options.changedFeatureCount > 0 {
                Divider()
                Button("Reset Features") { options.features = [:] }
            }
        } label: {
            Text(options.changedFeatureCount > 0
                ? "OpenType Features (\(options.changedFeatureCount) changed)"
                : "OpenType Features")
        }
        .disabled(features.isEmpty)
        .help(features.isEmpty
            ? "These fonts have no OpenType features to switch"
            : "Switch OpenType features of the pair's fonts")
    }
}
