import AppKit
import Combine
import SwiftUI

/// The identifier of the mixed-pair window scene. The library's toolbar button
/// opens it.
enum MixedPairWindow {
    static let id = "mixedPairEditor"
}

/// What the mixed-pair window is composing. The window seeds it with the fonts
/// a new pair starts from, and edits it until the pair is saved.
@MainActor
final class MixedPairDraft: ObservableObject {
    @Published private var selections: [MixedScript: FontFaceReference] = [:]
    /// The text the window's specimen previews. Empty shows the samples.
    @Published var previewText = ""
    /// The window's own specimen size; `nil` follows the library's preview
    /// size, which this window never changes.
    @Published var previewSize: Double?
    /// OpenType features and the Japanese–Latin space the pair is saved with.
    @Published var typesetting = TypesettingOptions()
    @Published private(set) var savedPairSelectionID: FontFamily.ID?
    weak var originatingWindow: NSWindow?

    /// Seeds the editor with the fonts a new pair starts from.
    func begin(with defaults: [MixedScript: FontFaceReference], from window: NSWindow?) {
        selections = defaults
        previewText = ""
        previewSize = nil
        typesetting = TypesettingOptions()
        originatingWindow = window
        savedPairSelectionID = nil
    }

    func didSave(_ pair: FontPair) {
        savedPairSelectionID = pair.selectionID
    }

    func selection(for script: MixedScript) -> FontFaceReference? {
        selections[script]
    }

    func setSelection(_ reference: FontFaceReference?, for script: MixedScript) {
        selections[script] = reference
    }

    /// The references the current selections name.
    func references() -> [MixedScript: FontFaceReference] {
        selections
    }

    /// The faces the current selections name, resolved against the library.
    func faces(in catalog: FontCatalog) -> [MixedScript: FontFace] {
        selections.compactMapValues { catalog.face(for: $0) }
    }
}

/// The mixed-pair window: one row per part of the mix on the left, the
/// specimen those choices draw on the right, and the actions at the bottom.
struct MixedPairEditorView: View {
    @ObservedObject var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var draft: MixedPairDraft
    @Environment(\.dismiss) private var dismiss
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isOpenTypeExpanded = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            scriptList
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
        } detail: {
            preview
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .safeAreaInset(edge: .bottom, spacing: 0) { partLegend }
        }
        .frame(minWidth: 820, minHeight: 520)
        // The chosen specimen background paints the whole window, so the rows
        // and the specimen sit on the same canvas the library uses.
        .background(canvasColor)
        .background { WindowCanvas(color: settings.previewBackgroundColor) }
        // Cancel and Save live in the window's own toolbar, at the top right, in
        // the same glass capsules the library window's toolbar items use.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PreviewSizeControl(size: previewSizeBinding)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.glassProminent)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var previewSize: Double {
        draft.previewSize ?? settings.previewSize
    }

    private var previewSizeBinding: Binding<Double> {
        Binding(get: { previewSize }, set: { draft.previewSize = $0 })
    }

    private var canvasColor: Color {
        settings.previewBackgroundColor ?? Color(nsColor: .windowBackgroundColor)
    }

    // MARK: - Parts

    /// The parts of the mix, each with the font and weight that draws it. No
    /// fixed width here: the column width owns the sizing, so dragging the
    /// divider never fights the content.
    private var scriptList: some View {
        let faces = draft.faces(in: catalog)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                partGroup(scripts: MixedScript.allCases, faces: faces)
                typesettingGroup(faces: faces)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// The pair's Character settings, named and measured like Illustrator's
    /// Character panel, and the OpenType features of its fonts.
    private func typesettingGroup(faces: [MixedScript: FontFace]) -> some View {
        let available = OpenTypeFeatureReader.features(
            for: MixedScript.allCases.compactMap { faces[$0] }.map { ($0.postScriptName, $0.fileURL) }
        )
        let hasProportionalMetrics = available.contains { $0.tag == "palt" }
        return VStack(alignment: .leading, spacing: 20) {
            group(String(localized: "Character")) {
                Grid(horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        characterField(.tracking) {
                            PresetComboBox(
                                title: String(localized: "Tracking"),
                                value: $draft.typesetting.tracking,
                                range: TypesettingOptions.trackingRange,
                                presets: [-100, -75, -50, -25, -10, -5, 0, 5, 10, 25, 50, 75, 100, 200]
                            )
                            .help(String(localized: "Space after every character, in 1/1000 em"))
                        }
                        characterField(.tsume) {
                            PresetComboBox(
                                title: String(localized: "Tsume"),
                                value: tsumePercent,
                                range: 0...100,
                                presets: stride(from: 0, through: 100, by: 10).map(Double.init),
                                unit: "%"
                            )
                            .help(String(localized: "Removes this share of each glyph's side bearings (文字ツメ)"))
                        }
                    }
                    GridRow {
                        characterField(.kerning) {
                            MixedPairPopUp(
                                title: String(localized: "Kerning"),
                                options: TypesettingOptions.Kerning.allCases.map {
                                    .init(id: $0.rawValue, title: $0 == .romanOnly ? String(localized: "Roman Only") : $0.title)
                                },
                                selection: kerningSelection
                            )
                            .help(String(localized: "Auto uses the fonts' kerning pairs; Metrics – Roman Only sets Japanese text solid; 0 turns kerning off"))
                        }
                        characterField(.japaneseLatin) {
                            MixedPairPopUp(
                                title: String(localized: "Japanese–Latin Space"),
                                options: spacingOptions,
                                selection: spacingSelection
                            )
                            .help(String(localized: "Space between Japanese and Latin letters or figures, as in a Mojikumi set (和欧間のアキ). A space typed at the boundary takes this width."))
                        }
                    }
                }
                Divider()
                    .padding(.top, 2)
                Toggle(String(localized: "Proportional Metrics"), isOn: proportionalMetrics)
                    .toggleStyle(.checkbox)
                    .disabled(!hasProportionalMetrics)
                    .help(hasProportionalMetrics
                        ? String(localized: "Sets Japanese text with the fonts' proportional widths (palt)")
                        : String(localized: "These fonts have no proportional metrics"))
            }
            DisclosureGroup(isExpanded: $isOpenTypeExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    OpenTypeFeatureList(
                        features: available.filter { !["kern", "palt"].contains($0.tag) },
                        options: $draft.typesetting
                    )
                    if draft.typesetting.features.keys.contains(where: { !["kern", "palt"].contains($0) }) {
                        Button(String(localized: "Reset Features")) {
                            draft.typesetting.features = draft.typesetting.features.filter {
                                ["kern", "palt"].contains($0.key)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(String(localized: "OpenType Features"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Compact icon-and-control rows, like a desktop typography palette.
    private func characterField<Content: View>(_ icon: CharacterIcon, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            icon
            content()
                .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: MixedPairPopUp.height)
    }

    /// The Japanese–Latin spaces of Illustrator's Mojikumi settings, in em.
    private static let spacingPresets: [(title: String, value: Double)] = [
        (String(localized: "None"), 0), ("1/8 em", 0.125), ("1/4 em", 0.25), ("1/3 em", 1.0 / 3), ("1/2 em", 0.5),
    ]

    private var spacingOptions: [MixedPairPopUp.Option] {
        var options = Self.spacingPresets.map { MixedPairPopUp.Option(id: String($0.value), title: $0.title) }
        let current = draft.typesetting.japaneseLatinSpacing
        if !Self.spacingPresets.contains(where: { $0.value == current }) {
            options.append(.init(id: String(current), title: String(localized: "Custom (\(Int((current * 100).rounded()))%)")))
        }
        return options
    }

    private var spacingSelection: Binding<String?> {
        Binding(
            get: { String(draft.typesetting.japaneseLatinSpacing) },
            set: { draft.typesetting.japaneseLatinSpacing = $0.flatMap(Double.init) ?? 0 }
        )
    }

    private var kerningSelection: Binding<String?> {
        Binding(
            get: { draft.typesetting.kerning.rawValue },
            set: { draft.typesetting.kerning = $0.flatMap(TypesettingOptions.Kerning.init(rawValue:)) ?? .auto }
        )
    }

    private var tsumePercent: Binding<Double> {
        Binding(
            get: { draft.typesetting.tsume * 100 },
            set: { draft.typesetting.tsume = $0 / 100 }
        )
    }

    private var proportionalMetrics: Binding<Bool> {
        Binding(
            get: { draft.typesetting.features["palt"] == true },
            set: { draft.typesetting.features["palt"] = $0 ? true : nil }
        )
    }

    /// A titled group of the left column: a muted heading over a rounded
    /// panel, like the grouped sections of System Settings.
    private func group<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// All four script choices share one panel without a heading.
    private func partGroup(
        scripts: [MixedScript],
        faces: [MixedScript: FontFace]
    ) -> some View {
        group {
            ForEach(Array(scripts.enumerated()), id: \.element) { index, script in
                if index > 0 {
                    Divider()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(script.title)
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 8)
                        partSample(script, faces: faces)
                    }
                    // The font takes the room; the weight only needs a
                    // short name such as W5 or Medium.
                    HStack(spacing: 6) {
                        fontMenu(script, selection: familyBinding(for: script))
                        styleMenu(script, selection: faceBinding(for: script))
                            .frame(width: MixedPairPopUp.styleWidth)
                    }
                }
            }
        }
    }

    /// A few characters of the part in the face that actually draws it: its
    /// own, or for an unset optional part, the face it falls back to.
    @ViewBuilder
    private func partSample(_ script: MixedScript, faces: [MixedScript: FontFace]) -> some View {
        let source = MixedText.fallbackScripts(for: script).first { faces[$0] != nil }
        if let source, let face = faces[source] {
            Text(script.sampleGlyphs)
                .font(FontResolver.shared.previewFont(
                    postScriptName: face.postScriptName,
                    fileURL: face.fileURL,
                    size: 18,
                    variations: settings.variationValues(for: face)
                ))
                .foregroundStyle(source != script
                    ? AnyShapeStyle(.tertiary)
                    : AnyShapeStyle(settings.previewTextColor ?? Color(nsColor: .labelColor)))
                .lineLimit(1)
                .help(source == script
                    ? String(localized: "\(script.title) sample")
                    : String(localized: "Automatic: drawn with the \(source.title) font"))
        }
    }

    /// One part's font pop-up: the families that can fill it, in name order,
    /// with a compact native control matching the style pop-up. Choosing a
    /// family resets the weight to its preferred mixed face (W5 or Medium when
    /// that style exists).
    private func fontMenu(
        _ script: MixedScript,
        selection: Binding<FontFamily.ID?>
    ) -> some View {
        MixedPairPopUp(
            title: String(localized: "\(script.title) font"),
            options: [MixedPairPopUp.Option(id: nil, title: script.isRequired ? String(localized: "None") : String(localized: "Automatic"))]
                + catalog.families(for: script).map { .init(id: $0.id, title: $0.name) },
            selection: selection
        )
        .frame(maxWidth: .infinity)
        .frame(height: MixedPairPopUp.height)
        .help(fontHelp(for: script))
    }

    private func fontHelp(for script: MixedScript) -> String {
        switch script {
        case .japanese, .latin:
            String(localized: "Choose the \(script.title) font; a pair needs one")
        case .numbers:
            String(localized: "Choose the numbers font; Automatic draws digits with the Symbols font, or the English font")
        case .symbols:
            String(localized: "Choose the symbols font; Automatic draws symbols with the Numbers font, or the English font")
        }
    }

    /// Every style pop-up keeps the same width, whether its current style name
    /// is short (W6) or long (Bold Italic).
    private func styleMenu(
        _ script: MixedScript,
        selection: Binding<String?>
    ) -> some View {
        let family = family(for: script)
        return MixedPairPopUp(
            title: String(localized: "\(script.title) style"),
            options: family?.faces.map { .init(id: $0.postScriptName, title: $0.styleName) }
                ?? [.init(id: nil, title: String(localized: "No style"))],
            selection: selection,
            enabled: family != nil
        )
        .frame(height: MixedPairPopUp.height)
        .help(String(localized: "Choose the \(script.title) weight"))
    }

    /// The family behind a part's current selection.
    private func family(for script: MixedScript) -> FontFamily? {
        guard let reference = draft.selection(for: script) else { return nil }
        return catalog.familyByID[reference.familyID]
    }

    private func familyBinding(for script: MixedScript) -> Binding<FontFamily.ID?> {
        Binding(
            get: { draft.selection(for: script)?.familyID },
            set: { familyID in
                guard let familyID, let family = catalog.familyByID[familyID],
                       let face = family.defaultMixedFace(for: script) else {
                    draft.setSelection(nil, for: script)
                    return
                }
                draft.setSelection(
                    FontFaceReference(familyID: family.id, postScriptName: face.postScriptName),
                    for: script
                )
            }
        )
    }

    private func faceBinding(for script: MixedScript) -> Binding<String?> {
        Binding(
            get: {
                guard let reference = draft.selection(for: script),
                      let family = catalog.familyByID[reference.familyID]
                else { return nil }
                // A stored style the family no longer carries shows the
                // preview style the specimen draws it with.
                if family.faces.contains(where: { $0.postScriptName == reference.postScriptName }) {
                    return reference.postScriptName
                }
                return family.previewFace?.postScriptName ?? family.faces.first?.postScriptName
            },
            set: { postScriptName in
                guard let familyID = draft.selection(for: script)?.familyID,
                      let postScriptName else { return }
                draft.setSelection(
                    FontFaceReference(familyID: familyID, postScriptName: postScriptName),
                    for: script
                )
            }
        )
    }

    // MARK: - Preview

    /// The mix while it is being composed, wrapping freely so the whole
    /// specimen is visible. The specimen itself is the text field: it is typed
    /// in with each part's font, so what is seen is what is saved.
    @ViewBuilder
    private var preview: some View {
        let faces = draft.faces(in: catalog)
        if faces[.japanese] != nil, faces[.latin] != nil {
            MixedTextEditor(
                text: $draft.previewText,
                placeholder: settings.effectiveMixedText(entered: ""),
                size: previewSize,
                fonts: fonts(for: faces),
                typesetting: draft.typesetting,
                textColor: settings.previewTextColor
            )
        } else {
            Text(String(localized: "Choose a Japanese and an English font to see the mix."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                .padding(20)
        }
    }

    /// Which font draws each part of the specimen, along its bottom edge: an
    /// unset optional part names the font it falls back to.
    private var partLegend: some View {
        let faces = draft.faces(in: catalog)
        return VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 24) {
                ForEach(MixedScript.allCases, id: \.self) { script in
                    let source = MixedText.fallbackScripts(for: script).first { faces[$0] != nil }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let source, let face = faces[source] {
                            Text(legendName(for: source, face: face))
                                .font(.callout)
                                .foregroundStyle(source == script ? .primary : .tertiary)
                                .lineLimit(1)
                                .help(source == script ? "" : String(localized: "Automatic: drawn with the \(source.title) font"))
                        } else {
                            Text("—")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
        }
    }

    private func legendName(for script: MixedScript, face: FontFace) -> String {
        let name = family(for: script)?.name ?? face.postScriptName
        return "\(name) \(face.styleName)"
    }

    private func fonts(for faces: [MixedScript: FontFace]) -> [MixedScript: PreviewFaceSpec] {
        faces.reduce(into: [:]) { result, entry in
            result[entry.key] = PreviewFaceSpec(
                postScriptName: entry.value.postScriptName,
                fileURL: entry.value.fileURL,
                variations: settings.variationValues(for: entry.value),
                features: draft.typesetting.features(for: entry.key)
            )
        }
    }

    // MARK: - Saving

    private var canSave: Bool {
        let faces = draft.faces(in: catalog)
        return faces[.japanese] != nil && faces[.latin] != nil
    }

    private func save() {
        // Normalize stale styles to the faces the specimen actually draws,
        // so a saved pair never points at a style its family no longer has.
        var references = draft.references()
        for script in MixedScript.allCases {
            guard let reference = references[script],
                  let face = catalog.face(for: reference)
            else {
                if script == .japanese || script == .latin { return }
                references.removeValue(forKey: script)
                continue
            }
            references[script] = FontFaceReference(
                familyID: reference.familyID,
                postScriptName: face.postScriptName
            )
        }
        let typesetting = draft.typesetting == TypesettingOptions() ? nil : draft.typesetting
        guard let pair = catalog.addMixedPair(references: references, typesetting: typesetting) else { return }
        draft.didSave(pair)
        dismiss()
    }
}

/// The pictogram in front of a Character setting, drawn like the icons of
/// Illustrator's Character panel: sample letters over an arrow that shows
/// which way the setting moves them. The setting's name is its tooltip and
/// accessibility label.
private enum CharacterIcon: View {
    case kerning, tracking, tsume, japaneseLatin

    static let width: CGFloat = 24

    var body: some View {
        VStack(spacing: 1) {
            Text(letters)
                .font(.system(size: 12, weight: .semibold))
                .kerning(self == .kerning ? -1.5 : 0)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: arrow)
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .frame(width: Self.width)
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch self {
        case .kerning: String(localized: "Kerning")
        case .tracking: String(localized: "Tracking")
        case .tsume: String(localized: "Tsume")
        case .japaneseLatin: String(localized: "Japanese–Latin Space")
        }
    }

    private var letters: String {
        switch self {
        case .kerning: "VA"
        case .tracking: "VA"
        case .tsume: "字"
        case .japaneseLatin: "あA"
        }
    }

    /// Kerning moves one pair, tracking spreads every letter, tsume pulls the
    /// bearings in, and the Japanese–Latin space opens the script boundary.
    private var arrow: String {
        switch self {
        case .kerning: "arrow.left"
        case .tracking: "arrow.left.and.right"
        case .tsume: "arrow.right.and.line.vertical.and.arrow.left"
        case .japaneseLatin: "arrow.left.and.line.vertical.and.arrow.right"
        }
    }
}

/// A number field with a list of preset values: the native combo box that
/// Illustrator's Character panel uses. Typed values are clamped to `range`;
/// the unit is shown after the number and ignored when reading it back.
private struct PresetComboBox: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let presets: [Double]
    var unit: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ComboContainer {
        let container = ComboContainer()
        let box = container.box
        box.usesDataSource = false
        box.completes = false
        box.addItems(withObjectValues: presets.map(format))
        box.numberOfVisibleItems = presets.count
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.commit(_:))
        box.stringValue = format(value)
        box.setAccessibilityLabel(title)
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComboContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: MixedPairPopUp.height)
    }

    func updateNSView(_ container: ComboContainer, context: Context) {
        context.coordinator.parent = self
        // Leave the text alone while it is being typed.
        if container.box.currentEditor() == nil, container.box.stringValue != format(value) {
            container.box.stringValue = format(value)
        }
    }

    func format(_ number: Double) -> String {
        let text = number.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
        return unit.map { text + $0 } ?? text
    }

    func parse(_ text: String) -> Double? {
        let digits = text.filter { $0.isNumber || $0 == "-" || $0 == "−" || $0 == "." }
            .replacingOccurrences(of: "−", with: "-")
        return Double(digits).map { min(max($0, range.lowerBound), range.upperBound) }
    }

    final class ComboContainer: NSView {
        let box = NSComboBox()

        init() {
            super.init(frame: .zero)
            box.translatesAutoresizingMaskIntoConstraints = false
            box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: leadingAnchor),
                box.trailingAnchor.constraint(equalTo: trailingAnchor),
                box.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// AppKit makes the first text field of a new window its first
        /// responder; hand that back so the window opens without a focused,
        /// selected number.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.box.currentEditor() != nil else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: PresetComboBox

        init(parent: PresetComboBox) {
            self.parent = parent
        }

        @objc func commit(_ box: NSComboBox) {
            if let number = parent.parse(box.stringValue) {
                parent.value = number
            }
            box.stringValue = parent.format(parent.value)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox,
                  parent.presets.indices.contains(box.indexOfSelectedItem) else { return }
            parent.value = parent.presets[box.indexOfSelectedItem]
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            commit(box)
        }
    }
}

/// A native AppKit pop-up with a consistent, compact width. SwiftUI's menu
/// Picker sizes its button to its current title, leaving short weights much
/// narrower than the font selector even with the same frame on both views.
private struct MixedPairPopUp: NSViewRepresentable {
    static let styleWidth: CGFloat = 92
    static let height: CGFloat = 30

    struct Option: Equatable {
        let id: String?
        let title: String
    }

    let title: String
    let options: [Option]
    @Binding var selection: String?
    var enabled = true

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> PopUpContainer {
        let container = PopUpContainer()
        let button = container.button
        button.target = context.coordinator
        button.action = #selector(Coordinator.didChange(_:))
        button.cell?.lineBreakMode = .byTruncatingTail
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopUpContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? Self.styleWidth, height: Self.height)
    }

    func updateNSView(_ container: PopUpContainer, context: Context) {
        let button = container.button
        let coordinator = context.coordinator
        coordinator.selection = $selection
        if coordinator.options != options {
            button.removeAllItems()
            for option in options { button.addItem(withTitle: option.title) }
            coordinator.options = options
        }
        let selectedIndex = options.firstIndex { $0.id == selection } ?? 0
        if button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
    }

    /// Keep the button's actual frame inside the fixed-width hosting view.
    /// A bare NSPopUpButton can report a wider intrinsic size based on its
    /// longest menu item and draw outside SwiftUI's frame.
    final class PopUpContainer: NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)

        init() {
            super.init(frame: .zero)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.heightAnchor.constraint(equalToConstant: 26),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<String?>
        var options: [Option] = []

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        @objc func didChange(_ button: NSPopUpButton) {
            guard options.indices.contains(button.indexOfSelectedItem) else { return }
            selection.wrappedValue = options[button.indexOfSelectedItem].id
        }
    }
}

/// The library window's toolbar button: fills the draft with the fonts a new
/// pair starts from and opens the mixed-pair window.
struct NewMixedPairButton: View {
    @ObservedObject var catalog: FontCatalog
    @EnvironmentObject private var draft: MixedPairDraft
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            draft.begin(with: catalog.defaultMixedPairFamilies(), from: NSApp.keyWindow)
            openWindow(id: MixedPairWindow.id)
        } label: {
            Label(String(localized: "Mixed Font"), systemImage: "rectangle.on.rectangle")
        }
        .help(String(localized: "Create a mixed-font pair"))
    }
}

/// Paints the window behind the content, titlebar included, with the specimen
/// canvas color. Without a chosen color the standard window chrome returns.
/// Applies once per color: rewriting the window's background mid-layout (e.g.
/// during the sidebar toggle animation) interrupts the animation and takes the
/// window frame with it.
private struct WindowCanvas: NSViewRepresentable {
    let color: Color?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let key = color.map { String(describing: $0) } ?? "system"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else {
                context.coordinator.lastKey = nil
                return
            }
            // The header stays transparent in every palette, so the titlebar, the
            // toolbar items, and the content read as one surface.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = color.map { NSColor($0) } ?? .windowBackgroundColor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastKey: String?
    }
}
