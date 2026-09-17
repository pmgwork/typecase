import Foundation

/// A writing system TypeCase reads font metadata for and previews with.
///
/// The raw values are TypeCase's own identifiers: they key persisted sample
/// texts and the dictionaries the scanner builds, so they stay stable across
/// releases. Latin is the fallback for every other script and never appears in
/// a font's detected language set.
nonisolated enum FontLanguage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case japanese
    case simplifiedChinese
    case traditionalChinese
    case korean
    case latin

    var id: String { rawValue }

    /// The order preview samples and display names follow when a font carries
    /// more than one of the languages TypeCase shows.
    static let previewPriority: [FontLanguage] = [
        .japanese, .simplifiedChinese, .traditionalChinese, .korean,
    ]

    /// The language's name in the interface and the inspector.
    var title: String {
        switch self {
        case .japanese: "Japanese"
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .korean: "Korean"
        case .latin: "Latin / Other"
        }
    }

    /// The built-in specimen sentence shown while the preview text field is
    /// empty.
    var sampleDefault: String {
        switch self {
        case .japanese: "美しい文字は、言葉の表情を豊かにする。"
        case .simplifiedChinese: "优美的文字，让语言的表情更丰富。"
        case .traditionalChinese: "優美的文字，讓語言的表情更豐富。"
        case .korean: "아름다운 글자는 말의 표정을 풍부하게 만든다."
        case .latin: "Typography gives every word a distinct voice."
        }
    }

    /// Whether a `kCTFontLanguagesAttribute` entry names this language's
    /// script. Core Text reports BCP 47 tags, but legacy fonts use the older
    /// `zh-CN`/`zh-TW` spellings, so both are recognized.
    func matches(coreTextLanguage code: String) -> Bool {
        let code = code.lowercased()
        switch self {
        case .japanese:
            return code == "ja" || code.hasPrefix("ja-")
        case .simplifiedChinese:
            return code == "zh-hans" || code.hasPrefix("zh-hans-")
                || code == "zh-cn" || code == "zh-sg"
        case .traditionalChinese:
            return code == "zh-hant" || code.hasPrefix("zh-hant-")
                || code == "zh-tw" || code == "zh-hk" || code == "zh-mo"
        case .korean:
            return code == "ko" || code.hasPrefix("ko-")
        case .latin:
            return false
        }
    }

    /// The CJK languages a font declares. A bare `zh` carries no script
    /// sub-tag; it counts as Simplified only when the font does not also
    /// declare a Traditional script, so a Traditional-only font does not match
    /// both. Accepts Core Text language lists and `meta` design languages.
    static func detected(in codes: [String]) -> Set<FontLanguage> {
        let codes = codes.map { $0.lowercased() }
        var languages = Set(previewPriority.filter { language in
            codes.contains { language.matches(coreTextLanguage: $0) }
        })
        if !languages.contains(.traditionalChinese), codes.contains("zh") {
            languages.insert(.simplifiedChinese)
        }
        return languages
    }
}
