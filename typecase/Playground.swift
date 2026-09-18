import Combine
import Foundation
import SwiftUI

/// The identifier of the PlayGround window scene. The library's toolbar button
/// and the File menu both open the same window.
enum PlaygroundWindow {
    static let id = "playground"
}

/// The ranges the PlayGround's controls offer. The sliders and the stored
/// model share them, so a stored layout can never carry a value its own
/// controls cannot show.
nonisolated enum PlaygroundMetrics {
    static let sizeRange: ClosedRange<Double> = 8...200
    static let lineHeightRange: ClosedRange<Double> = 1...2.5
    static let trackingRange: ClosedRange<Double> = -5...20

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// How a block's text aligns in the canvas.
nonisolated enum PlaygroundAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        }
    }

    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// One text block of a PlayGround layout: its text, the style it is set in,
/// and the typographic controls of the inspector.
nonisolated struct PlaygroundBlock: Identifiable, Codable, Equatable, Sendable {
    static let defaultSize: Double = 20
    static let defaultLineHeight: Double = 1.4

    var id: UUID
    /// The block's text. Empty text follows the family's language sample, the
    /// same way an empty preview text does in the library.
    var text: String
    /// The family the block is set in; `nil` keeps the system font.
    var familyID: FontFamily.ID?
    /// The PostScript name of the chosen style; `nil` follows the family's
    /// preview style.
    var faceName: FontFace.ID?
    var size: Double
    /// Line height as a multiple of the font size; 1 keeps the font's own
    /// leading.
    var lineHeight: Double
    /// Letter spacing in points; 0 keeps the font's own spacing.
    var tracking: Double
    var alignment: PlaygroundAlignment

    init(
        id: UUID = UUID(),
        text: String = "",
        familyID: FontFamily.ID? = nil,
        faceName: FontFace.ID? = nil,
        size: Double = PlaygroundBlock.defaultSize,
        lineHeight: Double = PlaygroundBlock.defaultLineHeight,
        tracking: Double = 0,
        alignment: PlaygroundAlignment = .leading
    ) {
        self.id = id
        self.text = text
        self.familyID = familyID
        self.faceName = faceName
        self.size = size
        self.lineHeight = lineHeight
        self.tracking = tracking
        self.alignment = alignment
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, familyID, faceName, size, lineHeight, tracking, alignment
    }

    /// Decodes with per-field defaults and clamps the numbers into the ranges
    /// the inspector can show, so a layout written by an older or newer build
    /// still opens.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        familyID = try container.decodeIfPresent(String.self, forKey: .familyID)
        faceName = try container.decodeIfPresent(String.self, forKey: .faceName)
        size = PlaygroundMetrics.clamp(
            try container.decodeIfPresent(Double.self, forKey: .size) ?? Self.defaultSize,
            to: PlaygroundMetrics.sizeRange
        )
        lineHeight = PlaygroundMetrics.clamp(
            try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? Self.defaultLineHeight,
            to: PlaygroundMetrics.lineHeightRange
        )
        tracking = PlaygroundMetrics.clamp(
            try container.decodeIfPresent(Double.self, forKey: .tracking) ?? 0,
            to: PlaygroundMetrics.trackingRange
        )
        alignment = (try? container.decode(PlaygroundAlignment.self, forKey: .alignment)) ?? .leading
    }
}

/// A named PlayGround page: an ordered list of text blocks.
nonisolated struct PlaygroundLayout: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var blocks: [PlaygroundBlock]

    init(id: UUID = UUID(), name: String, blocks: [PlaygroundBlock]) {
        self.id = id
        self.name = name
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        blocks = try container.decodeIfPresent([PlaygroundBlock].self, forKey: .blocks) ?? []
    }
}

/// The PlayGround's layouts and the current selection, shared by the library
/// window and the PlayGround window and persisted in `UserDefaults` as JSON.
///
/// The catalog owns the fonts; a layout only stores the family and style names
/// it references, so a layout survives fonts being installed or removed and
/// falls back to the system font while a referenced font is missing.
@MainActor
final class PlaygroundStore: ObservableObject {
    @Published private(set) var layouts: [PlaygroundLayout]
    @Published private(set) var currentLayoutID: PlaygroundLayout.ID
    @Published var selectedBlockID: PlaygroundBlock.ID?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.loadLayouts(defaults: defaults)
        let loaded = stored.isEmpty ? [Self.starterLayout()] : stored
        layouts = loaded
        let storedID = defaults.string(forKey: Key.currentLayout).flatMap(UUID.init(uuidString:))
        currentLayoutID = storedID.flatMap { id in
            loaded.contains { $0.id == id } ? id : nil
        } ?? loaded[0].id
        selectedBlockID = loaded.first { $0.id == currentLayoutID }?.blocks.first?.id
    }

    // MARK: - Reading

    var currentLayout: PlaygroundLayout {
        layouts.first { $0.id == currentLayoutID } ?? layouts[0]
    }

    func block(id: PlaygroundBlock.ID) -> PlaygroundBlock? {
        currentLayout.blocks.first { $0.id == id }
    }

    /// The block the canvas highlights and the inspector edits.
    var selectedBlock: PlaygroundBlock? {
        selectedBlockID.flatMap { block(id: $0) }
    }

    // MARK: - Blocks

    /// Adds a body block that continues the selected block's font, so a layout
    /// grows in one family before another font is chosen.
    func addBlock() {
        var block = PlaygroundBlock()
        if let selected = selectedBlock {
            block.familyID = selected.familyID
            block.faceName = selected.faceName
            block.alignment = selected.alignment
        }
        addBlock(block)
    }

    func addBlock(_ block: PlaygroundBlock) {
        mutateCurrentLayout { $0.blocks.append(block) }
        selectedBlockID = block.id
    }

    /// Replaces the block with the same id, which is how every inspector
    /// control writes.
    func update(_ block: PlaygroundBlock) {
        mutateCurrentLayout { layout in
            guard let index = layout.blocks.firstIndex(where: { $0.id == block.id }) else { return }
            layout.blocks[index] = block
        }
    }

    func removeBlock(_ id: PlaygroundBlock.ID) {
        guard let index = currentLayout.blocks.firstIndex(where: { $0.id == id }) else { return }
        mutateCurrentLayout { $0.blocks.remove(at: index) }
        let remaining = currentLayout.blocks
        selectedBlockID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    func duplicateBlock(_ id: PlaygroundBlock.ID) {
        guard let index = currentLayout.blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = currentLayout.blocks[index]
        copy.id = UUID()
        mutateCurrentLayout { $0.blocks.insert(copy, at: index + 1) }
        selectedBlockID = copy.id
    }

    func moveBlocks(from offsets: IndexSet, to destination: Int) {
        mutateCurrentLayout { $0.blocks.move(fromOffsets: offsets, toOffset: destination) }
    }

    func moveBlock(_ id: PlaygroundBlock.ID, by offset: Int) {
        guard let index = currentLayout.blocks.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard currentLayout.blocks.indices.contains(destination) else { return }
        mutateCurrentLayout { $0.blocks.swapAt(index, destination) }
    }

    // MARK: - Library integration

    /// Adds the given families to the current layout and selects the last one.
    /// A family that already has a block is selected instead of added, and an
    /// empty preview text leaves the block empty so it follows the family's
    /// language sample.
    func use(_ families: [FontFamily], text: String, size: Double) {
        guard !families.isEmpty else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var target: PlaygroundBlock.ID?
        for family in families {
            if let existing = currentLayout.blocks.first(where: { $0.familyID == family.id }) {
                target = existing.id
                continue
            }
            var block = PlaygroundBlock()
            block.familyID = family.id
            block.faceName = family.previewFace?.postScriptName
            block.text = typed.isEmpty ? "" : text
            block.size = PlaygroundMetrics.clamp(size, to: PlaygroundMetrics.sizeRange)
            addBlock(block)
            target = block.id
        }
        if let target {
            selectedBlockID = target
        }
    }

    // MARK: - Layouts

    func selectLayout(_ id: PlaygroundLayout.ID) {
        guard id != currentLayoutID, layouts.contains(where: { $0.id == id }) else { return }
        currentLayoutID = id
        defaults.set(id.uuidString, forKey: Key.currentLayout)
        selectedBlockID = currentLayout.blocks.first?.id
    }

    func addLayout() {
        let layout = Self.starterLayout(name: uniqueName(basedOn: "Untitled"))
        layouts.append(layout)
        persistLayouts()
        selectLayout(layout.id)
    }

    func duplicateCurrentLayout() {
        var copy = currentLayout
        copy.id = UUID()
        copy.name = uniqueName(basedOn: "\(currentLayout.name) Copy")
        copy.blocks = copy.blocks.map { block in
            var block = block
            block.id = UUID()
            return block
        }
        layouts.append(copy)
        persistLayouts()
        selectLayout(copy.id)
    }

    func renameCurrentLayout(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateCurrentLayout { $0.name = trimmed }
    }

    /// Removes the current layout. The last layout stays, so the window always
    /// has a page to show.
    func deleteCurrentLayout() {
        guard layouts.count > 1 else { return }
        layouts.removeAll { $0.id == currentLayoutID }
        persistLayouts()
        currentLayoutID = layouts[0].id
        defaults.set(currentLayoutID.uuidString, forKey: Key.currentLayout)
        selectedBlockID = currentLayout.blocks.first?.id
    }

    // MARK: - Storage

    private func mutateCurrentLayout(_ mutate: (inout PlaygroundLayout) -> Void) {
        guard let index = layouts.firstIndex(where: { $0.id == currentLayoutID }) else { return }
        var layout = layouts[index]
        mutate(&layout)
        layouts[index] = layout
        persistLayouts()
    }

    private func persistLayouts() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        defaults.set(data, forKey: Key.layouts)
    }

    private static func loadLayouts(defaults: UserDefaults) -> [PlaygroundLayout] {
        guard let data = defaults.data(forKey: Key.layouts),
              let layouts = try? JSONDecoder().decode([PlaygroundLayout].self, from: data) else { return [] }
        return layouts
    }

    /// A name that no other layout uses, so the menu never lists two entries
    /// with the same label.
    private func uniqueName(basedOn base: String) -> String {
        let existing = Set(layouts.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// The page a fresh install starts with: a heading, a body block that
    /// follows the font's language sample, and a Japanese line.
    private static func starterLayout(name: String = "Untitled") -> PlaygroundLayout {
        PlaygroundLayout(name: name, blocks: [
            PlaygroundBlock(text: "PlayGround", size: 56, lineHeight: 1.1, tracking: -1),
            PlaygroundBlock(size: 20, lineHeight: 1.5),
            PlaygroundBlock(
                text: FontLanguage.japanese.sampleDefault,
                size: 14,
                lineHeight: 1.7
            ),
        ])
    }

    private enum Key {
        static let layouts = "playgroundLayouts"
        static let currentLayout = "playgroundCurrentLayout"
    }
}
