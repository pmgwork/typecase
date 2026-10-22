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

/// A block's place in the page hierarchy. The role supplies starting
/// typography and spacing; its individual controls remain editable afterward.
nonisolated enum PlaygroundBlockRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case h1, h2, h3
    case paragraph = "p"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h1: "H1"
        case .h2: "H2"
        case .h3: "H3"
        case .paragraph: "p"
        }
    }

    var description: String {
        switch self {
        case .h1: String(localized: "Heading 1")
        case .h2: String(localized: "Heading 2")
        case .h3: String(localized: "Heading 3")
        case .paragraph: String(localized: "Paragraph")
        }
    }

    var size: Double {
        switch self {
        case .h1: 56
        case .h2: 36
        case .h3: 26
        case .paragraph: 20
        }
    }

    var lineHeight: Double {
        switch self {
        case .h1: 1.1
        case .h2: 1.2
        case .h3: 1.3
        case .paragraph: 1.5
        }
    }

    var tracking: Double {
        switch self {
        case .h1: -1
        case .h2: -0.5
        case .h3, .paragraph: 0
        }
    }

    var topSpacing: CGFloat {
        switch self {
        case .h1: 28
        case .h2: 22
        case .h3: 16
        case .paragraph: 8
        }
    }

    var bottomSpacing: CGFloat {
        switch self {
        case .h1: 18
        case .h2: 12
        case .h3: 8
        case .paragraph: 10
        }
    }

    /// Earlier saved layouts had no role. Infer one without changing the
    /// user's existing size, tracking, or line height values.
    static func inferred(from size: Double) -> Self {
        if size >= 48 { return .h1 }
        if size >= 32 { return .h2 }
        if size >= 24 { return .h3 }
        return .paragraph
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
        case .leading: String(localized: "Left")
        case .center: String(localized: "Center")
        case .trailing: String(localized: "Right")
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
    /// The block's text; empty shows a language sample as an editable placeholder.
    var text: String
    /// The family the block is set in; `nil` keeps the system font.
    var familyID: FontFamily.ID?
    /// The PostScript name of the chosen style; `nil` follows the family's
    /// preview style.
    var faceName: FontFace.ID?
    var role: PlaygroundBlockRole
    var size: Double
    /// Line height as a multiple of the font size; 1 keeps the font's own
    /// leading.
    var lineHeight: Double
    /// Letter spacing in points; 0 keeps the font's own spacing.
    var tracking: Double
    var alignment: PlaygroundAlignment
    /// OpenType feature overrides and the Japanese–Latin space.
    var typesetting: TypesettingOptions

    init(
        id: UUID = UUID(),
        text: String = "",
        familyID: FontFamily.ID? = nil,
        faceName: FontFace.ID? = nil,
        role: PlaygroundBlockRole = .paragraph,
        size: Double? = nil,
        lineHeight: Double? = nil,
        tracking: Double? = nil,
        alignment: PlaygroundAlignment = .leading,
        typesetting: TypesettingOptions = TypesettingOptions()
    ) {
        self.id = id
        self.text = text
        self.familyID = familyID
        self.faceName = faceName
        self.role = role
        self.size = size ?? role.size
        self.lineHeight = lineHeight ?? role.lineHeight
        self.tracking = tracking ?? role.tracking
        self.alignment = alignment
        self.typesetting = typesetting
    }

    mutating func applyRole(_ newRole: PlaygroundBlockRole) {
        guard role != newRole else { return }
        role = newRole
        resetTypographyToRole()
    }

    /// Whether size, line height, and tracking still carry the role's values.
    var usesRoleTypography: Bool {
        size == role.size && lineHeight == role.lineHeight && tracking == role.tracking
    }

    /// Returns size, line height, and tracking to the role's starting values.
    mutating func resetTypographyToRole() {
        size = role.size
        lineHeight = role.lineHeight
        tracking = role.tracking
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, familyID, faceName, role, size, lineHeight, tracking, alignment, typesetting
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
        role = (try? container.decodeIfPresent(PlaygroundBlockRole.self, forKey: .role))
            ?? PlaygroundBlockRole.inferred(from: size)
        alignment = (try? container.decode(PlaygroundAlignment.self, forKey: .alignment)) ?? .leading
        typesetting = (try? container.decodeIfPresent(TypesettingOptions.self, forKey: .typesetting))
            ?? TypesettingOptions()
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
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "Untitled")
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
        let loaded = stored.isEmpty ? [Self.starterLayout()] : stored.map(Self.migrateStarterLayout)
        layouts = loaded
        let storedID = defaults.string(forKey: Key.currentLayout).flatMap(UUID.init(uuidString:))
        currentLayoutID = storedID.flatMap { id in
            loaded.contains { $0.id == id } ? id : nil
        } ?? loaded[0].id
        selectedBlockID = loaded.first { $0.id == currentLayoutID }?.blocks.first?.id

        // An earlier release changed only newly created pages. Give the open
        // page the blank four-element canvas and keep its contents as a copy.
        if !defaults.bool(forKey: Key.typeScaleApplied) {
            if let index = layouts.firstIndex(where: { $0.id == currentLayoutID }),
               !Self.isTypeScale(layouts[index]) {
                let original = layouts[index]
                var previous = original
                previous.id = UUID()
                previous.name = uniqueName(basedOn: String(localized: "\(original.name) Previous"))

                var scale = Self.starterLayout(name: original.name)
                scale.id = original.id
                layouts[index] = scale
                layouts.append(previous)
                selectedBlockID = scale.blocks.first?.id
            }
            defaults.set(true, forKey: Key.typeScaleApplied)
        }
        if layouts != stored, !stored.isEmpty {
            persistLayouts()
        }
    }

    // MARK: - Reading

    var currentLayout: PlaygroundLayout {
        layouts.first { $0.id == currentLayoutID } ?? layouts[0]
    }

    func block(id: PlaygroundBlock.ID) -> PlaygroundBlock? {
        currentLayout.blocks.first { $0.id == id }
    }

    /// The block the inspector edits.
    var selectedBlock: PlaygroundBlock? {
        selectedBlockID.flatMap { block(id: $0) }
    }

    // MARK: - Blocks

    /// Inserts a role below the current block and continues its font,
    /// alignment, and typesetting. A new page starts with a paragraph if none is selected.
    func addBlock(role: PlaygroundBlockRole = .paragraph) {
        var block = PlaygroundBlock(role: role)
        if let selected = selectedBlock {
            block.familyID = selected.familyID
            block.faceName = selected.faceName
            block.alignment = selected.alignment
            block.typesetting = selected.typesetting
        }
        if let selectedBlockID,
           let index = currentLayout.blocks.firstIndex(where: { $0.id == selectedBlockID }) {
            mutateCurrentLayout { $0.blocks.insert(block, at: index + 1) }
            self.selectedBlockID = block.id
        } else {
            addBlock(block)
        }
    }

    func addBlock(_ block: PlaygroundBlock) {
        mutateCurrentLayout { $0.blocks.append(block) }
        selectedBlockID = block.id
    }

    /// Assign Hiragino once the asynchronous font catalog becomes available.
    /// Fill only unconfigured blocks of the blank starter scale: a font chosen
    /// for one block must not leave the other three on the system font.
    func setStarterFontIfNeeded(_ reference: FontFaceReference) {
        guard Self.isTypeScale(currentLayout),
              currentLayout.blocks.contains(where: { $0.text.isEmpty && $0.familyID == nil && $0.faceName == nil })
        else { return }
        mutateCurrentLayout { layout in
            for index in layout.blocks.indices where layout.blocks[index].text.isEmpty &&
                layout.blocks[index].familyID == nil && layout.blocks[index].faceName == nil {
                layout.blocks[index].familyID = reference.familyID
                layout.blocks[index].faceName = reference.postScriptName
            }
        }
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
    /// empty preview text leaves the block on its language sample placeholder.
    func use(_ families: [FontFamily], text: String, size: Double) {
        guard !families.isEmpty else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var target: PlaygroundBlock.ID?
        for family in families {
            if let existing = currentLayout.blocks.first(where: { $0.familyID == family.id }) {
                target = existing.id
                continue
            }
            var block = PlaygroundBlock(role: .inferred(from: size))
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
        let layout = Self.starterLayout(name: uniqueName(basedOn: String(localized: "Untitled")))
        layouts.append(layout)
        persistLayouts()
        selectLayout(layout.id)
    }

    func duplicateCurrentLayout() {
        var copy = currentLayout
        copy.id = UUID()
        copy.name = uniqueName(basedOn: String(localized: "\(currentLayout.name) Copy"))
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

    /// The four text fields start without saved text. The canvas shows their
    /// role labels and language sample placeholders until the user types.
    private static func starterLayout(name: String = String(localized: "Untitled")) -> PlaygroundLayout {
        PlaygroundLayout(name: name, blocks: [
            PlaygroundBlock(role: .h1),
            PlaygroundBlock(role: .h2),
            PlaygroundBlock(role: .h3),
            PlaygroundBlock(role: .paragraph),
        ])
    }

    private static func isTypeScale(_ layout: PlaygroundLayout) -> Bool {
        let roles = PlaygroundBlockRole.allCases
        let labels = ["H1", "H2", "H3", "p"]
        return layout.blocks.count == roles.count &&
            zip(layout.blocks, zip(roles, labels)).allSatisfy { block, expected in
                block.role == expected.0 && (block.text.isEmpty || block.text == expected.1)
            }
    }

    /// Change only untouched starter pages from previous versions. In
    /// particular, a page with edited text or a chosen font remains the user's
    /// page, even when its blocks still happen to have the starter roles.
    private static func migrateStarterLayout(_ layout: PlaygroundLayout) -> PlaygroundLayout {
        // The last starter version stored its role labels as editable text and
        // copied fonts from the old page. Move the labels outside the editor.
        if isTypeScale(layout),
           layout.blocks.map(\.text) == ["H1", "H2", "H3", "p"] {
            var result = layout
            for index in result.blocks.indices {
                result.blocks[index].text = ""
                result.blocks[index].familyID = nil
                result.blocks[index].faceName = nil
            }
            return result
        }

        let previousFour = ["PlayGround", String(localized: "Typography"), "文字組み", ""]
        let fourRoles = PlaygroundBlockRole.allCases
        let matchesFour = layout.blocks.count == fourRoles.count &&
            zip(layout.blocks, zip(fourRoles, previousFour)).allSatisfy { block, expected in
                isUntouched(block, role: expected.0, text: expected.1)
            }
        if matchesFour {
            var result = layout
            for index in result.blocks.indices { result.blocks[index].text = "" }
            return result
        }

        let previousThree: [(PlaygroundBlockRole, String, Double, Double, Double)] = [
            (.h1, "PlayGround", 56, 1.1, -1),
            (.paragraph, "", 20, 1.5, 0),
            (.paragraph, FontLanguage.japanese.sampleDefault, 14, 1.7, 0),
        ]
        let matchesThree = layout.blocks.count == previousThree.count &&
            zip(layout.blocks, previousThree).allSatisfy { block, expected in
                isUntouched(block, role: expected.0, text: expected.1,
                            size: expected.2, lineHeight: expected.3, tracking: expected.4)
            }
        guard matchesThree else { return layout }

        var result = starterLayout(name: layout.name)
        result.id = layout.id
        for index in layout.blocks.indices {
            result.blocks[index].id = layout.blocks[index].id
        }
        return result
    }

    private static func isUntouched(
        _ block: PlaygroundBlock,
        role: PlaygroundBlockRole,
        text: String,
        size: Double? = nil,
        lineHeight: Double? = nil,
        tracking: Double? = nil
    ) -> Bool {
        block.role == role && block.text == text &&
            block.familyID == nil && block.faceName == nil &&
            block.size == (size ?? role.size) &&
            block.lineHeight == (lineHeight ?? role.lineHeight) &&
            block.tracking == (tracking ?? role.tracking) &&
            block.alignment == .leading && block.typesetting == TypesettingOptions()
    }

    private enum Key {
        static let layouts = "playgroundLayouts"
        static let currentLayout = "playgroundCurrentLayout"
        static let typeScaleApplied = "playgroundTypeScaleApplied"
    }
}
