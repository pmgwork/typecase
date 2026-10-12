import AppKit
import CoreText
import SwiftUI

/// The PlayGround window: a canvas of text blocks set in the library's fonts.
///
/// The library's toolbar adds the current selection and brings this window
/// forward; every block's typography is edited in the trailing inspector.
/// Layouts live in `PlaygroundStore`, so closing the window keeps the page.
struct PlaygroundView: View {
    @EnvironmentObject private var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playground: PlaygroundStore

    @State private var inspectorVisible = true
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    @State private var copiedImage = false
    @State private var copyFailed = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    private var layout: PlaygroundLayout { playground.currentLayout }

    var body: some View {
        PlaygroundCanvas()
            .inspector(isPresented: $inspectorVisible) {
                PlaygroundBlockInspector()
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
            }
            .frame(minWidth: 720, minHeight: 480)
            .navigationTitle(playground.currentLayout.name)
            .toolbar { toolbarItems }
            .onAppear(perform: setStarterFont)
            .onChange(of: catalog.familiesRevision) { _, _ in setStarterFont() }
            .onChange(of: playground.currentLayoutID) { _, _ in setStarterFont() }
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
            .alert("Could Not Copy Image", isPresented: $copyFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The layout could not be rendered as an image. Try again.")
            }
    }

    private func setStarterFont() {
        guard let reference = catalog.defaultPlaygroundFace() else { return }
        playground.setStarterFontIfNeeded(reference)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            layoutMenu
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(PlaygroundBlockRole.allCases) { role in
                    Button("\(role.title) · \(role.description)") {
                        playground.addBlock(role: role)
                    }
                }
            } label: {
                Label("Add Block", systemImage: "plus")
            }
            .help("Add a heading or paragraph after the selected block")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                copyImage()
            } label: {
                Label(copiedImage ? "Copied" : "Copy as Image",
                      systemImage: copiedImage ? "checkmark" : "doc.on.clipboard")
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .help(copiedImage ? "Image copied to clipboard" : "Copy the layout to the clipboard as an image (⌥⌘C)")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                inspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Show or hide the block settings (⌥⌘I)")
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
        guard let image = renderer.nsImage else {
            copyFailed = true
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            copyFailed = true
            return
        }
        copiedImage = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedImage = false
        }
    }
}

/// A block resolved against the catalog: the face to draw with and the text to
/// show. The canvas and the copied image resolve blocks the same way.
private struct PlaygroundResolvedBlock {
    let text: String
    let family: FontFamily?
    let face: FontFace?
    let variations: [UInt32: Double]?
    let typesetting: TypesettingOptions

    init(block: PlaygroundBlock, catalog: FontCatalog, settings: AppSettings) {
        let family = block.familyID.flatMap { catalog.familyByID[$0] }
        let face = block.faceName.flatMap { name in
            family?.faces.first { $0.postScriptName == name }
        } ?? family?.previewFace
        self.family = family
        self.face = face
        self.variations = face.map { settings.variationValues(for: $0.postScriptName) }
        self.typesetting = block.typesetting

        if block.text.isEmpty {
            var language = family?.previewLanguage ?? .latin
            // Some installed fonts have no CJK metadata in the catalog even
            // though the chosen face supports one. Use that face to choose the
            // placeholder rather than defaulting to English.
            if language == .latin, let face {
                let font = FontResolver.shared.nsFont(
                    postScriptName: face.postScriptName, fileURL: face.fileURL, size: 12
                )
                let codes = CTFontCopySupportedLanguages(font as CTFont) as? [String] ?? []
                let detected = FontLanguage.detected(in: codes)
                language = FontLanguage.previewPriority.first { detected.contains($0) } ?? .latin
            }
            text = settings.sample(for: language)
        } else {
            text = block.text
        }
    }

    func font(size: CGFloat) -> Font {
        FontResolver.shared.previewFont(
            postScriptName: face?.postScriptName,
            fileURL: face?.fileURL,
            size: size,
            variations: variations,
            features: typesetting.features
        )
    }

    /// The OpenType features the block's face carries.
    var availableFeatures: [OpenTypeFeature] {
        guard let face else { return [] }
        return OpenTypeFeatureReader.features(for: [(face.postScriptName, face.fileURL)])
    }
}

/// The canvas: a list for scrolling and reordering blocks, without its native
/// row selection paint. The focused text view chooses the inspector block.
private struct PlaygroundCanvas: View {
    @EnvironmentObject private var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playground: PlaygroundStore

    var body: some View {
        let layout = playground.currentLayout
        List {
            ForEach(layout.blocks) { block in
                PlaygroundBlockRow(
                    block: block,
                    resolved: PlaygroundResolvedBlock(block: block, catalog: catalog, settings: settings),
                    textColor: textColor,
                    isSelected: playground.selectedBlockID == block.id
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: block.role.topSpacing, leading: 28,
                    bottom: block.role.bottomSpacing, trailing: 28
                ))
                .listRowBackground(Color.clear)
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded {
                    if playground.selectedBlockID != block.id {
                        playground.selectedBlockID = block.id
                    }
                })
                .contextMenu {
                    Menu("Element") {
                        ForEach(PlaygroundBlockRole.allCases) { role in
                            Button("\(role.title) · \(role.description)") {
                                var updated = playground.block(id: block.id) ?? block
                                updated.applyRole(role)
                                playground.update(updated)
                                playground.selectedBlockID = block.id
                            }
                        }
                    }
                    Divider()
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
        .background(paperColor)
        // The canvas list has no selection of its own, so it never receives
        // the Delete command; watch the window's key presses instead.
        .background {
            DeleteKeyMonitor {
                guard let id = playground.selectedBlockID else { return false }
                playground.removeBlock(id)
                return true
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
}

/// Calls `onDelete` for Delete and Forward Delete pressed in this view's
/// window while no text view is editing; a text view owning the keyboard keeps
/// the key for its text. `onDelete` returns whether it consumed the key.
private struct DeleteKeyMonitor: NSViewRepresentable {
    let onDelete: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onDelete = onDelete
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onDelete: (() -> Bool)?
        private var monitor: Any?

        /// Delete (51) and Forward Delete (117).
        private static let deleteKeyCodes: Set<UInt16> = [51, 117]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Pass only Sendable values into the main-actor check.
                let windowNumber = event.windowNumber
                let isPlainDelete = Self.deleteKeyCodes.contains(event.keyCode)
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.function, .numericPad]).isEmpty
                guard isPlainDelete else { return event }
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window,
                          window.windowNumber == windowNumber,
                          !(window.firstResponder is NSText) else { return false }
                    return self.onDelete?() == true
                }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// One block of the canvas: the text set in its face at its own size, line
/// height, tracking, and alignment.
private struct PlaygroundBlockRow: View {
    @EnvironmentObject private var playground: PlaygroundStore
    let block: PlaygroundBlock
    let resolved: PlaygroundResolvedBlock
    let textColor: Color
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            caption
            PlaygroundTextEditor(
                text: textBinding,
                placeholder: block.text.isEmpty ? resolved.text : "",
                postScriptName: resolved.face?.postScriptName,
                fileURL: resolved.face?.fileURL,
                variations: resolved.variations,
                features: block.typesetting.features,
                japaneseLatinSpacing: block.typesetting.japaneseLatinSpacing,
                size: CGFloat(block.size),
                lineHeight: block.lineHeight,
                tracking: block.tracking,
                alignment: block.alignment,
                textColor: textColor,
                onBeginEditing: {
                    if playground.selectedBlockID != block.id {
                        playground.selectedBlockID = block.id
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: block.alignment.frameAlignment)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .help("\(block.role.title) · \(helpText) · Click to edit text; press Esc, then Delete, to remove the block")
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { playground.block(id: block.id)?.text ?? block.text },
            set: { text in
                guard var updated = playground.block(id: block.id) else { return }
                updated.text = text
                playground.update(updated)
            }
        )
    }

    /// The role label; the active block adds its font and size, so the block
    /// the inspector edits reads on the canvas without a selection background.
    private var caption: some View {
        Text(isSelected
            ? "\(block.role.title) · \(helpText) · \(Int(block.size.rounded())) pt"
            : block.role.title)
            .font(.caption)
            .foregroundStyle(textColor.opacity(isSelected ? 0.8 : 0.55))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var helpText: String {
        guard let family = resolved.family else { return "System Font" }
        guard let style = resolved.face?.styleName, !style.isEmpty else { return family.name }
        return "\(family.name) · \(style)"
    }
}

/// The trailing panel: the selected block's font and typography controls.
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
                    field("Element") {
                        Picker("Element", selection: roleBinding(block)) {
                            ForEach(PlaygroundBlockRole.allCases) { role in
                                Text("\(role.title) · \(role.description)").tag(role)
                            }
                        }
                        .labelsHidden()
                    }
                    Divider()
                    fontSection(block)
                    if !missingCharacters.isEmpty {
                        missingCharactersNotice
                    }
                    Divider()
                    typographySection(block)
                    Divider()
                    featureSection(block, features: resolved.availableFeatures)
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
                Menu("Sample Text") {
                    ForEach(FontLanguage.allCases) { language in
                        Button(language.title) {
                            update(block) { $0.text = settings.sample(for: language) }
                        }
                    }
                    Divider()
                    Button("Clear Text") { update(block) { $0.text = "" } }
                }
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
            .help("Duplicate, reorder, choose sample text, or delete this block")
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
            HStack(spacing: 8) {
                Text("Typography")
                    .font(.headline)
                Spacer(minLength: 8)
                // Only offered once the values have left the role's scale.
                if !block.usesRoleTypography {
                    Button("Reset to \(block.role.title)") {
                        update(block) { $0.resetTypographyToRole() }
                    }
                    .buttonStyle(.link)
                    .help("Return size, line height, and tracking to the \(block.role.description) defaults")
                }
            }
            slider(
                "Size",
                value: numberBinding(block, \.size),
                range: PlaygroundMetrics.sizeRange,
                step: 1,
                fractionDigits: 0,
                unit: "pt"
            )
            slider(
                "Line Height",
                value: numberBinding(block, \.lineHeight),
                range: PlaygroundMetrics.lineHeightRange,
                step: 0.05,
                fractionDigits: 2,
                unit: "×"
            )
            slider(
                "Tracking",
                value: numberBinding(block, \.tracking),
                range: PlaygroundMetrics.trackingRange,
                step: 0.1,
                fractionDigits: 1,
                unit: "pt"
            )
            slider(
                "Japanese–Latin Space",
                value: spacingPercentBinding(block),
                range: 0...(TypesettingOptions.spacingRange.upperBound * 100),
                step: 1,
                fractionDigits: 0,
                unit: "%"
            )
            .help("Space added between Japanese and Latin letters or figures, as a percentage of the font size (和欧間のアキ)")
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

    /// The face's OpenType features as checkboxes, with a reset once any
    /// differs from the font's default.
    private func featureSection(_ block: PlaygroundBlock, features: [OpenTypeFeature]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("OpenType Features")
                    .font(.headline)
                Spacer(minLength: 8)
                if block.typesetting.changedFeatureCount > 0 {
                    Button("Reset") { update(block) { $0.typesetting.features = [:] } }
                        .buttonStyle(.link)
                        .help("Return every feature to the font's default")
                }
            }
            OpenTypeFeatureList(features: features, options: typesettingBinding(block))
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

    private func roleBinding(_ block: PlaygroundBlock) -> Binding<PlaygroundBlockRole> {
        Binding(
            get: { playground.block(id: block.id)?.role ?? block.role },
            set: { newRole in update(block) { $0.applyRole(newRole) } }
        )
    }

    private func update(_ block: PlaygroundBlock, _ mutate: (inout PlaygroundBlock) -> Void) {
        var updated = playground.block(id: block.id) ?? block
        mutate(&updated)
        playground.update(updated)
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

    private func typesettingBinding(_ block: PlaygroundBlock) -> Binding<TypesettingOptions> {
        Binding(
            get: { playground.block(id: block.id)?.typesetting ?? block.typesetting },
            set: { newValue in update(block) { $0.typesetting = newValue } }
        )
    }

    /// The Japanese–Latin space shown as a percentage of the em.
    private func spacingPercentBinding(_ block: PlaygroundBlock) -> Binding<Double> {
        Binding(
            get: { (playground.block(id: block.id)?.typesetting ?? block.typesetting).japaneseLatinSpacing * 100 },
            set: { newValue in update(block) { $0.typesetting.japaneseLatinSpacing = newValue / 100 } }
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

    /// A slider with a number field beside it, so a value can be dragged or
    /// typed exactly. Typed values are clamped into the slider's range.
    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int,
        unit: String
    ) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = PlaygroundMetrics.clamp($0, to: range) }
        )
        return field(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(title)
                TextField(
                    title,
                    value: clamped,
                    format: .number.precision(.fractionLength(fractionDigits))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 52)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(layout.blocks) { block in
                let resolved = PlaygroundResolvedBlock(block: block, catalog: catalog, settings: settings)
                Text(JapaneseLatinSpacing.attributed(
                    resolved.text.isEmpty ? " " : resolved.text,
                    spacing: block.typesetting.spacing(at: CGFloat(block.size))
                ))
                    .font(resolved.font(size: CGFloat(block.size)))
                    .lineSpacing(CGFloat(block.size) * CGFloat(max(block.lineHeight - 1, 0)))
                    .tracking(CGFloat(block.tracking))
                    .multilineTextAlignment(block.alignment.textAlignment)
                    .foregroundStyle(settings.previewTextColor ?? Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, alignment: block.alignment.frameAlignment)
                    .padding(.vertical, 4)
                    .padding(.top, block.role.topSpacing)
                    .padding(.bottom, block.role.bottomSpacing)
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
