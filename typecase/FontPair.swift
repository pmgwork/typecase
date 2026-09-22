import Foundation
import SwiftUI

/// Names one face of the library by its family and PostScript name.
///
/// Family ids and PostScript names stay stable across launches, so a saved
/// mixed-preview pair survives restarts without storing file paths. The file
/// URL is resolved from the catalog when the pair is drawn.
nonisolated struct FontFaceReference: Codable, Hashable, Sendable {
    let familyID: FontFamily.ID
    let postScriptName: String

    init(familyID: FontFamily.ID, postScriptName: String) {
        self.familyID = familyID
        self.postScriptName = postScriptName
    }

    /// The family's preview face, the face the list shows. Families without
    /// faces never reach the pair controls.
    init?(family: FontFamily) {
        guard let face = family.previewFace else { return nil }
        self.init(familyID: family.id, postScriptName: face.postScriptName)
    }
}

/// A saved mixed-font combination: the face that draws each part of a
/// specimen. The Japanese and Latin faces are required; the rest are optional.
nonisolated struct FontPair: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var japanese: FontFaceReference
    var latin: FontFaceReference
    var numbers: FontFaceReference?
    var symbols: FontFaceReference?

    init(
        id: UUID = UUID(),
        japanese: FontFaceReference,
        latin: FontFaceReference,
        numbers: FontFaceReference? = nil,
        symbols: FontFaceReference? = nil
    ) {
        self.id = id
        self.japanese = japanese
        self.latin = latin
        self.numbers = numbers
        self.symbols = symbols
    }

    /// The face that draws one part of the mix, when the pair sets it.
    func reference(for script: MixedScript) -> FontFaceReference? {
        switch script {
        case .japanese: japanese
        case .latin: latin
        case .numbers: numbers
        case .symbols: symbols
        }
    }

    /// The faces the pair sets, in slot order.
    var references: [(script: MixedScript, reference: FontFaceReference)] {
        MixedScript.allCases.compactMap { script in
            reference(for: script).map { (script, $0) }
        }
    }

    /// The list selection value that names this pair. Family ids are folded
    /// family names, so the prefix keeps the two kinds of rows apart.
    var selectionID: String { Self.selectionID(for: id) }

    static func selectionID(for id: UUID) -> String {
        "pair:\(id.uuidString)"
    }

    /// Whether a list selection value names a mixed pair rather than a family.
    static func isSelectionID(_ value: String) -> Bool {
        value.hasPrefix("pair:")
    }

    /// How a pair is named, from its two required fonts.
    static func defaultName(japanese: String, latin: String) -> String {
        "\(japanese) ＋ \(latin)"
    }
}

/// The parts of a mixed specimen, each drawn with its own font.
nonisolated enum MixedScript: String, Codable, CaseIterable, Hashable, Sendable {
    case japanese
    case latin
    case numbers
    case symbols

    var title: String {
        switch self {
        case .japanese: "Japanese"
        case .latin: "English"
        case .numbers: "Numbers"
        case .symbols: "Symbols"
        }
    }
}

/// One face of a mixed specimen and the axis values it is drawn with.
nonisolated struct PreviewFaceSpec: Hashable, Sendable {
    let postScriptName: String
    let fileURL: URL?
    let variations: [UInt32: Double]?
}

/// Splits preview text by script so each run can be drawn with its own font.
///
/// Kana, ideographs, Japanese punctuation, and the full-width forms belong to
/// the Japanese part; digits to the numbers part; punctuation and symbols to
/// the symbols part; letters and everything else to the English part.
nonisolated enum MixedText {
    /// Kana, ideographs, Japanese punctuation, and the full-width forms.
    static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF,   // CJK symbols and punctuation, kana
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFE10...0xFE1F,   // Vertical forms
             0xFE30...0xFE4F,   // CJK Compatibility Forms
             0xFF00...0xFFEF,   // Full-width and half-width forms
             0x1B000...0x1B16F, // Kana supplement and extended
             0x1F200...0x1F2FF, // Enclosed ideographic supplement
             0x20000...0x2FA1F, // Ideograph extensions B–F and compatibility
             0x30000...0x323AF: // Ideograph extensions G and H
            return true
        default:
            return false
        }
    }

    /// The part of a mixed specimen a character belongs to. The first scalar
    /// decides, so a base character carries its combining marks with it.
    static func script(of character: Character) -> MixedScript {
        guard let scalar = character.unicodeScalars.first else { return .latin }
        if isJapanese(scalar) { return .japanese }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber:
            return .numbers
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return .symbols
        default:
            return .latin
        }
    }

    /// The text with each part set in its font. Runs are cut at script changes,
    /// so a face only ever draws the characters it is responsible for and Core
    /// Text's fallback stays out of the mix. A missing face falls back to the
    /// next one that can draw the run.
    static func attributed(_ text: String, fonts: [MixedScript: Font]) -> AttributedString {
        var attributed = AttributedString(text)
        var index = attributed.startIndex
        while index < attributed.endIndex {
            let runScript = MixedText.script(of: attributed.characters[index])
            let start = index
            repeat {
                index = attributed.characters.index(after: index)
            } while index < attributed.endIndex
                && MixedText.script(of: attributed.characters[index]) == runScript
            if let font = font(for: runScript, in: fonts) {
                attributed[start..<index].font = font
            }
        }
        return attributed
    }

    /// The font that draws one part, falling back through the fonts that can
    /// stand in for it.
    private static func font(for script: MixedScript, in fonts: [MixedScript: Font]) -> Font? {
        for candidate in fallbackScripts(for: script) {
            if let font = fonts[candidate] { return font }
        }
        return nil
    }

    /// The fonts that can stand in for one part, most specific first.
    static func fallbackScripts(for script: MixedScript) -> [MixedScript] {
        fallbackOrder[script] ?? [script]
    }

    private static let fallbackOrder: [MixedScript: [MixedScript]] = [
        .japanese: [.japanese, .latin],
        .latin: [.latin, .japanese],
        .numbers: [.numbers, .symbols, .latin, .japanese],
        .symbols: [.symbols, .numbers, .latin, .japanese],
    ]
}

nonisolated extension FontFamily {
    /// Whether the family belongs to the Japanese side of a mixed specimen.
    /// The preview language already weighs a Japanese localized name against
    /// the declared languages, matching how the list picks its sample text.
    var usesJapaneseScript: Bool { previewLanguage == .japanese }
}
