import AppKit
import CoreGraphics
import CoreText
import SwiftUI

/// The script groups the glyph browser filters by. Ranges follow the Unicode
/// blocks of each group; anything outside them falls under `other`.
nonisolated enum GlyphBlock: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case latin
    case kana
    case cjk
    case symbols
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .latin: "Latin"
        case .kana: "Kana"
        case .cjk: "CJK Ideographs"
        case .symbols: "Symbols"
        case .other: "Other"
        }
    }

    /// Basic Latin through Latin Extended-B, IPA and spacing modifiers,
    /// Latin Extended Additional, -C, -D, -E, and the Latin ligatures.
    private static let latinRanges: [ClosedRange<UInt32>] = [
        0x0020...0x02FF, 0x1E00...0x1EFF, 0x2C60...0x2C7F,
        0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06,
    ]

    /// Hiragana, Katakana, Katakana Phonetic Extensions, halfwidth katakana,
    /// and the historic kana supplements.
    private static let kanaRanges: [ClosedRange<UInt32>] = [
        0x3040...0x30FF, 0x31F0...0x31FF, 0xFF65...0xFF9F, 0x1B000...0x1B16F,
    ]

    /// CJK Unified Ideographs with every extension, the compatibility
    /// ideographs, and the radicals.
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x2E80...0x2FDF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
        0x20000...0x2FA1F, 0x30000...0x323AF,
    ]

    /// Punctuation and symbol blocks: General Punctuation through
    /// Miscellaneous Symbols and Arrows, CJK Symbols and Punctuation,
    /// enclosed CJK and CJK Compatibility, the vertical and fullwidth forms,
    /// and the emoji and pictograph planes.
    private static let symbolRanges: [ClosedRange<UInt32>] = [
        0x2000...0x2BFF, 0x3000...0x303F, 0x3200...0x33FF, 0xFE10...0xFE1F,
        0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x1F000...0x1FBFF,
    ]

    /// The group a code point belongs to; never `all`. Kana is checked first so
    /// halfwidth katakana stay out of the fullwidth forms counted as symbols.
    static func classify(_ codePoint: UInt32) -> GlyphBlock {
        if kanaRanges.contains(where: { $0.contains(codePoint) }) { return .kana }
        if cjkRanges.contains(where: { $0.contains(codePoint) }) { return .cjk }
        if latinRanges.contains(where: { $0.contains(codePoint) }) { return .latin }
        if symbolRanges.contains(where: { $0.contains(codePoint) }) { return .symbols }
        return .other
    }
}

/// A face's drawable characters, grouped by `GlyphBlock`.
nonisolated struct GlyphInventory: Sendable {
    private let all: [UInt32]
    private let byBlock: [GlyphBlock: [UInt32]]

    /// Control and format characters map to empty glyphs, so they are left
    /// out of the grid.
    init(codePoints: [UInt32]) {
        var all: [UInt32] = []
        all.reserveCapacity(codePoints.count)
        var byBlock: [GlyphBlock: [UInt32]] = [:]
        for codePoint in codePoints {
            guard let scalar = Unicode.Scalar(codePoint) else { continue }
            let category = scalar.properties.generalCategory
            guard category != .control, category != .format else { continue }
            all.append(codePoint)
            byBlock[GlyphBlock.classify(codePoint), default: []].append(codePoint)
        }
        self.all = all
        self.byBlock = byBlock
    }

    func codePoints(in block: GlyphBlock) -> [UInt32] {
        block == .all ? all : byBlock[block] ?? []
    }
}

/// Every character a font can display, in a lazily drawn grid. Fonts that are
/// not activated are drawn straight from their files through `FontResolver`.
struct GlyphBrowser: View {
    let catalog: FontCatalog
    let family: FontFamily
    @Environment(\.dismiss) private var dismiss
    @State private var faceID: FontFace.ID?
    @State private var block: GlyphBlock = .all
    @State private var inventory: GlyphInventory?
    @State private var selection: UInt32?

    private static let cellSize: CGFloat = 56
    private static let glyphSize: CGFloat = 30
    private static let detailGlyphSize: CGFloat = 120

    init(catalog: FontCatalog, family: FontFamily) {
        self.catalog = catalog
        self.family = family
        _faceID = State(initialValue: family.previewFace?.id)
    }

    private var face: FontFace? {
        family.faces.first { $0.id == faceID } ?? family.previewFace
    }

    private var visibleCodePoints: [UInt32] {
        inventory?.codePoints(in: block) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            HStack(spacing: 0) {
                grid
                Divider()
                detail
                    .frame(width: 260)
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .task(id: face?.id) {
            guard let face else { return }
            inventory = nil
            selection = nil
            let loaded = await catalog.glyphInventory(for: face)
            guard !Task.isCancelled else { return }
            inventory = loaded
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Glyphs: \(family.name)")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if family.faces.count > 1 {
                    Picker("Style", selection: $faceID) {
                        ForEach(family.faces) { face in
                            Text(face.styleName).tag(Optional(face.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                Picker("Unicode Block", selection: $block) {
                    ForEach(GlyphBlock.allCases) { block in
                        Text(block.title).tag(block)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if inventory != nil {
                    Text("\(visibleCodePoints.count.formatted()) characters")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if inventory == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleCodePoints.isEmpty {
            ContentUnavailableView(
                "No characters",
                systemImage: "character",
                description: Text("This font has no characters in \(block.title).")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let font = cellFont
            ScrollView {
                // LazyVGrid only builds the rows on screen, which keeps fonts
                // with tens of thousands of glyphs responsive.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.cellSize, maximum: Self.cellSize + 16), spacing: 4)],
                    spacing: 4
                ) {
                    ForEach(visibleCodePoints, id: \.self) { codePoint in
                        GlyphCell(
                            codePoint: codePoint,
                            font: font,
                            size: Self.cellSize,
                            isSelected: codePoint == selection
                        )
                        .equatable()
                        .onTapGesture { selection = codePoint }
                    }
                }
                .padding(12)
            }
            // Start each block from its top rather than the previous offset.
            .id(block)
        }
    }

    private var cellFont: Font {
        FontResolver.shared.previewFont(
            postScriptName: face?.postScriptName,
            fileURL: face?.fileURL,
            size: Self.glyphSize
        )
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let scalar = Unicode.Scalar(selection), let face {
            let character = String(scalar)
            let codePoint = Self.codePointText(selection)
            let glyph = Self.glyph(for: character, in: FontResolver.shared.nsFont(
                postScriptName: face.postScriptName,
                fileURL: face.fileURL,
                size: Self.detailGlyphSize
            ))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(character)
                        .font(FontResolver.shared.previewFont(
                            postScriptName: face.postScriptName,
                            fileURL: face.fileURL,
                            size: Self.detailGlyphSize
                        ))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                    detailRow("Code Point", codePoint, copy: codePoint)
                    detailRow("Unicode Name", Self.unicodeName(scalar) ?? "—", copy: Self.unicodeName(scalar))
                    detailRow("Glyph Name", glyph?.name ?? "—", copy: glyph?.name)
                    if let glyph {
                        detailRow("Glyph ID", "\(glyph.id)", copy: nil)
                    }

                    Button {
                        catalog.copyStrings([character])
                    } label: {
                        Label("Copy Character", systemImage: "doc.on.doc")
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                "Select a glyph",
                systemImage: "character.cursor.ibeam",
                description: Text("Its code point and glyph name appear here.")
            )
        }
    }

    private func detailRow(_ title: String, _ value: String, copy: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .help(value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let copy {
                Button {
                    catalog.copyStrings([copy])
                } label: {
                    Label("Copy \(title)", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy the \(title.lowercased())")
            }
        }
    }

    private static func codePointText(_ codePoint: UInt32) -> String {
        "U+" + String(format: "%04X", codePoint)
    }

    private static func unicodeName(_ scalar: Unicode.Scalar) -> String? {
        scalar.properties.name ?? scalar.properties.nameAlias
    }

    /// The glyph the font's character map assigns to `character`, with its
    /// PostScript glyph name when the font carries one.
    private static func glyph(for character: String, in font: NSFont) -> (id: CGGlyph, name: String?)? {
        let ctFont = font as CTFont
        let utf16 = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count), glyphs[0] != 0 else {
            return nil
        }
        let graphicsFont = CTFontCopyGraphicsFont(ctFont, nil)
        let name = graphicsFont.name(for: glyphs[0]).map { $0 as String }
        return (glyphs[0], name)
    }
}

/// One glyph of the grid. Equatable so scrolling and selection changes only
/// redraw the cells whose state changed.
private struct GlyphCell: View, Equatable {
    let codePoint: UInt32
    let font: Font
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        Text(Unicode.Scalar(codePoint).map { String($0) } ?? "")
            .font(font)
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .clipped()
            .background(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .help("U+" + String(format: "%04X", codePoint))
    }
}
