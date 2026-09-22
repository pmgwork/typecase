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

    /// Seeds the editor with the fonts a new pair starts from.
    func begin(with defaults: [MixedScript: FontFaceReference]) {
        selections = defaults
        previewText = ""
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

    /// One part's font picker: the families that can fill it, in name order,
    /// with the current choice shown in a native pop-up button. Choosing a
    /// family resets the weight to its default mixed face (Regular, or W4 for
    /// Hiragino Sans).
    private func fontMenu(
        _ script: MixedScript,
        selection: Binding<FontFamily.ID?>
    ) -> some View {
        Picker(script.title, selection: selection) {
            Text("None").tag(FontFamily.ID?.none)
            ForEach(catalog.families(for: script)) { family in
                Text(family.name).tag(Optional(family.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Choose the \(script.title.lowercased()) font")
    }

    /// One part's weight picker: the styles of the chosen family, light to
    /// heavy. Disabled while no family is chosen.
    private func styleMenu(
        _ script: MixedScript,
        selection: Binding<String?>
    ) -> some View {
        Picker("\(script.title) style", selection: selection) {
            if let family = family(for: script) {
                ForEach(family.faces) { face in
                    Text(face.styleName).tag(Optional(face.postScriptName))
                }
            } else {
                Text("No style").tag(String?.none)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(family(for: script) == nil)
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
                      let face = family.defaultMixedFace ?? family.faces.first else {
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
        guard catalog.addMixedPair(references: references) != nil else { return }
        dismiss()
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
            draft.begin(with: catalog.defaultMixedPairFamilies())
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
