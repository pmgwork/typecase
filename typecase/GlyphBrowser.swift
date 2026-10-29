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
        case .all: String(localized: "All")
        case .latin: String(localized: "Latin")
        case .kana: String(localized: "Kana")
        case .cjk: String(localized: "CJK")
        case .symbols: String(localized: "Symbols")
        case .other: String(localized: "Other")
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

    /// The block's characters that match `query`: a character it contains, a
    /// hexadecimal code point (`U+3042`, `0x3042`, or `3042`), or — from three
    /// letters on — part of the Unicode name.
    func codePoints(in block: GlyphBlock, matching query: String) -> [UInt32] {
        let codePoints = codePoints(in: block)
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return codePoints }

        let characters = Set(query.unicodeScalars.map(\.value))
        var hex = query.uppercased()
        for prefix in ["U+", "0X"] where hex.hasPrefix(prefix) {
            hex.removeFirst(prefix.count)
        }
        let codePoint = hex.count <= 6 ? UInt32(hex, radix: 16) : nil
        let name = query.count >= 3 ? query.uppercased() : nil

        return codePoints.filter { value in
            if characters.contains(value) || value == codePoint { return true }
            guard let name, let scalar = Unicode.Scalar(value) else { return false }
            return scalar.properties.name?.contains(name) == true
        }
    }
}

/// The identifier of the glyph window scene. The inspector's Browse Glyphs
/// button opens one window per family.
enum GlyphWindow {
    static let id = "glyphBrowser"
}

/// The glyph window's content: resolves the family it was opened for, which
/// can still be loading when the window is restored at launch.
struct GlyphBrowserWindow: View {
    @ObservedObject var catalog: FontCatalog
    let familyID: FontFamily.ID?

    var body: some View {
        if let family = catalog.families.first(where: { $0.id == familyID }) {
            GlyphBrowser(catalog: catalog, family: family)
        } else if catalog.families.isEmpty {
            ProgressView()
                .frame(minWidth: 860, minHeight: 560)
        } else {
            ContentUnavailableView(
                String(localized: "Font unavailable"),
                systemImage: "textformat",
                description: Text(String(localized: "The font is no longer in the library."))
            )
            .frame(minWidth: 860, minHeight: 560)
        }
    }
}

/// Every character a font can display, in a lazily drawn grid. Fonts that are
/// not activated are drawn straight from their files through `FontResolver`.
struct GlyphBrowser: View {
    let catalog: FontCatalog
    let family: FontFamily
    @State private var faceID: FontFace.ID?
    @State private var block: GlyphBlock = .all
    @State private var query = ""
    @State private var inventory: GlyphInventory?
    @State private var visibleCodePoints: [UInt32] = []
    @State private var selection: UInt32?
    @State private var gridWidth: CGFloat = 0

    private static let cellMinimumWidth: CGFloat = 68
    private static let cellHeight: CGFloat = 78
    private static let glyphSize: CGFloat = 30
    /// The size the detail specimen reads its outlines and metrics at; the
    /// canvas scales them to fit.
    private static let specimenSize: CGFloat = 100

    init(catalog: FontCatalog, family: FontFamily) {
        self.catalog = catalog
        self.family = family
        _faceID = State(initialValue: family.previewFace?.id)
    }

    private var face: FontFace? {
        family.faces.first { $0.id == faceID } ?? family.previewFace
    }

    private struct FilterKey: Hashable {
        let face: FontFace.ID?
        let block: GlyphBlock
        let query: String
        let isLoaded: Bool
    }

    var body: some View {
        HStack(spacing: 0) {
            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            detail
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle(family.name)
        .navigationSubtitle(summary)
        // The controls live in the window's own toolbar, where macOS draws
        // them as Liquid Glass over the glyphs scrolling beneath; the
        // toolbar's scroll edge effect keeps the title legible over them.
        .toolbar {
            ToolbarItem {
                Picker(String(localized: "Unicode Group"), selection: $block) {
                    ForEach(GlyphBlock.allCases) { block in
                        Text(block.title).tag(block)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if family.faces.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Picker(String(localized: "Style"), selection: $faceID) {
                        ForEach(family.faces) { face in
                            Text(face.styleName).tag(Optional(face.id))
                        }
                    }
                    .labelsHidden()
                    .help(String(localized: "Style"))
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: String(localized: "Character, U+, or name"))
        .task(id: face?.id) {
            guard let face else { return }
            inventory = nil
            selection = nil
            let loaded = await catalog.glyphInventory(for: face)
            guard !Task.isCancelled else { return }
            inventory = loaded
        }
        .task(id: FilterKey(face: face?.id, block: block, query: query, isLoaded: inventory != nil)) {
            guard let inventory else {
                visibleCodePoints = []
                return
            }
            // Matching Unicode names across a CJK font takes a moment, so it
            // runs off the main actor and is dropped when the query changes.
            let block = block, query = query
            let matches = await Task.detached(priority: .userInitiated) {
                inventory.codePoints(in: block, matching: query)
            }.value
            guard !Task.isCancelled else { return }
            visibleCodePoints = matches
            if let selection, !matches.contains(selection) {
                self.selection = nil
            }
        }
    }

    /// "Regular · 1,234 characters", or "12 of 1,234" while a search narrows it.
    private var summary: String {
        let style = face?.styleName ?? ""
        guard let inventory else { return style }
        let total = inventory.codePoints(in: block).count
        let count = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(localized: "\(total) characters")
            : String(localized: "\(visibleCodePoints.count) of \(total) characters")
        return style.isEmpty ? count : "\(style) · \(count)"
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        if inventory == nil {
            ProgressView()
        } else if visibleCodePoints.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(
                    String(localized: "No characters"),
                    systemImage: "character",
                    description: Text(String(localized: "This font has no characters in \(block.title)."))
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            let font = cellFont
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 0)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                    // LazyVGrid only builds the rows on screen, which keeps
                    // fonts with tens of thousands of glyphs responsive.
                    LazyVGrid(columns: gridColumns, spacing: 0) {
                        ForEach(visibleCodePoints, id: \.self) { codePoint in
                            GlyphCell(
                                codePoint: codePoint,
                                font: font,
                                height: Self.cellHeight,
                                isSelected: codePoint == selection
                            )
                            .equatable()
                            .onTapGesture { selection = codePoint }
                            .contextMenu { cellMenu(codePoint) }
                        }
                    }
                    // Each cell draws its trailing and bottom rules; the grid
                    // closes the outer leading and top edges.
                    .overlay(alignment: .top) { GlyphRule(axis: .horizontal) }
                    .overlay(alignment: .leading) { GlyphRule(axis: .vertical) }
                }
                .padding(16)
            }
            // Start each block and search from the top rather than the
            // previous offset.
            .id(FilterKey(face: face?.id, block: block, query: query, isLoaded: true))
        }
    }

    @ViewBuilder
    private func cellMenu(_ codePoint: UInt32) -> some View {
        if let scalar = Unicode.Scalar(codePoint) {
            Button(String(localized: "Copy Character")) { catalog.copyStrings([String(scalar)]) }
            Button(String(localized: "Copy Code Point")) { catalog.copyStrings([Self.codePointText(codePoint)]) }
            if let name = Self.unicodeName(scalar) {
                Button(String(localized: "Copy Unicode Name")) { catalog.copyStrings([name]) }
            }
        }
    }

    /// Whole-point column widths keep every rule on a device pixel; adaptive
    /// columns land on fractions and the hairlines blur away.
    private var gridColumns: [GridItem] {
        let available = max(gridWidth, Self.cellMinimumWidth)
        let count = max(1, Int(available / Self.cellMinimumWidth))
        let width = (available / CGFloat(count)).rounded(.down)
        return Array(repeating: GridItem(.fixed(width), spacing: 0), count: count)
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
            let ctFont = FontResolver.shared.nsFont(
                postScriptName: face.postScriptName,
                fileURL: face.fileURL,
                size: Self.specimenSize
            ) as CTFont
            let glyph = Self.glyph(for: character, in: ctFont)
            let name = Self.unicodeName(scalar)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlyphSpecimen(
                        character: character,
                        glyph: glyph?.id,
                        font: ctFont,
                        textFont: FontResolver.shared.previewFont(
                            postScriptName: face.postScriptName,
                            fileURL: face.fileURL,
                            size: 140
                        )
                    )
                    .frame(height: 260)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(name.map { Self.displayName($0) } ?? codePoint)
                            .font(.headline)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text(GlyphBlock.classify(selection).title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            detailField(String(localized: "Code Point"), codePoint, copy: codePoint)
                            detailField(String(localized: "Glyph ID"), glyph.map { "\($0.id)" } ?? "—", copy: nil)
                        }
                        GridRow {
                            detailField(String(localized: "Glyph Name"), glyph?.name ?? "—", copy: glyph?.name)
                            detailField(String(localized: "Advance"), glyph.map { "\($0.advance.formatted()) u" } ?? "—", copy: nil)
                        }
                    }
                    if let name {
                        detailField(String(localized: "Unicode Name"), name, copy: name)
                    }

                    Button {
                        catalog.copyStrings([character])
                    } label: {
                        Label(String(localized: "Copy Character"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                String(localized: "Select a glyph"),
                systemImage: "character.cursor.ibeam",
                description: Text(String(localized: "Its outline, metrics, and names appear here."))
            )
        }
    }

    /// A muted eyebrow label above its value, like the inspector's details.
    private func detailField(_ title: String, _ value: String, copy: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(value)
                if let copy {
                    Button {
                        catalog.copyStrings([copy])
                    } label: {
                        Label(String(localized: "Copy \(title)"), systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Copy the \(title)"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func codePointText(_ codePoint: UInt32) -> String {
        "U+" + String(format: "%04X", codePoint)
    }

    private static func unicodeName(_ scalar: Unicode.Scalar) -> String? {
        scalar.properties.name ?? scalar.properties.nameAlias
    }

    /// "LATIN CAPITAL LETTER A" as "Latin Capital Letter A".
    private static func displayName(_ name: String) -> String {
        name.lowercased().capitalized
    }

    /// The glyph the font's character map assigns to `character`, with its
    /// PostScript glyph name and advance width in font units.
    private static func glyph(for character: String, in font: CTFont) -> (id: CGGlyph, name: String?, advance: Int)? {
        let utf16 = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), glyphs[0] != 0 else {
            return nil
        }
        let graphicsFont = CTFontCopyGraphicsFont(font, nil)
        let name = graphicsFont.name(for: glyphs[0]).map { $0 as String }
        var glyph = glyphs[0]
        let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
        let unitsPerEm = CGFloat(CTFontGetUnitsPerEm(font))
        return (glyph, name, Int((advance * unitsPerEm / CTFontGetSize(font)).rounded()))
    }
}

/// One glyph of the grid with its code point underneath. Equatable so
/// scrolling and selection changes only redraw the cells whose state changed.
private struct GlyphCell: View, Equatable {
    let codePoint: UInt32
    let font: Font
    let height: CGFloat
    let isSelected: Bool
    @State private var isHovered = false

    static func == (lhs: GlyphCell, rhs: GlyphCell) -> Bool {
        lhs.codePoint == rhs.codePoint && lhs.font == rhs.font
            && lhs.height == rhs.height && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(Unicode.Scalar(codePoint).map { String($0) } ?? "")
                .font(font)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            Text(String(format: "%04X", codePoint))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                .padding(.bottom, 6)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .frame(height: height)
        .background(background)
        .overlay(alignment: .trailing) { GlyphRule(axis: .vertical) }
        .overlay(alignment: .bottom) { GlyphRule(axis: .horizontal) }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return isHovered ? .primary.opacity(0.07) : .clear
    }
}

/// A one-pixel rule of the glyph grid.
private struct GlyphRule: View {
    let axis: Axis
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let width = 1 / displayScale
        Rectangle()
            .fill(.primary.opacity(0.14))
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
    }
}

/// The selected glyph's outline on its metric lines: ascender, cap height,
/// x-height, baseline, and descender, with the advance width as side bearings.
private struct GlyphSpecimen: View {
    let character: String
    let glyph: CGGlyph?
    let font: CTFont
    /// Draws glyphs without an outline, such as color emoji.
    let textFont: Font

    private struct Metric {
        let title: String
        let value: CGFloat
    }

    var body: some View {
        Canvas { context, size in
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            let metrics = [
                Metric(title: String(localized: "Ascender"), value: ascent),
                Metric(title: String(localized: "Cap Height"), value: CTFontGetCapHeight(font)),
                Metric(title: String(localized: "x-Height"), value: CTFontGetXHeight(font)),
                Metric(title: String(localized: "Baseline"), value: 0),
                Metric(title: String(localized: "Descender"), value: -descent),
            ].filter { $0.title == String(localized: "Baseline") || $0.value != 0 }

            var advance: CGFloat = 0
            var bounds = CGRect.zero
            if var glyph {
                advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
                bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
            }

            // Fit the em box and any overshoot of the outline.
            let top = max(ascent, bounds.maxY)
            let bottom = min(-descent, bounds.minY)
            let left = min(0, bounds.minX)
            let right = max(advance, bounds.maxX)
            let inset = CGSize(width: 28, height: 20)
            let scale = min(
                (size.height - inset.height * 2) / max(top - bottom, 1),
                (size.width - inset.width * 2) / max(right - left, 1)
            )
            let baseline = (size.height - (top - bottom) * scale) / 2 + top * scale
            let origin = (size.width - (right - left) * scale) / 2 - left * scale

            var lastLabelY = -CGFloat.infinity
            for metric in metrics.sorted(by: { $0.value > $1.value }) {
                let y = (baseline - metric.value * scale).rounded() + 0.5
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                let isBaseline = metric.value == 0
                context.stroke(
                    line,
                    with: .color(isBaseline ? .accentColor.opacity(0.7) : .secondary.opacity(0.3)),
                    lineWidth: isBaseline ? 1 : 0.5
                )
                // Skip labels that would collide with the one above.
                guard y - lastLabelY > 11 else { continue }
                lastLabelY = y
                context.draw(
                    Text(metric.title).font(.system(size: 9)).foregroundStyle(.secondary),
                    at: CGPoint(x: 6, y: y - 2),
                    anchor: .bottomLeading
                )
            }

            if glyph != nil {
                for x in [origin, origin + advance * scale] {
                    var line = Path()
                    let x = x.rounded() + 0.5
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        line,
                        with: .color(.secondary.opacity(0.3)),
                        style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                    )
                }
            }

            if let glyph, let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                let transform = CGAffineTransform(translationX: origin, y: baseline)
                    .scaledBy(x: scale, y: -scale)
                context.fill(Path(outline).applying(transform), with: .color(.primary))
            } else {
                context.draw(
                    Text(character).font(textFont),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
            }
        }
        .accessibilityLabel(Text(character))
    }
}
