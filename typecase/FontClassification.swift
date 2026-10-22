import CoreText
import Foundation

nonisolated enum FontCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sansSerif
    case serif
    case monospaced
    case display
    case script
    case symbols
    case unclassified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sansSerif: String(localized: "Sans Serif")
        case .serif: String(localized: "Serif")
        case .monospaced: String(localized: "Monospaced")
        case .display: String(localized: "Display")
        case .script: String(localized: "Script / Handwriting")
        case .symbols: String(localized: "Symbols")
        case .unclassified: String(localized: "Unclassified")
        }
    }
}

/// Uses face-specific OpenType metadata before falling back to family names.
/// PANOSE: https://monotype.github.io/panose/pan2.htm
/// OS/2: https://learn.microsoft.com/en-us/typography/opentype/spec/os2
nonisolated enum FontClassifier {
    static func classify(font: CTFont, family: String, localizedNames: [String]) -> FontCategory {
        let metadataCategory = classify(
            names: [family] + localizedNames,
            symbolicTraits: CTFontGetSymbolicTraits(font).rawValue,
            os2: CTFontCopyTable(font, 0x4F532F32, []).map { $0 as Data }
        )
        return metadataCategory == .unclassified ? outlineCategory(font: font) ?? .unclassified : metadataCategory
    }

    static func classify(names: [String], symbolicTraits: UInt32 = 0, os2: Data? = nil) -> FontCategory {
        let bytes = os2.map(Array.init) ?? []
        // Offsets are shared by every version of OS/2. Unknown PANOSE values
        // (0 = any, 1 = no fit) are never evidence of a design class.
        let panose = bytes.count >= 42 ? Array(bytes[32..<42]) : []
        if symbolicTraits & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0
            || (panose.count == 10 && panose[0] == 2 && panose[3] == 9) {
            return .monospaced
        }

        let name = names.joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        // CJK design names are more useful than the Latin PANOSE values some
        // CJK fonts use for their embedded Latin alphabet.
        if containsAny(name, ["楷書", "楷书", "楷体", "楷體", "行書", "行书", "草書", "草书",
                              "隷書", "隶书", "篆書", "篆书", "手書", "手写", "毛筆", "教科書"]) {
            return .script
        }
        if containsAny(name, ["明朝", "明體", "明体", "宋体", "宋體", "仿宋"]) { return .serif }
        if containsAny(name, ["ゴシック", "角ゴ", "丸ゴ", "黑体", "黑體", "고딕", "돋움"]) {
            return .sansSerif
        }
        if name.contains("바탕") { return .serif }

        if panose.count == 10 {
            switch panose[0] {
            case 2:
                if (2...10).contains(panose[1]) { return .serif }
                if (11...15).contains(panose[1]) { return .sansSerif }
            case 3: return .script
            case 4: return .display
            case 5: return .symbols
            default: break
            }
        }
        if bytes.count >= 32, let category = category(forClass: UInt32(bytes[30])) { return category }
        // Core Text exposes the same IBM design classes in the high four bits,
        // also covering fonts without an OS/2 table (including older AAT faces).
        if let category = category(forClass: symbolicTraits >> 28) { return category }

        let separated = names.joined(separator: " ").replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        ).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(separated.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ candidates: [String]) -> Bool { !words.isDisjoint(with: candidates) }
        // Match words, not substrings: Monotype is not monospaced, and Sans
        // Serif must be tested before Serif. Style names like "Display" are
        // intentionally excluded: an optical size does not change the design.
        if has(["mono", "monospaced", "monospace", "typewriter"]) { return .monospaced }
        if has(["symbols", "symbol", "dingbats", "dingbat", "emoji", "icons"]) { return .symbols }
        if has(["script", "handwriting", "handwritten", "brush", "calligraphy", "cursive", "chancery"]) { return .script }
        if has(["sans", "sansserif", "gothic", "grotesk", "grotesque", "kaku", "maru", "heiti", "dotum"]) { return .sansSerif }
        if has(["serif", "mincho", "minchou", "ming", "mingcho", "song", "songti", "myeongjo", "batang"]) {
            return .serif
        }
        if has(["display", "decorative", "ornamental", "blackletter", "fraktur", "pixel", "bitmap"]) { return .display }
        return .unclassified
    }

    /// Each distinct face gets one vote; missing classifications cannot hide
    /// metadata supplied by other faces. Ties use a fixed order, not scan order.
    static func familyCategory(_ categories: [FontCategory]) -> FontCategory {
        let counts = Dictionary(grouping: categories.filter { $0 != .unclassified }, by: { $0 }).mapValues(\.count)
        var best = FontCategory.unclassified
        var bestCount = 0
        for category in FontCategory.allCases where counts[category, default: 0] > bestCount {
            best = category
            bestCount = counts[category, default: 0]
        }
        return best
    }

    /// Conservative fallback for Latin fonts with no declared design class.
    /// Inspect both terminals of H and the feet of n: a serif widens each stem
    /// near its end. All three measurements must agree. A barred capital I
    /// alone would incorrectly mark many sans serifs as serif.
    static func outlineCategory(font: CTFont) -> FontCategory? {
        let font = CTFontCreateCopyWithAttributes(font, 1000, nil, nil)
        let characters: [UniChar] = [0x48, 0x6E]
        var glyphs = [CGGlyph](repeating: 0, count: 2)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, 2),
              let h = CTFontCreatePathForGlyph(font, glyphs[0], nil),
              let n = CTFontCreatePathForGlyph(font, glyphs[1], nil) else { return nil }
        let hEdges = edges(of: h), nEdges = edges(of: n)
        guard let bottomH = terminalRatio(hEdges, bounds: h.boundingBoxOfPath, top: false),
              let topH = terminalRatio(hEdges, bounds: h.boundingBoxOfPath, top: true),
              let bottomN = terminalRatio(nEdges, bounds: n.boundingBoxOfPath, top: false) else { return nil }
        let ratios = [bottomH, topH, bottomN]
        if ratios.allSatisfy({ $0 >= 1.5 }) { return .serif }
        if ratios.allSatisfy({ $0 <= 1.12 }) { return .sansSerif }
        return nil
    }

    private struct Edge { let a: CGPoint; let b: CGPoint }

    private static func edges(of path: CGPath) -> [Edge] {
        var result: [Edge] = []
        var current = CGPoint.zero, start = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]; start = current
            case .addLineToPoint:
                result.append(Edge(a: current, b: element.points[0]))
                current = element.points[0]
            case .addQuadCurveToPoint, .addCurveToPoint:
                let origin = current
                let control = element.points[0]
                let cubic = element.type == .addCurveToPoint
                let end = element.points[cubic ? 2 : 1]
                for step in 1...32 {
                    let t = CGFloat(step) / 32, u = 1 - t
                    let point: CGPoint
                    if cubic {
                        let second = element.points[1]
                        point = CGPoint(x: u*u*u*origin.x + 3*u*u*t*control.x + 3*u*t*t*second.x + t*t*t*end.x,
                                        y: u*u*u*origin.y + 3*u*u*t*control.y + 3*u*t*t*second.y + t*t*t*end.y)
                    } else {
                        point = CGPoint(x: u*u*origin.x + 2*u*t*control.x + t*t*end.x,
                                        y: u*u*origin.y + 2*u*t*control.y + t*t*end.y)
                    }
                    result.append(Edge(a: current, b: point)); current = point
                }
            case .closeSubpath:
                result.append(Edge(a: current, b: start)); current = start
            @unknown default: break
            }
        }
        return result
    }

    private static func terminalRatio(_ edges: [Edge], bounds: CGRect, top: Bool) -> CGFloat? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        func widths(at fraction: CGFloat) -> [CGFloat]? {
            let y = bounds.minY + bounds.height * (top ? 1 - fraction : fraction)
            let intersections = edges.compactMap { edge -> CGFloat? in
                guard (edge.a.y <= y && edge.b.y > y) || (edge.b.y <= y && edge.a.y > y) else { return nil }
                return edge.a.x + (y - edge.a.y) * (edge.b.x - edge.a.x) / (edge.b.y - edge.a.y)
            }.sorted()
            // Two separated stems only; connected, swashed or outlined glyphs
            // are outside this fallback's scope.
            guard intersections.count == 4 else { return nil }
            let widths = [intersections[1] - intersections[0], intersections[3] - intersections[2]]
            guard widths.allSatisfy({ $0 > bounds.width * 0.005 }),
                  intersections[2] - intersections[1] > bounds.width * 0.1 else { return nil }
            return widths
        }
        let interior = [CGFloat(0.2), 0.25, 0.3].compactMap { widths(at: $0) }
        guard interior.count == 3 else { return nil }
        let terminals = [CGFloat(0.005), 0.01, 0.02, 0.04, 0.06, 0.08].compactMap { widths(at: $0) }
        guard terminals.count >= 3 else { return nil }
        var ratios: [CGFloat] = []
        for stem in 0..<2 {
            let body = interior.map { $0[stem] }.sorted()[1]
            let end = terminals.map { $0[stem] }.max() ?? body
            ratios.append(end / body)
        }
        // Both stems must flare for a serif result; either flaring disqualifies
        // a sans result. In-between values remain unclassified.
        if ratios.allSatisfy({ $0 >= 1.5 }) { return ratios.min() }
        if ratios.allSatisfy({ $0 <= 1.12 }) { return ratios.max() }
        return 1.3
    }

    private static func containsAny(_ name: String, _ words: [String]) -> Bool {
        words.contains { name.contains($0) }
    }

    private static func category(forClass value: UInt32) -> FontCategory? {
        switch value {
        case 1...5, 7: .serif
        case 8: .sansSerif
        case 9: .display
        case 10: .script
        case 12: .symbols
        default: nil
        }
    }
}

