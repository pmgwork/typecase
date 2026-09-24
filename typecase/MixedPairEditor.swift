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
    @Published private(set) var savedPairSelectionID: FontFamily.ID?
    weak var originatingWindow: NSWindow?

    /// Seeds the editor with the fonts a new pair starts from.
    func begin(with defaults: [MixedScript: FontFaceReference], from window: NSWindow?) {
        selections = defaults
        previewText = ""
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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            scriptList
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            preview
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 480)
        // The chosen specimen background paints the whole window, so the rows
        // and the specimen sit on the same canvas the library uses.
        .background(canvasColor)
        .background { WindowCanvas(color: settings.previewBackgroundColor) }
        // Cancel and Save live in the window's own toolbar, at the top right, in
        // the same glass capsules the library window's toolbar items use.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.glassProminent)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var canvasColor: Color {
        settings.previewBackgroundColor ?? Color(nsColor: .windowBackgroundColor)
    }

    // MARK: - Parts

    /// The parts of the mix, each with the font and weight that draws it. No
    /// fixed width here: the column width owns the sizing, so dragging the
    /// divider never fights the content.
    private var scriptList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(MixedScript.allCases, id: \.self) { script in
                VStack(alignment: .leading, spacing: 4) {
                    Text(script.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    fontMenu(script, selection: familyBinding(for: script))
                    styleMenu(script, selection: faceBinding(for: script))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Push the rows to the top; without the spacer the stack centers
            // itself in the sidebar column.
            Spacer(minLength: 0)
        }
        .padding(20)
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
            title: "\(script.title) font",
            options: [MixedPairPopUp.Option(id: nil, title: "None")]
                + catalog.families(for: script).map { .init(id: $0.id, title: $0.name) },
            selection: selection
        )
        .frame(width: MixedPairPopUp.width, height: MixedPairPopUp.height)
        .help("Choose the \(script.title.lowercased()) font")
    }

    /// Every style pop-up keeps the same width as its font pop-up, even when its
    /// current style name is short (e.g. W6 or Regular).
    private func styleMenu(
        _ script: MixedScript,
        selection: Binding<String?>
    ) -> some View {
        let family = family(for: script)
        return MixedPairPopUp(
            title: "\(script.title) style",
            options: family?.faces.map { .init(id: $0.postScriptName, title: $0.styleName) }
                ?? [.init(id: nil, title: "No style")],
            selection: selection,
            enabled: family != nil
        )
        .frame(width: MixedPairPopUp.width, height: MixedPairPopUp.height)
        .help("Choose the \(script.title.lowercased()) weight")
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
                size: settings.previewSize,
                fonts: fonts(for: faces),
                textColor: settings.previewTextColor
            )
        } else {
            Text("Choose a Japanese and an English font to see the mix.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                .padding(20)
        }
    }

    private func fonts(for faces: [MixedScript: FontFace]) -> [MixedScript: PreviewFaceSpec] {
        faces.reduce(into: [:]) { result, entry in
            result[entry.key] = PreviewFaceSpec(
                postScriptName: entry.value.postScriptName,
                fileURL: entry.value.fileURL,
                variations: settings.variationValues(for: entry.value)
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
        guard let pair = catalog.addMixedPair(references: references) else { return }
        draft.didSave(pair)
        dismiss()
    }
}

/// A native AppKit pop-up with a consistent, compact width. SwiftUI's menu
/// Picker sizes its button to its current title, leaving short weights much
/// narrower than the font selector even with the same frame on both views.
private struct MixedPairPopUp: NSViewRepresentable {
    static let width: CGFloat = 200
    static let height: CGFloat = 34

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
        CGSize(width: Self.width, height: Self.height)
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
    /// longest menu item and draw outside SwiftUI's 200 pt frame.
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
            Label("Mixed Font", systemImage: "rectangle.on.rectangle")
        }
        .help("Create a mixed-font pair")
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
