// Build with FontClassification.swift; run with --audit [--folder /path/to/fonts]
// to report metadata/outline coverage without activating or changing any font.
import CoreText
import Foundation

@main
struct FontClassificationTests {
    static func main() {
        func table(class familyClass: UInt8 = 0, kind: UInt8 = 0, serif: UInt8 = 0,
                   proportion: UInt8 = 0) -> Data {
            var bytes = [UInt8](repeating: 0, count: 78)
            bytes[30] = familyClass
            bytes[32] = kind
            bytes[33] = serif
            bytes[35] = proportion
            return Data(bytes)
        }
        func check(_ expected: FontCategory, _ names: [String] = ["Neutral Family"],
                   traits: UInt32 = 0, os2: Data? = nil) {
            let actual = FontClassifier.classify(names: names, symbolicTraits: traits, os2: os2)
            precondition(actual == expected, "\(names): expected \(expected), got \(actual)")
        }
        // Regressions in substring-only classification and unsupported values.
        check(.sansSerif, ["Example Sans Serif"])
        check(.sansSerif, ["ExampleSansSerif"])
        check(.unclassified, ["Monotype Example"])
        check(.unclassified, ["Monoton", "Serifless"])
        check(.monospaced, ["Example Mono"])
        check(.unclassified, os2: Data(repeating: 0, count: 31))
        check(.unclassified, os2: table(kind: 2, serif: 1))
        check(.unclassified, os2: table(kind: 2, serif: 16))
        check(.unclassified, os2: table(class: 6))

        for serif in UInt8(2)...10 { check(.serif, os2: table(kind: 2, serif: serif)) }
        for serif in UInt8(11)...15 { check(.sansSerif, os2: table(kind: 2, serif: serif)) }
        check(.monospaced, os2: table(kind: 2, serif: 2, proportion: 9))
        check(.script, os2: table(kind: 3, proportion: 9))
        check(.display, os2: table(kind: 4))
        check(.symbols, os2: table(kind: 5))
        check(.sansSerif, ["Misleading Serif Name"], os2: table(kind: 2, serif: 11))
        check(.serif, ["Misleading Sans Name"], os2: table(class: 3))
        check(.sansSerif, os2: table(class: 8, kind: 2, serif: 1))

        for value in UInt8(1)...5 { check(.serif, os2: table(class: value)) }
        check(.serif, os2: table(class: 7))
        check(.sansSerif, traits: UInt32(8) << 28)
        check(.serif, traits: UInt32(3) << 28)
        check(.display, traits: UInt32(9) << 28)
        check(.script, traits: UInt32(10) << 28)
        check(.symbols, traits: UInt32(12) << 28)
        check(.monospaced, traits: CTFontSymbolicTraits.traitMonoSpace.rawValue)

        // Localized names describe the CJK design, not its Latin companion.
        check(.serif, ["Example", "ヒラギノ明朝"], os2: table(kind: 2, serif: 11))
        check(.sansSerif, ["Example", "角ゴシック"], os2: table(kind: 2, serif: 2))
        check(.serif, ["思源宋體"])
        check(.sansSerif, ["思源黑体"])
        check(.script, ["毛筆楷書"])
        check(.serif, ["Noto Serif"])
        check(.sansSerif, ["Noto Sans"])
        check(.script, ["Example Brush"])
        check(.symbols, ["Example Dingbats"])
        check(.display, ["Example Fraktur"])

        precondition(FontClassifier.familyCategory([]) == .unclassified)
        precondition(FontClassifier.familyCategory([.unclassified, .serif, .serif, .sansSerif]) == .serif)
        precondition(FontClassifier.familyCategory([.serif, .sansSerif])
                     == FontClassifier.familyCategory([.sansSerif, .serif]))

        // Exercise the real Core Text table-reading path on system fonts.
        for (name, expected) in [("Times-Roman", FontCategory.serif), ("Helvetica", .sansSerif),
                                 ("Courier", .monospaced), ("Zapfino", .script), ("AppleSymbols", .symbols)] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            guard CTFontCopyPostScriptName(font) as String == name else { continue }
            let actual = FontClassifier.classify(font: font, family: CTFontCopyFamilyName(font) as String, localizedNames: [])
            precondition(actual == expected, "System font \(name): expected \(expected), got \(actual)")
            print("PASS: \(name) → \(actual.rawValue)")
        }
        for (name, expected) in [("Times-Roman", FontCategory.serif), ("Helvetica", .sansSerif),
                                 ("Georgia", .serif), ("Baskerville", .serif), ("Didot", .serif),
                                 ("ArialMT", .sansSerif), ("Futura-Medium", .sansSerif),
                                 ("Avenir-Roman", .sansSerif)] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            guard CTFontCopyPostScriptName(font) as String == name else { continue }
            let inferred = FontClassifier.outlineCategory(font: font)
            precondition(inferred == nil || inferred == expected,
                         "Outline of \(name): expected \(expected) or unknown, got \(String(describing: inferred))")
            if name == "Times-Roman" || name == "Helvetica" {
                precondition(inferred == expected, "Baseline outline recognition must work")
            }
        }
        print("PASS: OpenType/PANOSE/Core Text, CJK names, conservative fallback, family consensus")

        if CommandLine.arguments.contains("--audit") {
            let collection = CTFontCollectionCreateFromAvailableFonts(nil)
            var descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
            if let flag = CommandLine.arguments.firstIndex(of: "--folder"),
               CommandLine.arguments.indices.contains(flag + 1) {
                let root = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
                let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
                while let url = files?.nextObject() as? URL {
                    guard ["otf", "ttf", "ttc", "otc"].contains(url.pathExtension.lowercased()) else { continue }
                    descriptors += CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                }
            }
            var counts: [FontCategory: Int] = [:]
            var unknown: Set<String> = []
            var matchedOutlines = 0
            var mismatches: Set<String> = []
            for descriptor in descriptors {
                let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
                let name = CTFontCopyFamilyName(font) as String
                let category = FontClassifier.classify(font: font, family: name, localizedNames: [])
                let declared = FontClassifier.classify(
                    names: [name], symbolicTraits: CTFontGetSymbolicTraits(font).rawValue,
                    os2: CTFontCopyTable(font, 0x4F532F32, []).map { $0 as Data }
                )
                if (declared == .serif || declared == .sansSerif), let inferred = FontClassifier.outlineCategory(font: font) {
                    if declared == inferred { matchedOutlines += 1 }
                    else { mismatches.insert("\(name): \(declared.rawValue) → \(inferred.rawValue)") }
                }
                counts[category, default: 0] += 1
                if category == .unclassified { unknown.insert(name) }
            }
            for category in FontCategory.allCases { print("\(category.rawValue): \(counts[category, default: 0]) faces") }
            print("Outline audit: \(matchedOutlines) faces agree with metadata; conflicts: \(mismatches.sorted())")
            print("Unclassified examples: \(unknown.sorted().prefix(20).joined(separator: ", "))")
        }
    }
}
