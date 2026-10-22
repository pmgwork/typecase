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
            .navigationTitle("PlayGround")
            .toolbar { toolbarItems }
            .onAppear(perform: setStarterFont)
            .onChange(of: catalog.familiesRevision) { _, _ in setStarterFont() }
            .onChange(of: playground.currentLayoutID) { _, _ in setStarterFont() }
            .alert(String(localized: "Rename Layout"), isPresented: $isRenaming) {
                TextField(String(localized: "Name"), text: $renameText)
                Button(String(localized: "Rename")) { playground.renameCurrentLayout(to: renameText) }
                    .keyboardShortcut(.defaultAction)
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "The name appears in the layout menu."))
            }
            .confirmationDialog(
                String(localized: "Delete “\(layout.name)”?"),
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete Layout"), role: .destructive) { playground.deleteCurrentLayout() }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "The layout’s blocks are removed."))
            }
            .alert(String(localized: "Could Not Copy Image"), isPresented: $copyFailed) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(localized: "The layout could not be rendered as an image. Try again."))
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
                Label(String(localized: "Add Block"), systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .help(String(localized: "Add a heading or paragraph after the selected block"))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                copyImage()
            } label: {
                Label(copiedImage ? String(localized: "Copied") : String(localized: "Copy as Image"),
                      systemImage: copiedImage ? "checkmark" : "doc.on.clipboard")
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .help(copiedImage ? String(localized: "Image copied to clipboard") : String(localized: "Copy the layout to the clipboard as an image (⌥⌘C)"))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                inspectorVisible.toggle()
            } label: {
                Label(String(localized: "Inspector"), systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(String(localized: "Show or hide the block settings (⌥⌘I)"))
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
            Button(String(localized: "New Layout")) { playground.addLayout() }
            Button(String(localized: "Duplicate")) { playground.duplicateCurrentLayout() }
            Button(String(localized: "Rename…")) {
                renameText = playground.currentLayout.name
                isRenaming = true
            }
            Divider()
            Button(String(localized: "Delete Layout"), role: .destructive) { isConfirmingDelete = true }
                .disabled(playground.layouts.count <= 1)
        } label: {
            Label(playground.currentLayout.name, systemImage: "rectangle.3.group")
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help(String(localized: "Choose a layout, or create, rename, duplicate, or delete one"))
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
                    Menu(String(localized: "Element")) {
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
                    Button(String(localized: "Duplicate Block")) { playground.duplicateBlock(block.id) }
                    Button(String(localized: "Move Up")) { playground.moveBlock(block.id, by: -1) }
                        .disabled(layout.blocks.first?.id == block.id)
                    Button(String(localized: "Move Down")) { playground.moveBlock(block.id, by: 1) }
                        .disabled(layout.blocks.last?.id == block.id)
                    Divider()
                    Button(String(localized: "Delete Block"), role: .destructive) { playground.removeBlock(block.id) }
                }
            }
            .onMove { playground.moveBlocks(from: $0, to: $1) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 16, for: .scrollContent)
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
            Label(String(localized: "Empty Layout"), systemImage: "character.textbox")
        } description: {
            Text(String(localized: "Add a block, then set it in any font in your library."))
        } actions: {
            Button(String(localized: "Add Block")) { playground.addBlock() }
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
            Button {
                playground.selectedBlockID = block.id
            } label: {
                caption.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Select a block"))
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
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(textColor.opacity(isSelected ? 0.035 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(textColor.opacity(isSelected ? 0.25 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .help(String(localized: "\(block.role.title) · \(helpText) · Click to edit text; press Esc, then Delete, to remove the block"))
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
            .foregroundStyle(textColor.opacity(isSelected ? 0.8 : 0.6))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var helpText: String {
        guard let family = resolved.family else { return String(localized: "System Font") }
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
    @State private var featuresExpanded = false

    var body: some View {
        if let block = playground.selectedBlock {
            let resolved = PlaygroundResolvedBlock(block: block, catalog: catalog, settings: settings)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    fontSection(block)
                    if !missingCharacters.isEmpty {
                        missingCharactersNotice
                    }
                    Divider()
                    typographySection(block)
                    Divider()
                    DisclosureGroup(isExpanded: $featuresExpanded) {
                        featureSection(block, features: resolved.availableFeatures)
                            .padding(.top, 12)
                    } label: {
                        Text(String(localized: "OpenType Features"))
                            .font(.headline)
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    blockHeader(block)
                    TypographyPopUp(
                        title: String(localized: "Element"),
                        options: PlaygroundBlockRole.allCases.map {
                            .init(id: $0.rawValue, title: "\($0.title) · \($0.description)")
                        },
                        selection: Binding(
                            get: { block.role.rawValue },
                            set: { value in
                                guard let value, let role = PlaygroundBlockRole(rawValue: value) else { return }
                                roleBinding(block).wrappedValue = role
                            }
                        )
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
            }
            .task(id: missingCharactersKey(block: block, resolved: resolved)) {
                missingCharacters = []
                guard let face = resolved.face else { return }
                let missing = await catalog.missingCharacters(in: resolved.text, for: face)
                guard !Task.isCancelled else { return }
                missingCharacters = missing
            }
        } else {
            ContentUnavailableView(String(localized: "Select a block"), systemImage: "character.textbox")
        }
    }

    // MARK: - Sections

    private func blockHeader(_ block: PlaygroundBlock) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "Block"))
                .font(.headline)
            Spacer(minLength: 8)
            Menu {
                Button(String(localized: "Duplicate Block")) { playground.duplicateBlock(block.id) }
                Button(String(localized: "Move Up")) { playground.moveBlock(block.id, by: -1) }
                    .disabled(playground.currentLayout.blocks.first?.id == block.id)
                Button(String(localized: "Move Down")) { playground.moveBlock(block.id, by: 1) }
                    .disabled(playground.currentLayout.blocks.last?.id == block.id)
                Divider()
                Menu(String(localized: "Sample Text")) {
                    ForEach(FontLanguage.allCases) { language in
                        Button(language.title) {
                            update(block) { $0.text = settings.sample(for: language) }
                        }
                    }
                    Divider()
                    Button(String(localized: "Clear Text")) { update(block) { $0.text = "" } }
                }
                Divider()
                Button(String(localized: "Delete Block"), role: .destructive) { playground.removeBlock(block.id) }
            } label: {
                Label(String(localized: "Block Actions"), systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Duplicate, reorder, choose sample text, or delete this block"))
        }
    }

    private func fontSection(_ block: PlaygroundBlock) -> some View {
        let family = block.familyID.flatMap { catalog.familyByID[$0] }
        var familyOptions: [TypographyPopUp.Option] = [
            .init(id: nil, title: String(localized: "System Font"))
        ]
        if let familyID = block.familyID, family == nil {
            familyOptions.append(.init(id: familyID, title: String(localized: "Missing Font")))
        }
        familyOptions += catalog.families.map { .init(id: $0.id, title: $0.name) }
        return VStack(alignment: .leading, spacing: 14) {
            field(String(localized: "Font")) {
                TypographyPopUp(title: String(localized: "Font"), options: familyOptions,
                                selection: familyBinding(block))
            }
            field(String(localized: "Style")) {
                TypographyPopUp(
                    title: String(localized: "Style"),
                    options: family?.faces.map { .init(id: $0.id, title: $0.styleName) }
                        ?? [.init(id: nil, title: "Regular")],
                    selection: faceBinding(block), enabled: family != nil
                )
            }
        }
    }

    private func typographySection(_ block: PlaygroundBlock) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(String(localized: "Typography"))
                    .font(.headline)
                Spacer(minLength: 8)
                // Only offered once the values have left the role's scale.
                if !block.usesRoleTypography {
                    Button(String(localized: "Reset to \(block.role.title)")) {
                        update(block) { $0.resetTypographyToRole() }
                    }
                    .buttonStyle(.link)
                    .help(String(localized: "Return size, line height, and tracking to the \(block.role.description) defaults"))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    metricField(String(localized: "Size"), value: numberBinding(block, \.size),
                                range: PlaygroundMetrics.sizeRange, fractionDigits: 0, unit: "pt")
                    metricField(String(localized: "Line Height"), value: numberBinding(block, \.lineHeight),
                                range: PlaygroundMetrics.lineHeightRange, fractionDigits: 2, unit: "×")
                }
                GridRow {
                    metricField(String(localized: "Tracking"), value: numberBinding(block, \.tracking),
                                range: PlaygroundMetrics.trackingRange, fractionDigits: 1, unit: "pt")
                    metricField(String(localized: "Japanese–Latin Space"), value: spacingPercentBinding(block),
                                range: 0...(TypesettingOptions.spacingRange.upperBound * 100),
                                fractionDigits: 0, unit: "%")
                        .help(String(localized: "Space added between Japanese and Latin letters or figures, as a percentage of the font size (和欧間のアキ)"))
                }
            }
            field(String(localized: "Alignment")) {
                HStack(spacing: 2) {
                    ForEach(PlaygroundAlignment.allCases) { alignment in
                        Button {
                            alignmentBinding(block).wrappedValue = alignment
                        } label: {
                            Image(systemName: alignment.symbol)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background {
                                    if block.alignment == alignment {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color(nsColor: .selectedControlColor))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(alignment.title)
                        .accessibilityLabel(alignment.title)
                        .accessibilityAddTraits(block.alignment == alignment ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Alignment"))
            }
        }
    }

    /// The face's OpenType features as checkboxes, with a reset once any
    /// differs from the font's default.
    private func featureSection(_ block: PlaygroundBlock, features: [OpenTypeFeature]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if block.typesetting.changedFeatureCount > 0 {
                Button(String(localized: "Reset")) { update(block) { $0.typesetting.features = [:] } }
                    .buttonStyle(.link)
                    .help(String(localized: "Return every feature to the font's default"))
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
                ? String(localized: "Missing characters: \(list) … (+\(remaining))")
                : String(localized: "Missing characters: \(list)"))
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .help(String(localized: "The selected style cannot display these characters"))
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
        labelHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: labelHeight, alignment: .bottomLeading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact numeric fields keep the common typography settings together.
    private func metricField(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>,
        fractionDigits: Int, unit: String
    ) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = PlaygroundMetrics.clamp($0, to: range) }
        )
        return field(title, labelHeight: 28) {
            HStack(spacing: 6) {
                TextField(title, value: clamped,
                          format: .number.precision(.fractionLength(fractionDigits)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                Text(unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
            }
            .controlSize(.large)
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
