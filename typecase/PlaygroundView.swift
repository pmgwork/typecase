import AppKit
import SwiftUI

/// The PlayGround window: a canvas of text blocks set in the library's fonts.
///
/// The library's toolbar adds the current selection and brings this window
/// forward; every block is edited in the trailing inspector, and the layouts
/// live in `PlaygroundStore`, so the window can be closed and reopened without
/// losing the page.
struct PlaygroundView: View {
    @EnvironmentObject private var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playground: PlaygroundStore

    @State private var inspectorVisible = true
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false

    private var layout: PlaygroundLayout { playground.currentLayout }

    var body: some View {
        PlaygroundCanvas()
            .inspector(isPresented: $inspectorVisible) {
                PlaygroundBlockInspector()
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            }
            .frame(minWidth: 720, minHeight: 480)
            .navigationTitle(playground.currentLayout.name)
            .toolbar { toolbarItems }
            .alert("Rename Layout", isPresented: $isRenaming) {
                TextField("Name", text: $renameText)
                Button("Rename") { playground.renameCurrentLayout(to: renameText) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The name appears in the layout menu.")
            }
            .confirmationDialog(
                "Delete “\(layout.name)”?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Layout", role: .destructive) { playground.deleteCurrentLayout() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The layout’s blocks are removed.")
            }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            layoutMenu
        }
        ToolbarItem(placement: .navigation) {
            Button {
                playground.addBlock()
            } label: {
                Label("Add Block", systemImage: "plus")
            }
            .help("Add a text block")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                copyImage()
            } label: {
                Label("Copy as Image", systemImage: "doc.on.clipboard")
            }
            .help("Copy the layout to the clipboard as an image")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                inspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "info.circle")
            }
            .help("Show or hide the block settings")
        }
    }

    /// The layout picker: the current name as the label, the saved pages and
    /// the layout actions as its menu.
    private var layoutMenu: some View {
        Menu {
            ForEach(playground.layouts) { layout in
                Button {
                    playground.selectLayout(layout.id)
                } label: {
                    if layout.id == playground.currentLayoutID {
                        Label(layout.name, systemImage: "checkmark")
                    } else {
                        Text(layout.name)
                    }
                }
            }
            Divider()
            Button("New Layout") { playground.addLayout() }
            Button("Duplicate") { playground.duplicateCurrentLayout() }
            Button("Rename…") {
                renameText = playground.currentLayout.name
                isRenaming = true
            }
            Divider()
            Button("Delete Layout", role: .destructive) { isConfirmingDelete = true }
                .disabled(playground.layouts.count <= 1)
        } label: {
            Label(playground.currentLayout.name, systemImage: "rectangle.3.group")
        }
        .fixedSize()
        .help("Choose a layout, or create, rename, duplicate, or delete one")
    }

    /// Puts the layout on the pasteboard as an image, drawn at a fixed measure
    /// so the copy does not depend on the window size.
    private func copyImage() {
        let renderer = ImageRenderer(content: PlaygroundPrintPage(
            layout: layout,
            catalog: catalog,
            settings: settings
        ))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

/// A block resolved against the catalog: the face to draw with and the text to
/// show. The canvas and the copied image resolve blocks the same way.
private struct PlaygroundResolvedBlock {
    let text: String
    let family: FontFamily?
    let face: FontFace?
    let variations: [UInt32: Double]?

    init(block: PlaygroundBlock, catalog: FontCatalog, settings: AppSettings) {
        let family = block.familyID.flatMap { catalog.familyByID[$0] }
        let face = block.faceName.flatMap { name in
            family?.faces.first { $0.postScriptName == name }
        } ?? family?.previewFace
        self.family = family
        self.face = face
        self.variations = face.map { settings.variationValues(for: $0.postScriptName) }

        let typed = block.text
        if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = settings.sample(for: family?.previewLanguage ?? .latin)
        } else {
            text = typed
        }
    }

    func font(size: CGFloat) -> Font {
        FontResolver.shared.previewFont(
            postScriptName: face?.postScriptName,
            fileURL: face?.fileURL,
            size: size,
            variations: variations
        )
    }
}

/// The canvas: the layout's blocks as a plain page. List selection is kept —
/// it is the native way to choose, reorder, and delete a block — while its
/// chrome is hidden so the specimens sit directly on the chosen background.
private struct PlaygroundCanvas: View {
    @EnvironmentObject private var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playground: PlaygroundStore

    var body: some View {
        let layout = playground.currentLayout
        List(selection: $playground.selectedBlockID) {
            ForEach(layout.blocks) { block in
                PlaygroundBlockRow(
                    block: block,
                    resolved: PlaygroundResolvedBlock(block: block, catalog: catalog, settings: settings),
                    textColor: textColor,
                    isSelected: playground.selectedBlockID == block.id,
                    selectionTint: selectionTint
                )
                .tag(block.id)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 28, bottom: 8, trailing: 28))
                .contextMenu {
                    Button("Duplicate Block") { playground.duplicateBlock(block.id) }
                    Button("Move Up") { playground.moveBlock(block.id, by: -1) }
                        .disabled(layout.blocks.first?.id == block.id)
                    Button("Move Down") { playground.moveBlock(block.id, by: 1) }
                        .disabled(layout.blocks.last?.id == block.id)
                    Divider()
                    Button("Delete Block", role: .destructive) { playground.removeBlock(block.id) }
                }
            }
            .onMove { playground.moveBlocks(from: $0, to: $1) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.controlActiveState, .key)
        .background(paperColor)
        .onDeleteCommand {
            if let id = playground.selectedBlockID {
                playground.removeBlock(id)
            }
        }
        .overlay {
            if layout.blocks.isEmpty {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Empty Layout", systemImage: "character.textbox")
        } description: {
            Text("Add a block, then set it in any font in your library.")
        } actions: {
            Button("Add Block") { playground.addBlock() }
        }
    }

    /// The canvas color: the chosen specimen background, or the window color
    /// while the specimens follow the system appearance.
    private var paperColor: Color {
        settings.previewBackgroundColor ?? Color(nsColor: .windowBackgroundColor)
    }

    private var textColor: Color {
        settings.previewTextColor ?? Color(nsColor: .labelColor)
    }

    /// The veil drawn over the selected block while the canvas has a custom
    /// color; `nil` keeps the system accent selection.
    private var selectionTint: Color? {
        guard settings.previewBackgroundColor != nil else { return nil }
        return textColor
    }
}

/// One block of the canvas: the text set in its face at its own size, line
/// height, tracking, and alignment.
private struct PlaygroundBlockRow: View {
    let block: PlaygroundBlock
    let resolved: PlaygroundResolvedBlock
    let textColor: Color
    let isSelected: Bool
    let selectionTint: Color?

    var body: some View {
        Text(resolved.text.isEmpty ? " " : resolved.text)
            .font(resolved.font(size: CGFloat(block.size)))
            .lineSpacing(CGFloat(block.size) * CGFloat(max(block.lineHeight - 1, 0)))
            .tracking(CGFloat(block.tracking))
            .multilineTextAlignment(block.alignment.textAlignment)
            .frame(maxWidth: .infinity, alignment: block.alignment.frameAlignment)
            .foregroundStyle(textColor)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                if isSelected, let selectionTint {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selectionTint.opacity(0.18))
                }
            }
            // The system's accent selection is suppressed while the block
            // draws its own veil, otherwise the blue fights the canvas color.
            .background(TableRowEmphasisConfigurator(
                isEmphasized: selectionTint == nil,
                hidesSelectionHighlight: selectionTint != nil
            ))
            .contentShape(.rect)
            .help(helpText)
    }

    private var helpText: String {
        guard let family = resolved.family else { return "System Font" }
        guard let style = resolved.face?.styleName, !style.isEmpty else { return family.name }
        return "\(family.name) · \(style)"
    }
}

/// The trailing panel: the selected block's text and typography.
private struct PlaygroundBlockInspector: View {
    @EnvironmentObject private var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playground: PlaygroundStore
    @State private var missingCharacters: [String] = []

    var body: some View {
        if let block = playground.selectedBlock {
            let resolved = PlaygroundResolvedBlock(block: block, catalog: catalog, settings: settings)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    blockHeader(block)
                    textSection(block: block, resolved: resolved)
                    if !missingCharacters.isEmpty {
                        missingCharactersNotice
                    }
                    Divider()
                    fontSection(block)
                    Divider()
                    typographySection(block)
                }
                .padding(20)
            }
            .task(id: missingCharactersKey(block: block, resolved: resolved)) {
                missingCharacters = []
                guard let face = resolved.face else { return }
                let missing = await catalog.missingCharacters(in: resolved.text, for: face)
                guard !Task.isCancelled else { return }
                missingCharacters = missing
            }
        } else {
            ContentUnavailableView("Select a block", systemImage: "character.textbox")
        }
    }

    // MARK: - Sections

    private func blockHeader(_ block: PlaygroundBlock) -> some View {
        HStack(spacing: 8) {
            Text("Block")
                .font(.headline)
            Spacer(minLength: 8)
            Menu {
                Button("Duplicate Block") { playground.duplicateBlock(block.id) }
                Button("Move Up") { playground.moveBlock(block.id, by: -1) }
                    .disabled(playground.currentLayout.blocks.first?.id == block.id)
                Button("Move Down") { playground.moveBlock(block.id, by: 1) }
                    .disabled(playground.currentLayout.blocks.last?.id == block.id)
                Divider()
                Button("Delete Block", role: .destructive) { playground.removeBlock(block.id) }
            } label: {
                Label("Block Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Duplicate, reorder, or delete this block")
        }
    }

    private func textSection(block: PlaygroundBlock, resolved: PlaygroundResolvedBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Text")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu("Sample Text") {
                    ForEach(FontLanguage.allCases) { language in
                        Button(language.title) {
                            update(block) { $0.text = settings.sample(for: language) }
                        }
                    }
                    Divider()
                    Button("Clear") { update(block) { $0.text = "" } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Fill the block with a language sample")
            }

            TextEditor(text: textBinding(block))
                .font(.body)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor))
                }

            Text("Empty text follows the sample for the font’s language.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fontSection(_ block: PlaygroundBlock) -> some View {
        let family = block.familyID.flatMap { catalog.familyByID[$0] }
        return VStack(alignment: .leading, spacing: 14) {
            field("Font") {
                Picker("Font", selection: familyBinding(block)) {
                    Text("System Font").tag(String?.none)
                    // A font the library no longer carries keeps its block
                    // readable instead of leaving the picker blank.
                    if let familyID = block.familyID, family == nil {
                        Text("Missing Font").tag(Optional(familyID))
                    }
                    ForEach(catalog.families) { item in
                        Text(item.name).tag(Optional(item.id))
                    }
                }
                .labelsHidden()
            }
            field("Style") {
                Picker("Style", selection: faceBinding(block)) {
                    if let family {
                        ForEach(family.faces) { face in
                            Text(face.styleName).tag(Optional(face.id))
                        }
                    } else {
                        Text("Regular").tag(String?.none)
                    }
                }
                .labelsHidden()
                .disabled(family == nil)
            }
        }
    }

    private func typographySection(_ block: PlaygroundBlock) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            slider(
                "Size",
                value: numberBinding(block, \.size),
                range: PlaygroundMetrics.sizeRange,
                step: 1,
                valueText: "\(Int(block.size.rounded())) pt"
            )
            slider(
                "Line Height",
                value: numberBinding(block, \.lineHeight),
                range: PlaygroundMetrics.lineHeightRange,
                step: 0.05,
                valueText: String(format: "%.2f", block.lineHeight)
            )
            slider(
                "Tracking",
                value: numberBinding(block, \.tracking),
                range: PlaygroundMetrics.trackingRange,
                step: 0.1,
                valueText: String(format: "%.1f pt", block.tracking)
            )
            field("Alignment") {
                Picker("Alignment", selection: alignmentBinding(block)) {
                    ForEach(PlaygroundAlignment.allCases) { alignment in
                        Label(alignment.title, systemImage: alignment.symbol)
                            .labelStyle(.iconOnly)
                            .tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Missing characters

    /// Characters of the resolved text the block's face cannot display, the
    /// same check the library's inspector makes.
    private var missingCharactersNotice: some View {
        let visible = missingCharacters.prefix(12)
        let remaining = missingCharacters.count - visible.count
        let list = visible.joined(separator: " ")
        return Label {
            Text(remaining > 0
                ? "Missing characters: \(list) … (+\(remaining))"
                : "Missing characters: \(list)")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .help("The selected style cannot display these characters")
    }

    private func missingCharactersKey(block: PlaygroundBlock, resolved: PlaygroundResolvedBlock) -> String {
        "\(block.id)|\(resolved.face?.postScriptName ?? "")|\(resolved.text)"
    }

    // MARK: - Bindings

    private func update(_ block: PlaygroundBlock, _ mutate: (inout PlaygroundBlock) -> Void) {
        var updated = block
        mutate(&updated)
        playground.update(updated)
    }

    private func textBinding(_ block: PlaygroundBlock) -> Binding<String> {
        Binding(
            get: { playground.block(id: block.id)?.text ?? block.text },
            set: { newValue in update(block) { $0.text = newValue } }
        )
    }

    /// Choosing a family resets the style to the family's preview face, so the
    /// block never points at another family's style.
    private func familyBinding(_ block: PlaygroundBlock) -> Binding<String?> {
        Binding(
            get: { playground.block(id: block.id)?.familyID ?? block.familyID },
            set: { newValue in
                update(block) { updated in
                    updated.familyID = newValue
                    updated.faceName = newValue
                        .flatMap { catalog.familyByID[$0] }?
                        .previewFace?.postScriptName
                }
            }
        )
    }

    private func faceBinding(_ block: PlaygroundBlock) -> Binding<String?> {
        Binding(
            get: {
                let stored = playground.block(id: block.id)?.faceName ?? block.faceName
                let family = (playground.block(id: block.id)?.familyID ?? block.familyID)
                    .flatMap { catalog.familyByID[$0] }
                // A family's style list has no "default" entry, so a block that
                // stores no style (or one its family no longer carries) shows
                // the preview style the canvas draws it with.
                if let stored, family?.faces.contains(where: { $0.postScriptName == stored }) == true {
                    return stored
                }
                return family?.previewFace?.postScriptName
            },
            set: { newValue in update(block) { $0.faceName = newValue } }
        )
    }

    private func numberBinding(
        _ block: PlaygroundBlock,
        _ keyPath: WritableKeyPath<PlaygroundBlock, Double>
    ) -> Binding<Double> {
        Binding(
            get: { playground.block(id: block.id)?[keyPath: keyPath] ?? block[keyPath: keyPath] },
            set: { newValue in update(block) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func alignmentBinding(_ block: PlaygroundBlock) -> Binding<PlaygroundAlignment> {
        Binding(
            get: { playground.block(id: block.id)?.alignment ?? block.alignment },
            set: { newValue in update(block) { $0.alignment = newValue } }
        )
    }

    // MARK: - Layout helpers

    /// The inspector's eyebrow layout: a muted label above its control.
    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        field(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(title)
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// The layout drawn as a page for the clipboard image: no list chrome, no
/// selection, and a fixed measure.
private struct PlaygroundPrintPage: View {
    let layout: PlaygroundLayout
    let catalog: FontCatalog
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(layout.blocks) { block in
                let resolved = PlaygroundResolvedBlock(block: block, catalog: catalog, settings: settings)
                Text(resolved.text.isEmpty ? " " : resolved.text)
                    .font(resolved.font(size: CGFloat(block.size)))
                    .lineSpacing(CGFloat(block.size) * CGFloat(max(block.lineHeight - 1, 0)))
                    .tracking(CGFloat(block.tracking))
                    .multilineTextAlignment(block.alignment.textAlignment)
                    .foregroundStyle(settings.previewTextColor ?? Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, alignment: block.alignment.frameAlignment)
            }
        }
        .frame(width: 900, alignment: .leading)
        .padding(72)
        .background(settings.previewBackgroundColor ?? Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    PlaygroundView()
        .environmentObject(FontCatalog())
        .environmentObject(AppSettings())
        .environmentObject(PlaygroundStore())
}
