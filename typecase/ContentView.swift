import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var mixedPairDraft: MixedPairDraft
    @StateObject private var viewState = LibraryViewState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorVisible = true
    @State private var comparisonVisible = false
    @State private var window: NSWindow?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(catalog: catalog, viewState: viewState)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            // The inspector belongs to the detail column. Attached to the whole
            // split view, it shifts the sidebar's rows and section headers past
            // the leading edge, clipping the disclosure arrows.
            FontLibraryView(catalog: catalog, viewState: viewState)
                .inspector(isPresented: $inspectorVisible) {
                    FontInspector(catalog: catalog, viewState: viewState, comparisonVisible: $comparisonVisible)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                }
        }
        .navigationTitle("TypeCase")
        // Preserve the principal region so trailing controls stay right-aligned.
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Keep the window's minimum size independent of sidebar and inspector visibility.
        // Otherwise AppKit changes the window frame when a split-view column is restored.
        // The width fits every column at its minimum: 190 + 480 + 280.
        .frame(minWidth: 950, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
            // Keep the size control separate from the button groups so it reads
            // as its own control instead of merging into their background.
            ToolbarItem(placement: .navigation) {
                PreviewSizeControl(size: $settings.previewSize)
                    .padding(.trailing, 8)
            }
            .sharedBackgroundVisibility(.hidden)

            // The specimen colors keep their own item so the swatch is not
            // drawn inside the button group's shared background.
            ToolbarItem(placement: .navigation) {
                PreviewColorsControl()
                    .padding(.trailing, 8)
            }
            .sharedBackgroundVisibility(.hidden)

            // On macOS, confirmationAction is the trailing toolbar region;
            // navigation items stay on the leading side.
            ToolbarItem(placement: .confirmationAction) {
                LibraryFilterMenu(viewState: viewState)
            }

            ToolbarItem(placement: .confirmationAction) {
                if catalog.isUpdatingActivation {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: "\(catalog.activationCompletedFiles)/\(catalog.activationTotalFiles)")
                            .monospacedDigit()
                            .font(.caption)
                    }
                    .accessibilityLabel(String(localized: "Change Font Activation"))
                    .help(String(localized: "Change Font Activation"))
                }
            }

            ToolbarSpacer(.fixed, placement: .confirmationAction)

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label(String(localized: "Inspector"), systemImage: "info.circle")
                }
                .help(String(localized: "Show or hide the inspector"))
            }

            ToolbarSpacer(.fixed, placement: .confirmationAction)

            ToolbarItem(placement: .confirmationAction) {
                ToolbarSearchField(text: $viewState.searchText)
                    .frame(width: 220)
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $comparisonVisible) {
            ComparisonView(
                viewState: viewState,
                families: viewState.selectedFamilies(catalog: catalog)
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFontFolder)) { _ in
            // The File menu command is not tied to a window; only the frontmost
            // library window navigates to the newly added folder, even while
            // another window is key.
            guard let window, window === LibraryWindows.frontmost else { return }
            window.makeKeyAndOrderFront(nil)
            catalog.addFolder { url in viewState.librarySelection = .folder(url) }
        }
        .task {
            viewState.restoreStartupState(from: settings)
            viewState.reconcile(with: catalog, settings: settings)
        }
        .background(WindowAccessor {
            window = $0
            if let window = $0 { LibraryWindows.register(window) }
        })
        .onChange(of: catalog.isLoading) { _, loading in
            if !loading { viewState.reconcileDestination(with: catalog, settings: settings) }
        }
        .onChange(of: catalog.familiesRevision) { _, _ in
            viewState.reconcile(with: catalog, settings: settings)
        }
        .onChange(of: catalog.dataRevision) { _, _ in
            // Renaming or deleting a tag removes the destination the sidebar shows.
            viewState.reconcileDestination(with: catalog, settings: settings)
        }
        .onChange(of: viewState.librarySelection) { _, selection in
            settings.remember(location: selection)
        }
        .onChange(of: viewState.selection) { _, selection in
            settings.remember(selection: selection)
        }
        .onChange(of: mixedPairDraft.savedPairSelectionID) { _, id in
            guard let id, window === mixedPairDraft.originatingWindow else { return }
            if !settings.showMixedSection { settings.showMixedSection = true }
            viewState.searchText = ""
            viewState.librarySelection = .section(.mixed)
            viewState.selection = [id]
        }
        // Every library window observes the catalog; only the frontmost one
        // presents its error, so the alert appears once.
        .alert("TypeCase", isPresented: Binding(
            get: { catalog.errorMessage != nil && window != nil && window === LibraryWindows.frontmost },
            set: { if !$0 { catalog.errorMessage = nil } }
        )) {
            Button(String(localized: "OK")) { catalog.errorMessage = nil }
        } message: {
            Text(catalog.errorMessage ?? "")
        }
    }
}

/// A compact native search field placed with the leading toolbar controls.
/// SwiftUI's toolbar `.searchable` consumes the toolbar's flexible space, which
/// is too wide for this library and sits at the trailing edge.
private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search")
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        // The clear button and Esc change the text without a text-change
        // notification; they only send the action.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func searchChanged(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }
    }
}

/// Compact preview-size control for the toolbar with a slider and point input.
/// Also used by the mixed-pair window for its own specimen size.
struct PreviewSizeControl: View {
    @Binding var size: Double
    @State private var sizeText = ""
    @FocusState private var isEditingSize: Bool

    /// A continuous slider keeps the system from drawing step tick marks below
    /// the track; the value still snaps to whole points.
    private var roundedSize: Binding<Double> {
        Binding(
            get: { size },
            set: { size = $0.rounded() }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("A")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)

            Slider(value: roundedSize, in: AppSettings.previewSizeRange)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 96)
                .accessibilityLabel(String(localized: "Preview size"))

            HStack(spacing: 3) {
                // No visible title; a String keeps it out of the string catalog.
                TextField(String(), text: $sizeText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 24)
                    .focused($isEditingSize)
                    .accessibilityLabel(String(localized: "Preview size"))
                    .onSubmit {
                        commitSize()
                        isEditingSize = false
                    }
                    .onExitCommand {
                        sizeText = String(Int(size))
                        isEditingSize = false
                    }
                Text(verbatim: "pt")
                    .font(.system(size: 10))
            }
                .foregroundStyle(.secondary)
        }
        .frame(height: 20)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .glassEffect(.regular, in: .capsule)
        .help(String(localized: "Preview size: \(Int(size)) pt"))
        .onAppear { sizeText = String(Int(size)) }
        .onChange(of: size) { _, value in sizeText = String(Int(value)) }
        .onChange(of: isEditingSize) { _, editing in
            if !editing { commitSize() }
        }
    }

    private func commitSize() {
        if let value = Double(sizeText), value.isFinite {
            size = min(max(value.rounded(), AppSettings.previewSizeRange.lowerBound), AppSettings.previewSizeRange.upperBound)
        }
        sizeText = String(Int(size))
    }
}

/// The copy actions shared by the font row's context menu and the inspector:
/// the names a designer needs when using the font somewhere else.
private struct FontNameCopyItems: View {
    @EnvironmentObject private var catalog: FontCatalog
    let family: FontFamily

    var body: some View {
        Button(String(localized: "Family Name")) {
            catalog.copyStrings([family.name])
        }
        Button(String(localized: "English Name")) {
            catalog.copyStrings([family.localizedName])
        }
        Button(String(localized: "PostScript Names")) {
            catalog.copyStrings(family.faces.map(\.postScriptName))
        }
        Button(String(localized: "CSS font-family")) {
            catalog.copyStrings(["font-family: \"\(family.name)\";"])
        }
    }
}

/// The specimen colors in the toolbar: the left half of the swatch is the
/// background, the right half the text color. Each half opens a color popover.
private struct PreviewColorsControl: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        swatch
            .overlay {
                HStack(spacing: 0) {
                    SpecimenColorPicker(color: $settings.previewBackgroundColor,
                                        fallback: Color(nsColor: .windowBackgroundColor), title: String(localized: "Background Color")) {
                        Color.clear.frame(width: 27, height: 36).contentShape(.rect)
                    }
                    SpecimenColorPicker(color: $settings.previewTextColor,
                                        fallback: Color(nsColor: .labelColor), title: String(localized: "Text Color")) {
                        Color.clear.frame(width: 27, height: 36).contentShape(.rect)
                    }
                }
            }
            .contextMenu {
                Button(String(localized: "System")) { settings.setPreviewColors(background: nil, text: nil) }
                Button(String(localized: "Light")) { settings.setPreviewColors(background: .white, text: .black) }
                Button(String(localized: "Dark")) {
                    settings.setPreviewColors(
                        background: Color(red: 0.11, green: 0.11, blue: 0.12), text: .white
                    )
                }
            }
    }

    /// Shows the system colors while the specimens follow the appearance.
    private var backgroundSwatch: Color {
        settings.previewBackgroundColor ?? Color(nsColor: .windowBackgroundColor)
    }

    private var textSwatch: Color {
        settings.previewTextColor ?? Color(nsColor: .labelColor)
    }

    private var swatch: some View {
        splitSwatch
            .frame(width: 54, height: 36)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// The specimens' colors as a single rounded swatch: the background on the
    /// left, the text color on the right.
    private var splitSwatch: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(backgroundSwatch)
            Rectangle()
                .fill(textSwatch)
        }
        .frame(width: 34, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .contentShape(.rect)
    }

}

private extension View {
    /// Shows a sidebar add button only while the pointer is over its row or
    /// header, so the rows read like their neighbors at rest. VoiceOver still
    /// reaches the hidden button.
    func revealedOnHover(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}

private struct Sidebar: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("systemScopesExpanded") private var systemScopesExpanded = true
    @AppStorage("foldersExpanded") private var foldersExpanded = true
    @AppStorage("tagsExpanded") private var tagsExpanded = true
    @State private var isDropTargeted = false
    @State private var isAddingTag = false
    @State private var newTagName = ""
    @FocusState private var newTagNameFocused: Bool
    @State private var tagBeingRenamed: String?
    @State private var renamedTagName = ""
    @State private var isMixedRowHovered = false
    @State private var isFoldersHeaderHovered = false
    @State private var isTagsHeaderHovered = false

    /// Show only detected services that the user has left visible.
    private var providerSections: [LibrarySection] {
        catalog.availableProviders
            .filter { settings.isProviderSectionVisible($0.id) }
            .map { .provider($0) }
    }

    var body: some View {
        List(selection: $viewState.librarySelection) {
            Section {
                if settings.showAllSection { sectionRow(.all) }
                if settings.showFavoritesSection { sectionRow(.favorites) }
                if settings.showMixedSection { mixedRow }
                if settings.showDuplicatesSection { sectionRow(.duplicates) }
                if (settings.showAllSection || settings.showFavoritesSection
                    || settings.showMixedSection || settings.showDuplicatesSection)
                    && (settings.showSystemSection || settings.showLocalSection) {
                    Divider()
                        .selectionDisabled()
                }
                if settings.showSystemSection { systemGroup }
                if settings.showLocalSection { sectionRow(.local) }
            }

            if !providerSections.isEmpty {
                Section {
                    ForEach(providerSections) { section in
                        sectionRow(section)
                    }
                } header: {
                    Text(String(localized: "Providers"))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }

            Section {
                if foldersExpanded {
                    if catalog.folders.isEmpty {
                        SidebarLabel(title: String(localized: "Drop folders here"), systemImage: "plus")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    } else {
                        OutlineGroup(catalog.folderTrees, children: \.children) { node in
                            Label {
                                Text(verbatim: node.url.lastPathComponent)
                                    .foregroundStyle(Color(nsColor: .labelColor))
                            } icon: {
                                FolderActivationControl(catalog: catalog, folder: node.url)
                            }
                                .font(.system(size: NSFont.systemFontSize))
                                .lineLimit(1)
                                .background(TableRowEmphasisConfigurator())
                                .badge(selectedCount(for: .folder(node.url)))
                                .tag(LibrarySelection.folder(node.url))
                                .help(node.url.path)
                                .contextMenu {
                                    FolderActivationActions(catalog: catalog, folder: node.url)
                                    Divider()
                                    Button(String(localized: "Show in Finder")) { catalog.revealFolder(node.url) }
                                    if catalog.folders.contains(where: { $0.standardizedFileURL == node.url.standardizedFileURL }) {
                                        Divider()
                                        Button(String(localized: "Remove"), role: .destructive) {
                                            if case .folder(let selected) = viewState.librarySelection,
                                               selected.isContained(in: node.url) {
                                                viewState.librarySelection = .section(.local)
                                            }
                                            catalog.removeFolder(node.url)
                                        }
                                    }
                                }
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text(String(localized: "Folders"))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    Spacer(minLength: 0)
                    headerControls {
                        Button {
                            catalog.addFolder { url in viewState.librarySelection = .folder(url) }
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .frame(width: 24, height: 24)
                        .help(String(localized: "Add a font folder"))
                        .accessibilityLabel(String(localized: "Add a font folder"))
                        .revealedOnHover(isFoldersHeaderHovered)

                        disclosureButton(isExpanded: $foldersExpanded, title: String(localized: "Folders"))
                    }
                }
                .padding(.trailing, 12)
                .contentShape(Rectangle())
                .onHover { isFoldersHeaderHovered = $0 }
            }

            if settings.showTagsSection {
                Section {
                    if tagsExpanded {
                        ForEach(catalog.allTags, id: \.self) { tag in
                            SidebarLabel(title: tag, systemImage: "tag")
                                .background(TableRowEmphasisConfigurator())
                                .badge(selectedCount(for: .tag(tag)))
                                .tag(LibrarySelection.tag(tag))
                                .contextMenu {
                                    Button(String(localized: "Rename Tag…")) { beginRenaming(tag) }
                                    Divider()
                                    Button(String(localized: "Delete Tag"), role: .destructive) { deleteTag(tag) }
                                }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(String(localized: "Tags"))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        Spacer(minLength: 0)
                        headerControls {
                            Button {
                                beginCreatingTag()
                            } label: {
                                Image(systemName: "plus")
                            }
                            .frame(width: 24, height: 24)
                            .help(String(localized: "Add a tag"))
                            .accessibilityLabel(String(localized: "Add a tag"))
                            .popover(isPresented: $isAddingTag, arrowEdge: .top) {
                                addTagForm
                            }
                            // Stays visible while its popover is open.
                            .revealedOnHover(isTagsHeaderHovered || isAddingTag)

                            disclosureButton(isExpanded: $tagsExpanded, title: String(localized: "Tags"))
                        }
                    }
                    .padding(.trailing, 12)
                    .contentShape(Rectangle())
                    .onHover { isTagsHeaderHovered = $0 }
                }
            }
        }
        // Keep the native source-list interaction while using its neutral
        // inactive selection appearance instead of an accent-color fill.
        .environment(\.controlActiveState, .inactive)
        .listStyle(.sidebar)
        .onChange(of: systemScopesExpanded) { _, expanded in
            // Collapsing while a scope is visible moves the selection to the
            // parent row so the list and the sidebar still agree.
            if !expanded, case .systemScope = viewState.librarySelection {
                viewState.librarySelection = .section(.system)
            }
        }
        .onChange(of: settings.visibleSidebarSections) { _, sections in
            // Hiding a destination moves the selection to the first row that is
            // still visible.
            guard !settings.isSidebarItemVisible(viewState.librarySelection),
                  let fallback = sections.first(where: { section in
                      guard let provider = section.provider else { return true }
                      return catalog.availableProviders.contains(where: { $0.id == provider.id })
                  }) else { return }
            viewState.librarySelection = .section(fallback)
        }
        .onAppear {
            // A restored system scope must be visible; a collapsed group has no
            // row to select.
            if !systemScopesExpanded, case .systemScope = viewState.librarySelection {
                viewState.librarySelection = .section(.system)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let added = catalog.addFolders(urls) else { return false }
            viewState.librarySelection = .folder(added)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .alert(String(localized: "Rename Tag"), isPresented: renameTagAlertPresented) {
            TextField(String(localized: "Name"), text: $renamedTagName)
            Button(String(localized: "Rename")) { commitTagRename() }
            Button(String(localized: "Cancel"), role: .cancel) { tagBeingRenamed = nil }
        } message: {
            Text(String(localized: "The tag is renamed on every font that uses it."))
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func sectionRow(_ section: LibrarySection) -> some View {
        let selection = LibrarySelection.section(section)
        return SidebarLabel(title: section.title, icon: section.icon)
            .background(TableRowEmphasisConfigurator())
            .badge(selectedCount(for: selection))
            .tag(selection)
    }

    /// The Mixed Fonts row carries its add button, like the Folders and Tags
    /// headers, and shows it the same way: on hover.
    private var mixedRow: some View {
        let selection = LibrarySelection.section(.mixed)
        return HStack(spacing: 6) {
            SidebarLabel(title: LibrarySection.mixed.title, icon: LibrarySection.mixed.icon)
            Spacer(minLength: 6)
            NewMixedPairButton(catalog: catalog)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 20, height: 24)
                .revealedOnHover(isMixedRowHovered)
        }
        .contentShape(Rectangle())
        .onHover { isMixedRowHovered = $0 }
        .background(TableRowEmphasisConfigurator())
        .badge(selectedCount(for: selection))
        .tag(selection)
    }

    /// The System Fonts disclosure group, including its installation scopes.
    private var systemGroup: some View {
        DisclosureGroup(isExpanded: $systemScopesExpanded) {
            ForEach(SystemFontScope.allCases, id: \.self) { scope in
                // Indent with a spacer instead of leading padding: a padded row is
                // treated as a nested sidebar row and rendered with a smaller font.
                HStack(spacing: 0) {
                    Color.clear.frame(width: 20, height: 1)
                    SidebarLabel(title: scope.title, icon: scope.icon)
                }
                .background(TableRowEmphasisConfigurator())
                .badge(selectedCount(for: .systemScope(scope)))
                .tag(LibrarySelection.systemScope(scope))
            }
        } label: {
            HStack(spacing: 6) {
                SidebarLabel(title: LibrarySection.system.title, icon: LibrarySection.system.icon)
                Spacer(minLength: 6)
                if viewState.librarySelection == .section(.system) {
                    Text("\(catalog.fontCount(for: .section(.system)))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .background(TableRowEmphasisConfigurator())
            .tag(LibrarySelection.section(.system))
        }
    }


    private func selectedCount(for selection: LibrarySelection) -> Int {
        guard viewState.librarySelection == selection else { return 0 }
        return catalog.fontCount(for: selection)
    }

    private func headerControls<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        // The buttons' 24pt frames already space the icons apart.
        HStack(spacing: 0) {
            content()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func disclosureButton(
        isExpanded: Binding<Bool>,
        title: String
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                .frame(width: 24, height: 24)
        }
        .frame(width: 24, height: 24)
        .help(isExpanded.wrappedValue ? String(localized: "Collapse \(title)") : String(localized: "Expand \(title)"))
        .accessibilityLabel(isExpanded.wrappedValue ? String(localized: "Collapse \(title)") : String(localized: "Expand \(title)"))
    }

    private var addTagForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Name"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(String(localized: "e.g. serif, display, favorites"), text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .focused($newTagNameFocused)
            }

            HStack {
                Button(String(localized: "Cancel")) { isAddingTag = false }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button(String(localized: "Add")) { addTag() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedNewTagName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 280)
        .defaultFocus($newTagNameFocused, true)
    }

    private var trimmedNewTagName: String {
        newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var renameTagAlertPresented: Binding<Bool> {
        Binding(
            get: { tagBeingRenamed != nil },
            set: { if !$0 { tagBeingRenamed = nil } }
        )
    }

    private func beginCreatingTag() {
        newTagName = ""
        isAddingTag = true
    }

    private func beginRenaming(_ tag: String) {
        renamedTagName = tag
        tagBeingRenamed = tag
    }

    private func addTag() {
        guard !trimmedNewTagName.isEmpty else { return }
        catalog.createTag(newTagName)
        isAddingTag = false
    }

    private func commitTagRename() {
        guard let tag = tagBeingRenamed else { return }
        tagBeingRenamed = nil
        guard let newName = catalog.renameTag(tag, to: renamedTagName) else { return }
        if viewState.librarySelection == .tag(tag) {
            viewState.librarySelection = .tag(newName)
        }
    }

    private func deleteTag(_ tag: String) {
        if viewState.librarySelection == .tag(tag) {
            viewState.librarySelection = .section(.all)
        }
        catalog.deleteTag(tag)
    }
}

private struct FontLibraryView: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var environmentUndoManager
    @FocusState private var listFocused: Bool
    @State private var expandedFamilyID: FontFamily.ID?
    @State private var cleanupDuplicates: [FontDuplicate] = []
    @State private var showsDuplicateCleanup = false
    @State private var quickLook = QuickLookController()

    private var visibleIDs: [FontFamily.ID] {
        if isMixedSection { return filteredMixedPairs.map(\.selectionID) }
        return viewState.filter(catalog: catalog, favoritesFirst: settings.favoritesFirst, activatedFirst: settings.activatedFirst)
            .ids
    }

    var body: some View {
        VStack(spacing: 0) {
            let output = viewState.filter(catalog: catalog, favoritesFirst: settings.favoritesFirst, activatedFirst: settings.activatedFirst)
            if isMixedSection {
                mixedPairsContent
            } else if output.families.isEmpty {
                emptyState(output: output)
            } else {
                List(selection: familySelection) {
                    ForEach(output.families) { family in
                        FontFamilyRow(
                            family: family,
                            isExpanded: expandedFamilyID == family.id,
                            isUpdatingActivation: catalog.isUpdatingActivation,
                            previewText: settings.effectivePreviewText(for: family, entered: viewState.previewText),
                            previewSize: settings.previewSize,
                            previewTextColor: settings.previewTextColor,
                            isSelected: viewState.selection.contains(family.id),
                            selectionTint: selectionTint,
                            isFavorite: catalog.isFavorite(family),
                            variations: settings.variationValues(for: family.faces),
                            toggleExpanded: { toggleExpanded(family) },
                            toggleFavorite: {
                                let targets = viewState.selection.contains(family.id)
                                    ? output.families.filter { viewState.selection.contains($0.id) }
                                    : [family]
                                catalog.setFavorite(!targets.allSatisfy { catalog.isFavorite($0) }, families: targets)
                            },
                            toggleEnabled: {
                                setEnabled(!family.isEnabled || family.isPartiallyEnabled, families: [family])
                            },
                            toggleFaceEnabled: { face in
                                setEnabled(!face.isInstalled, faces: [face], in: family)
                            },
                            loadVariableInfo: { await catalog.variableInfo(for: $0) },
                            setVariation: { value, tag, face in
                                settings.setVariation(value, tag: tag, for: face.postScriptName)
                            },
                            resetVariations: { settings.resetVariations(for: $0.postScriptName) }
                        )
                            .equatable()
                            .tag(family.id)
                    }
                }
                .contextMenu(forSelectionType: FontFamily.ID.self) { ids in
                    fontContextMenu(for: ids, among: output.families)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
                .environment(\.controlActiveState, .key)
                .focused($listFocused)
                // Space toggles Quick Look as in Finder; the panel follows the
                // selection, so the arrow keys keep moving through the list.
                .onKeyPress(.space) {
                    quickLook.toggle(catalog: catalog, viewState: viewState, settings: settings)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard quickLook.isVisible else { return .ignored }
                    quickLook.close()
                    return .handled
                }
                .simultaneousGesture(TapGesture().onEnded {
                    // A click into a field in a row, such as an axis value,
                    // has already given it the keyboard; don't take it back.
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor { return }
                    listFocused = true
                })
                .onChange(of: viewState.selection) { _, selection in
                    // Styles stay expanded only for the selected font.
                    guard let expanded = expandedFamilyID, selection != [expanded] else { return }
                    expandedFamilyID = nil
                }
            }
        }
        // The preview-text editor stays pinned below the font list area, in
        // every state of the list, so text can always be edited or cleared
        // even while it filters every font out.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            previewTextEditor
        }
        .sheet(isPresented: $showsDuplicateCleanup) {
            DuplicateCleanupView(catalog: catalog, duplicates: cleanupDuplicates)
        }
        // The chosen background paints the whole font list area, so specimens
        // sit directly on it. The inspector keeps the system surface.
        .background(canvasColor)
        // Coverage depends on the preview text and the family list, so the check
        // is requested here rather than from inside the cached filter.
        .task(id: viewState.coverageRequest(catalog: catalog)) {
            viewState.updateCoverage(catalog: catalog)
        }
        .onAppear { reconcileSelection() }
        .onDisappear { quickLook.close() }
        .onChange(of: visibleIDs) { _, ids in
            reconcileSelection(with: ids)
        }
        .onChange(of: viewState.selection) { _, _ in
            reconcileSelection()
        }
        .onChange(of: catalog.isLoading) { _, _ in
            reconcileSelection()
        }
        .navigationSplitViewColumnWidth(min: 480, ideal: 640)
    }

    /// The Mixed Fonts destination lists saved Japanese + Latin combinations
    /// instead of the library's families.
    private var isMixedSection: Bool {
        viewState.librarySelection == .section(.mixed)
    }

    private func reconcileSelection(with ids: [FontFamily.ID]? = nil) {
        guard !catalog.isLoading || !catalog.families.isEmpty else { return }
        viewState.reconcileVisibleSelection(with: ids ?? visibleIDs)
    }

    /// The font list's selection holds family ids only. A pair selected in the
    /// Mixed Fonts section stays in the stored selection but is not offered to
    /// this list, which cannot show it.
    private var familySelection: Binding<Set<FontFamily.ID>> {
        Binding(
            get: { viewState.selection.filter { !FontPair.isSelectionID($0) } },
            set: { viewState.selection = $0 }
        )
    }

    /// A selection-based menu belongs to the List rather than a row's SwiftUI
    /// view. This avoids the extra outlined row preview on secondary-click.
    @ViewBuilder
    private func fontContextMenu(for ids: Set<FontFamily.ID>, among families: [FontFamily]) -> some View {
        let targets = families.filter { ids.contains($0.id) }
        let fileURLs = Array(Set(targets.flatMap(\.fileURLs))).sorted { $0.path < $1.path }
        if let family = targets.first {
            Button(String(localized: "Quick Look")) {
                if !ids.isSubset(of: viewState.selection) { viewState.selection = [family.id] }
                quickLook.show(catalog: catalog, viewState: viewState, settings: settings)
            }
            Divider()
            let duplicates = targets.flatMap { catalog.duplicatesByFamily[$0.id] ?? [] }
            if !duplicates.isEmpty {
                Button(String(localized: "Clean Up Duplicates…")) {
                    cleanupDuplicates = duplicates
                    showsDuplicateCleanup = true
                }
                .disabled(catalog.isLoading || catalog.isUpdatingActivation)
                Divider()
            }
            Button(String(localized: "Activate \(targets.count) Fonts")) {
                setEnabled(true, families: targets)
            }
            .disabled(catalog.isUpdatingActivation || !targets.contains(where: \.canActivate))

            Button(String(localized: "Deactivate \(targets.count) Fonts")) {
                setEnabled(false, families: targets)
            }
            .disabled(catalog.isUpdatingActivation || !targets.contains(where: \.canDeactivate))

            Divider()

            Button {
                catalog.setFavorite(true, families: targets)
            } label: {
                Label(String(localized: "Add to Favorites"), systemImage: "star")
            }
            .disabled(targets.allSatisfy { catalog.isFavorite($0) })

            Button {
                catalog.setFavorite(false, families: targets)
            } label: {
                Label(String(localized: "Remove from Favorites"), systemImage: "star.slash")
            }
            .disabled(!targets.contains { catalog.isFavorite($0) })

            Divider()

            Menu(String(localized: "Tags")) {
                if catalog.allTags.isEmpty {
                    Text(String(localized: "No Tags"))
                }
                ForEach(catalog.allTags, id: \.self) { tag in
                    Toggle(tag, isOn: tagBinding(tag, families: targets))
                }
            }

            Divider()

            Button(String(localized: "Show in Finder")) {
                catalog.revealFiles(fileURLs)
            }
            .disabled(fileURLs.isEmpty)

            Button(String(localized: "Copy Path")) {
                catalog.copyPaths(fileURLs)
            }
            .disabled(fileURLs.isEmpty)

            Divider()

            Menu(String(localized: "Copy Name")) {
                FontNameCopyItems(family: family)
            }
            .disabled(targets.count != 1)
        }
    }

    /// The Mixed Fonts list's selection holds pair ids only.
    private var mixedPairSelection: Binding<Set<FontFamily.ID>> {
        Binding(
            get: { viewState.selection.filter(FontPair.isSelectionID) },
            set: { viewState.selection = $0 }
        )
    }

    // MARK: - Mixed pairs

    @ViewBuilder
    private var mixedPairsContent: some View {
        let pairs = filteredMixedPairs
        if pairs.isEmpty {
            mixedEmptyState
        } else {
            List(selection: mixedPairSelection) {
                ForEach(pairs) { pair in
                    mixedPairRow(pair)
                        .equatable()
                        .tag(pair.selectionID)
                }
            }
            // Like the font list, the menu belongs to the List so secondary-click
            // does not outline the row.
            .contextMenu(forSelectionType: FontFamily.ID.self) { ids in
                let targets = pairs.filter { ids.contains($0.selectionID) }
                Button(targets.count > 1 ? String(localized: "Delete \(targets.count) Pairs") : String(localized: "Delete"), role: .destructive) {
                    targets.forEach(deleteMixedPair)
                }
                .disabled(targets.isEmpty)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.inset)
            .environment(\.controlActiveState, .key)
        }
    }

    private func mixedPairRow(_ pair: FontPair) -> MixedPairRow {
        var faces: [MixedScript: FontFace] = [:]
        for entry in pair.references {
            if let face = catalog.face(for: entry.reference) {
                faces[entry.script] = face
            }
        }
        return MixedPairRow(
            pair: pair,
            japaneseName: japaneseName(for: pair),
            latinName: latinName(for: pair),
            faces: faces,
            variations: settings.variationValues(for: Array(faces.values)),
            sourceLabel: sourceLabel(for: pair),
            previewText: settings.effectiveMixedText(entered: viewState.previewText),
            previewSize: settings.previewSize,
            previewTextColor: settings.previewTextColor,
            isSelected: viewState.selection.contains(pair.selectionID),
            selectionTint: selectionTint,
            isResolvable: faces.count == pair.references.count
        )
    }

    /// The short source labels of a pair's fonts, without repeats. System fonts
    /// carry no label, matching the font rows.
    private func sourceLabel(for pair: FontPair) -> String {
        var labels: [String] = []
        for entry in pair.references {
            guard let family = catalog.familyByID[entry.reference.familyID],
                  family.source != .system else { continue }
            let label = family.source.shortTitle
            if !labels.contains(label) { labels.append(label) }
        }
        return labels.joined(separator: " / ")
    }

    /// The saved pairs, ordered by name and narrowed by the search text, which
    /// also matches the two font names.
    private var filteredMixedPairs: [FontPair] {
        let query = viewState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.mixedPairs
            .filter { pair in
                guard !query.isEmpty else { return true }
                return name(for: pair).localizedCaseInsensitiveContains(query)
                    || japaneseName(for: pair).localizedCaseInsensitiveContains(query)
                    || latinName(for: pair).localizedCaseInsensitiveContains(query)
            }
            .sorted { name(for: $0).localizedStandardCompare(name(for: $1)) == .orderedAscending }
    }

    private func name(for pair: FontPair) -> String {
        FontPair.defaultName(japanese: japaneseName(for: pair), latin: latinName(for: pair))
    }

    @ViewBuilder
    private var mixedEmptyState: some View {
        if catalog.mixedPairs.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No mixed pairs yet"), image: "mixed.font")
            } description: {
                Text(String(localized: "Pair a Japanese font with a Latin one."))
            } actions: {
                NewMixedPairButton(catalog: catalog)
                    .labelStyle(.titleOnly)
                Button(String(localized: "Show All Fonts")) { viewState.librarySelection = .section(.all) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(String(localized: "No pairs match"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(String(localized: "Change the search text."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func japaneseName(for pair: FontPair) -> String {
        catalog.familyByID[pair.japanese.familyID]?.name ?? pair.japanese.postScriptName
    }

    private func latinName(for pair: FontPair) -> String {
        catalog.familyByID[pair.latin.familyID]?.name ?? pair.latin.postScriptName
    }

    private func deleteMixedPair(_ pair: FontPair) {
        let wasSelected = viewState.selection.contains(pair.selectionID)
        catalog.removeMixedPair(pair)
        if wasSelected {
            viewState.selection = []
            viewState.reconcile(with: catalog, settings: settings)
        }
    }

    private var previewTextEditor: some View {
        PreviewTextEditor(viewState: viewState)
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
    }

    /// The specimen canvas color: the chosen background, or the window color
    /// while the specimens follow the system appearance.
    private var canvasColor: Color {
        settings.previewBackgroundColor ?? Color(nsColor: .windowBackgroundColor)
    }

    /// Use the same selection region with the system and custom palettes.
    /// The default dark appearance gets a pure white veil; light appearance
    /// uses black so the selection remains visible on a white canvas.
    private var selectionTint: Color? {
        settings.previewTextColor ?? (colorScheme == .dark ? .white : .black)
    }


    @ViewBuilder
    private func emptyState(output: LibraryViewState.FilterOutput) -> some View {
        Group {
            if catalog.families.isEmpty && catalog.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Loading fonts…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.families.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No fonts in the library"), systemImage: "textformat")
                } description: {
                    Text(String(localized: "Installed fonts are read automatically. Add a folder to include the font files stored on disk."))
                } actions: {
                    Button(String(localized: "Add Font Folder…")) {
                        catalog.addFolder { url in viewState.librarySelection = .folder(url) }
                    }
                    Button(String(localized: "Refresh")) { catalog.refresh() }
                }
            } else if output.sectionIsEmpty {
                ContentUnavailableView {
                    Label {
                        Text(emptySectionTitle)
                    } icon: {
                        SourceIconView(
                            icon: viewState.librarySelection.icon,
                            assetSize: 48
                        )
                    }
                } description: {
                    Text(emptySectionMessage)
                } actions: {
                    if viewState.librarySelection == .section(.local) {
                        Button(String(localized: "Add Font Folder…")) {
                            catalog.addFolder { url in viewState.librarySelection = .folder(url) }
                        }
                    }
                    Button(String(localized: "Show All Fonts")) { viewState.librarySelection = .section(.all) }
                }
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No fonts match"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(filterSummary.isEmpty ? String(localized: "Change the search text or filters.") : filterSummary)
                } actions: {
                    if hasActiveToolbarFilters {
                        Button(String(localized: "Clear Filters")) { viewState.clearFilters() }
                    }
                    if !activeCoverageText.isEmpty {
                        Button(String(localized: "Clear Preview Text")) { viewState.previewText = "" }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterSummary: String {
        var parts: [String] = []
        let query = viewState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append(String(localized: "Search: “\(query)”")) }
        if let category = viewState.category { parts.append(String(localized: "Category: \(category.title)")) }
        if viewState.activationFilter != .all { parts.append(String(localized: "Status: \(viewState.activationFilter.title)")) }
        if !activeCoverageText.isEmpty { parts.append(String(localized: "Contains: “\(activeCoverageText)”")) }
        return parts.joined(separator: " · ")
    }

    /// The toolbar filters, excluding the always-on preview-text coverage.
    private var hasActiveToolbarFilters: Bool {
        !viewState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewState.category != nil
            || viewState.activationFilter != .all
    }

    private var activeCoverageText: String {
        viewState.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptySectionTitle: String {
        switch viewState.librarySelection {
        case .section(let section):
            if let provider = section.provider { return String(localized: "No \(provider.title)") }
            switch section {
            case .favorites: return String(localized: "No favorites yet")
            case .local: return String(localized: "No local fonts")
            case .duplicates: return String(localized: "No duplicates")
            default: return String(localized: "No fonts")
            }
        case .folder(let folder): return String(localized: "No fonts in \(folder.lastPathComponent)")
        case .systemScope(let scope): return String(localized: "No fonts for \(scope.title)")
        case .tag(let tag): return String(localized: "No fonts tagged “\(tag)”")
        }
    }

    private var emptySectionMessage: String {
        switch viewState.librarySelection {
        case .section(let section):
            if let provider = section.provider { return provider.emptyMessage }
            switch section {
            case .favorites: return String(localized: "Select a font and click the star to keep it here.")
            case .local: return String(localized: "Add a folder that contains font files to browse them without installing.")
            case .duplicates: return String(localized: "No font file shares a PostScript name with another file.")
            default: return String(localized: "Change the search text or filters.")
            }
        case .folder: return String(localized: "This folder does not contain any supported font files.")
        case .systemScope: return String(localized: "No fonts were found in this installation scope.")
        case .tag: return String(localized: "Assign the tag to a font from the row’s context menu, or delete the tag in the sidebar.")
        }
    }

    /// The window's undo manager, falling back to the key window while a
    /// context menu action is running.
    private var activeUndoManager: UndoManager? {
        environmentUndoManager ?? NSApp.keyWindow?.undoManager
    }

    /// Enables or disables the managed files behind the families and registers
    /// the change with the window's undo manager.
    private func setEnabled(_ enabled: Bool, families: [FontFamily]) {
        catalog.setEnabled(enabled, families: families, undoManager: activeUndoManager)
    }

    private func setEnabled(_ enabled: Bool, faces: [FontFace], in family: FontFamily) {
        catalog.setEnabled(enabled, faces: faces, in: family, undoManager: activeUndoManager)
    }

    /// Toggles an existing tag on every targeted family; the menu shows a
    /// checkmark only while all of them carry it.
    private func tagBinding(_ tag: String, families: [FontFamily]) -> Binding<Bool> {
        Binding(
            get: { families.allSatisfy { catalog.hasTag(tag, in: $0) } },
            set: { isOn in
                for family in families {
                    if isOn {
                        catalog.addTag(tag, to: family)
                    } else {
                        catalog.removeTag(tag, from: family)
                    }
                }
            }
        )
    }

    private func toggleExpanded(_ family: FontFamily) {
        expandedFamilyID = expandedFamilyID == family.id ? nil : family.id
    }
}

private extension View {
    /// Double-clicking a row's text or specimen toggles its styles. The row's
    /// buttons stay outside it, so double-clicking the star or an activation
    /// button only toggles that button.
    func togglesOnDoubleClick(_ action: @escaping () -> Void) -> some View {
        contentShape(.rect)
            // Let the List select on the first click without waiting for the
            // double-click recognizer to fail.
            .simultaneousGesture(TapGesture(count: 2).onEnded { action() })
    }
}

/// The tint of the list-row activation indicators. System green marks fonts
/// that TypeCase manages, including the lock for sources it cannot change;
/// an inactive style keeps a secondary-gray outline.
private let activationTint = Color.green

private struct FontFamilyRow: View, Equatable {
    let family: FontFamily
    let isExpanded: Bool
    let isUpdatingActivation: Bool
    let previewText: String
    let previewSize: Double
    let previewTextColor: Color?
    let isSelected: Bool
    /// The selected row's veil, shared by default and custom canvas colors.
    let selectionTint: Color?
    let isFavorite: Bool
    let variations: [FontFace.ID: [UInt32: Double]]
    let toggleExpanded: () -> Void
    let toggleFavorite: () -> Void
    let toggleEnabled: () -> Void
    let toggleFaceEnabled: (FontFace) -> Void
    let loadVariableInfo: (FontFace) async -> VariableFontInfo?
    let setVariation: (Double, UInt32, FontFace) -> Void
    let resetVariations: (FontFace) -> Void
    /// Whether the expanded row shows axis controls instead of the style list.
    @State private var expandedContent: ExpandedContent = .unknown

    private enum ExpandedContent {
        /// Still reading the faces; the row keeps its collapsed specimen.
        case unknown
        case styles
        case axes(VariableFamilyAxes)
    }

    static func == (lhs: FontFamilyRow, rhs: FontFamilyRow) -> Bool {
        lhs.family == rhs.family
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isUpdatingActivation == rhs.isUpdatingActivation
            && lhs.previewText == rhs.previewText
            && lhs.previewSize == rhs.previewSize
            && lhs.previewTextColor == rhs.previewTextColor
            && lhs.isSelected == rhs.isSelected
            && lhs.selectionTint == rhs.selectionTint
            && lhs.isFavorite == rhs.isFavorite
            && lhs.variations == rhs.variations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                activationIndicator
                HStack(spacing: 8) {
                    Text(family.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(String(localized: "\(family.faces.count) styles"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if family.source != .system {
                        Text(family.source.shortTitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .togglesOnDoubleClick(toggleExpanded)
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Favorite"))
            }
            if isExpanded {
                switch expandedContent {
                case .unknown:
                    collapsedSpecimen
                case .styles:
                    styleList
                case .axes(let axes):
                    VariableAxesPanel(
                        axes: axes,
                        stored: variations[axes.face.id] ?? [:],
                        previewText: previewText,
                        previewSize: previewSize,
                        previewTextColor: previewTextColor,
                        toggleExpanded: toggleExpanded,
                        setVariation: { value, tag in setVariation(value, tag, axes.face) },
                        reset: { resetVariations(axes.face) }
                    )
                }
            } else {
                collapsedSpecimen
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if isSelected, let selectionTint {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectionTint.opacity(0.22))
            }
        }
        // Use the same row-sized highlight for every specimen palette.
        .background(TableRowEmphasisConfigurator(
            isEmphasized: selectionTint == nil,
            hidesSelectionHighlight: selectionTint != nil
        ))
        .contentShape(.rect)
        .help(isExpanded ? String(localized: "Double-click to hide styles") : String(localized: "Double-click to show styles"))
        .task(id: isExpanded ? family : nil) { await loadExpandedContent() }
    }

    private var collapsedSpecimen: some View {
        FontPreviewText(
            text: previewText,
            postScriptName: family.previewFace?.postScriptName,
            fileURL: family.previewFace?.fileURL,
            size: previewSize,
            variations: family.previewFace.flatMap { variations[$0.id] },
            textColor: previewTextColor
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .togglesOnDoubleClick(toggleExpanded)
    }

    private var styleList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(family.faces) { face in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if face.isManaged {
                            Button {
                                toggleFaceEnabled(face)
                            } label: {
                                Image(systemName: face.isInstalled ? "circle.fill" : "circle")
                                    .font(.callout)
                                    .foregroundStyle(face.isInstalled ? activationTint : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(isUpdatingActivation)
                            .help(face.isInstalled ? String(localized: "Deactivate") : String(localized: "Activate"))
                            .frame(width: 16)
                        } else {
                            ActivationLock(hint: faceLockHint)
                        }
                        Text(face.styleName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .togglesOnDoubleClick(toggleExpanded)
                    }
                    FontPreviewText(
                        text: previewText,
                        postScriptName: face.postScriptName,
                        fileURL: face.fileURL,
                        size: previewSize,
                        variations: variations[face.id],
                        textColor: previewTextColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .togglesOnDoubleClick(toggleExpanded)
                }
            }
        }
    }

    /// A family is adjusted on its axes when every style is an instance of a
    /// variable font; a family mixing static files keeps the style list.
    private func loadExpandedContent() async {
        guard isExpanded, let previewFace = family.previewFace else { return }
        guard let info = await loadVariableInfo(previewFace) else {
            expandedContent = .styles
            return
        }
        var instances: [VariableInstance] = []
        for face in family.faces {
            guard let faceInfo = await loadVariableInfo(face) else {
                expandedContent = .styles
                return
            }
            instances.append(VariableInstance(face: face, values: faceInfo.currentValues))
        }
        guard !Task.isCancelled else { return }
        expandedContent = .axes(VariableFamilyAxes(face: previewFace, info: info, instances: instances))
    }

    @ViewBuilder
    private var activationIndicator: some View {
        if family.isManaged {
            Button {
                toggleEnabled()
            } label: {
                Image(systemName: activationSymbol)
                    .font(.callout)
                    .foregroundStyle(activationColor)
            }
            .buttonStyle(.borderless)
            .disabled(isUpdatingActivation)
            .accessibilityLabel(activationHelp)
            .help(activationHelp)
            .frame(width: 16)
        } else {
            ActivationLock(hint: family.source.managementHint)
        }
    }

    private var activationSymbol: String {
        if family.isPartiallyEnabled { return "circle.lefthalf.filled" }
        return family.isEnabled ? "circle.fill" : "circle"
    }

    private var activationColor: Color {
        family.isEnabled ? activationTint : .secondary
    }

    private var activationHelp: String {
        if family.isPartiallyEnabled { return String(localized: "Some styles are disabled — click to enable all") }
        return family.isEnabled ? String(localized: "Deactivate") : String(localized: "Activate")
    }

    /// A face outside the added folder is installed on this Mac, even when the
    /// family also has folder faces, so it stays locked.
    private var faceLockHint: String {
        family.source == .local && family.isManaged
            ? FontSource.system.managementHint
            : family.source.managementHint
    }
}

/// Uses AppKit's native selection paint: gray in the sidebar, emphasized in
/// the font list. While a custom canvas color is set the system paint is
/// suppressed, so the row's own veil is the only selection mark.
struct TableRowEmphasisConfigurator: NSViewRepresentable {
    var isEmphasized = false
    var hidesSelectionHighlight = false

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.isEmphasized = isEmphasized
        view.hidesSelectionHighlight = hidesSelectionHighlight
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.isEmphasized = isEmphasized
        view.hidesSelectionHighlight = hidesSelectionHighlight
        view.attach()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.observations = []
    }

    final class Probe: NSView {
        var isEmphasized = false
        var hidesSelectionHighlight = false
        weak var observedRow: NSTableRowView?
        var observations: [NSKeyValueObservation] = []
        private var systemSelectionStyle: NSTableView.SelectionHighlightStyle?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        func attach() {
            var ancestor = superview
            while let current = ancestor {
                if let row = current as? NSTableRowView {
                    if observedRow !== row {
                        observations = []
                        observedRow = row
                        systemSelectionStyle = nil
                        // Observe the actual properties rather than only selection
                        // notifications: AppKit also updates them on focus changes
                        // and may restore its own highlight when the row changes.
                        observations = [\.isEmphasized, \.isSelected].map { keyPath in
                            row.observe(keyPath, options: [.new]) { [weak self] row, _ in
                                MainActor.assumeIsolated { self?.apply(to: row) }
                            }
                        }
                    }
                    apply(to: row)
                    return
                }
                ancestor = current.superview
            }
            observations = []
            observedRow = nil
        }

        private func apply(to row: NSTableRowView) {
            if hidesSelectionHighlight {
                if systemSelectionStyle == nil { systemSelectionStyle = row.selectionHighlightStyle }
                if row.selectionHighlightStyle != .none { row.selectionHighlightStyle = .none }
            } else if let style = systemSelectionStyle, row.selectionHighlightStyle != style {
                row.selectionHighlightStyle = style
                systemSelectionStyle = nil
            }
            if row.isEmphasized != isEmphasized { row.isEmphasized = isEmphasized }
        }
    }
}

/// The lock shown in place of the radio button for fonts whose activation is
/// managed outside TypeCase. The fixed width keeps names aligned in both the
/// family row and its expanded style rows.
private struct ActivationLock: View {
    let hint: String

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.callout)
            .foregroundStyle(activationTint)
            .help(hint)
            .frame(width: 16)
    }
}

/// A named instance of a variable family and its own axis coordinates.
private struct VariableInstance: Identifiable {
    let face: FontFace
    let values: [UInt32: Double]

    var id: FontFace.ID { face.id }
}

/// The axes an expanded variable family is adjusted on. The adjustments are
/// stored on the preview face, the one the collapsed row and inspector draw.
private struct VariableFamilyAxes {
    let face: FontFace
    let info: VariableFontInfo
    let instances: [VariableInstance]
}

/// The expanded row of a variable family: a live specimen, the named
/// instances to start from, and a slider per axis.
private struct VariableAxesPanel: View {
    let axes: VariableFamilyAxes
    /// The stored adjustments of the preview face; empty at its own instance.
    let stored: [UInt32: Double]
    let previewText: String
    let previewSize: Double
    let previewTextColor: Color?
    let toggleExpanded: () -> Void
    let setVariation: (Double, UInt32) -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FontPreviewText(
                text: previewText,
                postScriptName: axes.face.postScriptName,
                fileURL: axes.face.fileURL,
                size: previewSize,
                variations: stored.isEmpty ? nil : stored,
                textColor: previewTextColor
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .togglesOnDoubleClick(toggleExpanded)

            HStack(spacing: 8) {
                if axes.instances.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(axes.instances) { instance in
                                instanceButton(instance)
                            }
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                }
                Button(String(localized: "Reset")) { reset() }
                    .controlSize(.small)
                    .disabled(stored.isEmpty)
                    .help(String(localized: "Return to the style's own axis values"))
            }

            // Axes flow into as many columns as the row is wide, so wide
            // windows show them side by side instead of leaving the right
            // half empty.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 40, alignment: .leading)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(axes.info.axes) { axis in
                    axisRow(axis)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }

    /// One axis: its name, a slider, and a field to type an exact value.
    private func axisRow(_ axis: VariableFontAxis) -> some View {
        HStack(spacing: 8) {
            Text(axis.name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 88, alignment: .leading)
                .help(axis.tagString)
            Slider(value: binding(for: axis), in: axis.minimum...axis.maximum)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(axis.name)
            AxisValueField(
                axis: axis,
                value: value(for: axis),
                display: valueText,
                commit: { setVariation($0, axis.tag) }
            )
        }
    }

    /// Starts from a named instance: the preview face's own instance clears
    /// the adjustments, any other copies its coordinates onto the shared axes.
    @ViewBuilder
    private func instanceButton(_ instance: VariableInstance) -> some View {
        let button = Button(instance.face.styleName) {
            if instance.face.id == axes.face.id {
                reset()
            } else {
                for axis in axes.info.axes {
                    if let value = instance.values[axis.tag] { setVariation(value, axis.tag) }
                }
            }
        }
        .controlSize(.small)
        if matches(instance) {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func matches(_ instance: VariableInstance) -> Bool {
        axes.info.axes.allSatisfy { axis in
            let target = instance.values[axis.tag] ?? axis.defaultValue
            return abs(value(for: axis) - target) < 0.5
        }
    }

    private func value(for axis: VariableFontAxis) -> Double {
        stored[axis.tag] ?? axes.info.currentValues[axis.tag] ?? axis.defaultValue
    }

    private func binding(for axis: VariableFontAxis) -> Binding<Double> {
        Binding(
            get: { value(for: axis) },
            // Typed values can fall outside the axis.
            set: { setVariation(min(max($0, axis.minimum), axis.maximum), axis.tag) }
        )
    }

    private func valueText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The exact value of one axis. Only a number can be typed; it is applied,
/// within the axis, on Return or when the field loses focus, and anything
/// that doesn't read as a number returns to the current value.
private struct AxisValueField: View {
    let axis: VariableFontAxis
    let value: Double
    let display: (Double) -> String
    let commit: (Double) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(axis.name, text: $text)
            .textFieldStyle(.plain)
            .font(.callout)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .frame(width: 44)
            .focused($isFocused)
            .help("\(display(axis.minimum))–\(display(axis.maximum))")
            .accessibilityLabel(axis.name)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, newValue in
                if !isFocused { text = display(newValue) }
            }
            .onChange(of: text) { _, newText in
                let filtered = Self.numeric(newText)
                if filtered != newText { text = filtered }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { apply() }
            }
            .onSubmit(apply)
            .onExitCommand {
                text = display(value)
                isFocused = false
            }
    }

    private func apply() {
        if let typed = Double(text) {
            let clamped = min(max(typed, axis.minimum), axis.maximum)
            if clamped != value { commit(clamped) }
            text = display(clamped)
        } else {
            text = display(value)
        }
    }

    /// Keeps digits, one decimal point, and a minus sign at the start.
    private static func numeric(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isASCII, character.isNumber {
                result.append(character)
            } else if character == "." || character == "．", !result.contains(".") {
                result.append(".")
            } else if character == "-" || character == "−", result.isEmpty {
                result.append("-")
            }
        }
        return result
    }
}

private struct FontInspector: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings
    @Binding var comparisonVisible: Bool
    @State private var missingCharacters: [String] = []
    @State private var variableAxes: VariableAxesState?
    @State private var metadata: FontNameTable.Metadata?
    @Environment(\.openWindow) private var openWindow

    /// The size of the inspector's specimen; also the point size the variable
    /// axis values are read at, so the sliders match what the specimen shows.
    private static let previewSize: CGFloat = 40

    private struct VariableAxesState {
        let faceID: FontFace.ID
        let info: VariableFontInfo
    }

    var body: some View {
        if let pair = catalog.mixedPair(for: viewState.selection) {
            mixedPairInspector(pair)
        } else if let family = catalog.family(for: viewState.selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(family.name)
                                .font(.title3.weight(.semibold))
                                .textSelection(.enabled)
                            if family.localizedName != family.name {
                                Text(family.localizedName)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Text(family.manufacturer == "Unknown" ? String(localized: "Unknown") : family.manufacturer)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer(minLength: 8)

                        // Both header actions share one row and a 24 pt slot so
                        // they line up. A Menu ignores a dimmed foreground
                        // style, so neither label sets one.
                        HStack(spacing: 2) {
                            if let duplicates = catalog.duplicatesByFamily[family.id] {
                                DuplicateFilesSection(catalog: catalog, duplicates: duplicates)
                            }

                            Menu {
                                FontNameCopyItems(family: family)
                            } label: {
                                InspectorHeaderIcon(Image(systemName: "doc.on.doc"), title: String(localized: "Copy Name"))
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .frame(width: 24, height: 24)
                            .help(String(localized: "Copy the font names"))
                        }
                    }

                    // The inspector's specimen always follows the system
                    // appearance; the chosen specimen colors paint the list.
                    FontPreviewText(
                        text: previewText(for: family),
                        postScriptName: family.previewFace?.postScriptName,
                        fileURL: family.previewFace?.fileURL,
                        size: Self.previewSize,
                        lines: 2,
                        variations: settings.variationValues(for: family.previewFace)
                    )

                    if !missingCharacters.isEmpty {
                        missingCharactersNotice
                    }

                    inspectorDetail(String(localized: "Classification"), family.category.title)
                    inspectorDetail(String(localized: "Language"), family.languageDescription)
                    inspectorDetail(String(localized: "Styles"), "\(family.faces.count)")

                    inspectorDetail(String(localized: "Glyphs")) {
                        HStack {
                            Text(metadata?.glyphCount?.formatted() ?? "—")
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer(minLength: 12)
                            Button(String(localized: "Browse Glyphs")) {
                                openWindow(id: GlyphWindow.id, value: family.id)
                            }
                            .controlSize(.small)
                            .disabled(family.previewFace == nil)
                            .help(String(localized: "Show every character this font can display"))
                        }
                    }

                    if let face = family.previewFace,
                       let variableAxes,
                       variableAxes.faceID == face.id,
                       !variableAxes.info.axes.isEmpty {
                        variableAxesSection(face: face, info: variableAxes.info)
                    }

                    Divider()

                    inspectorDetail(String(localized: "Source"), family.source.title)
                    if !family.isManaged {
                        Label(family.source.managementHint, systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let metadata {
                        metadataSection(metadata)
                    }
                }
                .padding(20)
            }
            .task(id: missingCharactersKey(for: family)) {
                let text = previewText(for: family)
                // Clear while checking so the notice never describes the
                // previously selected font.
                missingCharacters = []
                let missing = await catalog.missingCharacters(in: text, for: family)
                guard !Task.isCancelled else { return }
                missingCharacters = missing
            }
            .task(id: family.id) {
                let face = family.previewFace
                variableAxes = nil
                let info = await catalog.variableInfo(for: family, size: Self.previewSize)
                guard !Task.isCancelled else { return }
                variableAxes = face.flatMap { face in
                    info.map { VariableAxesState(faceID: face.id, info: $0) }
                }
            }
            .task(id: family.id) {
                let face = family.previewFace
                metadata = nil
                let loaded = await catalog.fontMetadata(
                    forPostScriptName: face?.postScriptName,
                    fileURL: face?.fileURL
                )
                guard !Task.isCancelled else { return }
                metadata = loaded
            }
        } else if viewState.selection.count > 1 {
            ContentUnavailableView {
                Label(String(localized: "\(viewState.selection.count) fonts selected"), systemImage: "rectangle.split.2x1")
            } description: {
                Text(String(localized: "Compare them side by side, or select a single font to edit its details."))
            } actions: {
                if let sources = catalog.mixedPairSources(in: viewState.selectedFamilies(catalog: catalog)) {
                    Button(String(localized: "Create Mixed Pair")) {
                        viewState.createMixedPair(sources.japanese, sources.latin, catalog: catalog)
                    }
                }
                Button(String(localized: "Compare")) { comparisonVisible = true }
            }
        } else {
            ContentUnavailableView(String(localized: "Select a font"), systemImage: "textformat")
        }
    }

    // MARK: - Mixed pair

    /// The inspector for a saved pair: its fonts and a specimen that draws each
    /// part of the text with its own face.
    private func mixedPairInspector(_ pair: FontPair) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(FontPair.defaultName(
                    japanese: pairName(for: pair.japanese),
                    latin: pairName(for: pair.latin)
                ))
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

                MixedFontPreview(
                    text: settings.effectiveMixedText(entered: viewState.previewText),
                    size: Self.previewSize,
                    lines: 2,
                    fonts: fonts(for: pair),
                    typesetting: pair.options
                )

                Group {
                    ForEach(pair.references, id: \.script) { entry in
                        inspectorDetail(entry.script.title, pairName(for: entry.reference))
                    }
                }

                if pair.references.contains(where: { !catalog.canResolve($0.reference) }) {
                    Label(String(localized: "One of the fonts is no longer in the library."), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button(String(localized: "Delete Pair"), role: .destructive) {
                    catalog.removeMixedPair(pair)
                    viewState.selection = []
                    viewState.reconcile(with: catalog, settings: settings)
                }
            }
            .padding(20)
        }
    }

    /// The pair's faces as drawable specs, keyed by the part they draw.
    private func fonts(for pair: FontPair) -> [MixedScript: PreviewFaceSpec] {
        pair.references.reduce(into: [:]) { result, entry in
            result[entry.script] = PreviewFaceSpec(
                postScriptName: entry.reference.postScriptName,
                fileURL: catalog.face(for: entry.reference)?.fileURL,
                variations: settings.variationValues(for: entry.reference.postScriptName),
                features: pair.options.features(for: entry.script)
            )
        }
    }

    private func pairName(for reference: FontFaceReference) -> String {
        guard let family = catalog.familyByID[reference.familyID] else { return reference.postScriptName }
        guard let face = family.faces.first(where: { $0.postScriptName == reference.postScriptName }) else {
            return family.name
        }
        return "\(family.name) \(face.styleName)"
    }

    // MARK: - File metadata

    /// The details read from the font file: version, glyph count, embedding
    /// permission, designer, and the legal notices. Fields the file does not
    /// carry are omitted.
    @ViewBuilder
    private func metadataSection(_ metadata: FontNameTable.Metadata) -> some View {
        let hasSummary = metadata.versionNumber != nil
            || metadata.embedding != nil
            || metadata.designer != nil
        if hasSummary {
            Group {
                if let version = metadata.versionNumber {
                    inspectorDetail(String(localized: "Version"), version)
                }
                if let embedding = metadata.embedding {
                    inspectorDetail(String(localized: "Embedding"), embedding.title)
                }
                if let designer = metadata.designer {
                    inspectorDetail(String(localized: "Designer"), designer)
                }
            }
        }
        if let copyright = metadata.copyright {
            inspectorDetail(String(localized: "Copyright"), copyright, lineLimit: 4)
        }
        if let license = metadata.license, license != metadata.copyright {
            inspectorDetail(String(localized: "License"), license, lineLimit: 4)
        }
    }

    private func inspectorDetail<Content: View>(
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

    private func inspectorDetail(
        _ title: String,
        _ text: String,
        lineLimit: Int? = nil
    ) -> some View {
        inspectorDetail(title) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .help(text)
        }
    }

    // MARK: - Variable axes

    private func variableAxesSection(face: FontFace, info: VariableFontInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "Variable Axes"))
                    .font(.headline)
                Spacer(minLength: 8)
                Button(String(localized: "Reset")) {
                    settings.resetVariations(for: face.postScriptName)
                }
                .controlSize(.small)
                .disabled(settings.variationValues(for: face.postScriptName).isEmpty)
                .help(String(localized: "Return to the style's own axis values"))
            }
            ForEach(info.axes) { axis in
                let binding = axisBinding(axis, face: face, info: info)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(axis.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(axisValueText(binding.wrappedValue))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Slider(value: binding, in: axis.minimum...axis.maximum)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(axis.name)
                }
            }
        }
    }

    /// The slider value: the stored adjustment, the instance's own coordinate,
    /// or the axis default.
    private func axisBinding(_ axis: VariableFontAxis, face: FontFace, info: VariableFontInfo) -> Binding<Double> {
        Binding(
            get: {
                settings.variationValues(for: face.postScriptName)[axis.tag]
                    ?? info.currentValues[axis.tag]
                    ?? axis.defaultValue
            },
            set: { settings.setVariation($0, tag: axis.tag, for: face.postScriptName) }
        )
    }

    private func axisValueText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func missingCharactersKey(for family: FontFamily) -> MissingCharactersKey {
        MissingCharactersKey(familyID: family.id, text: previewText(for: family))
    }

    private func previewText(for family: FontFamily) -> String {
        settings.effectivePreviewText(for: family, entered: viewState.previewText)
    }

    /// Characters of the preview text the selected font cannot display. The
    /// inspector is the only place missing coverage is surfaced; list rows stay
    /// unmarked.
    private var missingCharactersNotice: some View {
        let visible = missingCharacters.prefix(16)
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
        .help(String(localized: "The selected font cannot display these characters of the preview text"))
    }
}

/// Re-checks the inspector's missing characters only when the font or the
/// preview text changes.
private struct MissingCharactersKey: Equatable {
    let familyID: String
    let text: String
}

/// The icon-only label of the inspector header's actions, one size for both.
private struct InspectorHeaderIcon: View {
    let image: Image
    let title: String

    init(_ image: Image, title: String) {
        self.image = image
        self.title = title
    }

    var body: some View {
        Label { Text(title) } icon: { image }
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .regular))
            .imageScale(.medium)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

/// A compact entry point to review duplicate files in the cleanup sheet.
private struct DuplicateFilesSection: View {
    @ObservedObject var catalog: FontCatalog
    let duplicates: [FontDuplicate]
    @State private var showsCleanup = false

    var body: some View {
        Button { showsCleanup = true } label: {
            // The 14 pt cut keeps its strokes on whole pixels beside doc.on.doc.
            InspectorHeaderIcon(Image("font.duplicate.small"), title: String(localized: "Duplicates"))
                // A borderless button draws its icon in the secondary color;
                // the Copy Name menu beside it draws in the primary one.
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .frame(width: 24, height: 24)
        .disabled(catalog.isLoading || catalog.isUpdatingActivation)
        .help(String(localized: "Clean Up Duplicates…"))
        .sheet(isPresented: $showsCleanup) {
            DuplicateCleanupView(catalog: catalog, duplicates: duplicates)
        }
    }
}

private struct ComparisonView: View {
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings
    @State private var families: [FontFamily]
    @Environment(\.dismiss) private var dismiss

    init(viewState: LibraryViewState, families: [FontFamily]) {
        self.viewState = viewState
        _families = State(initialValue: families)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text(String(localized: "Compare"))
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button(String(localized: "Done")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                HStack(spacing: 10) {
                    TextField(String(localized: "Sample text"), text: $viewState.previewText)
                        .textFieldStyle(.roundedBorder)
                    Slider(value: $settings.previewSize, in: AppSettings.previewSizeRange, step: 1)
                        .frame(width: 120)
                    Text("\(Int(settings.previewSize)) pt")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .padding(16)
            Divider()
            if families.isEmpty {
                ContentUnavailableView(String(localized: "Nothing to compare"), systemImage: "rectangle.split.2x1")
            } else {
                List {
                    ForEach(families) { family in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(family.name)
                                    .font(.headline)
                                Text(family.previewFace?.styleName ?? "")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    families.removeAll { $0.id == family.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(String(localized: "Remove from comparison"))
                            }
                            FontPreviewText(
                                text: settings.effectivePreviewText(for: family, entered: viewState.previewText),
                                postScriptName: family.previewFace?.postScriptName,
                                fileURL: family.previewFace?.fileURL,
                                size: settings.previewSize,
                                lines: 2,
                                variations: settings.variationValues(for: family.previewFace),
                                backgroundColor: settings.previewBackgroundColor,
                                textColor: settings.previewTextColor
                            )
                        }
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

#Preview {
    ContentView()
        .environmentObject(FontCatalog())
        .environmentObject(AppSettings())
        .environmentObject(MixedPairDraft())
}

/// The open library windows, so app-wide commands and alerts reach exactly one
/// of them even while another window (Settings, a mixed pair) is key.
@MainActor
enum LibraryWindows {
    static let id = "library"
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) {
        windows.add(window)
    }

    /// The library window nearest the front, or nil when none is open.
    static var frontmost: NSWindow? {
        NSApp.orderedWindows.first { windows.contains($0) && $0.isVisible }
    }
}

/// Reports the hosting `NSWindow` so menu commands can be routed to the key window.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.hideTitle()
        DispatchQueue.main.async { onWindow(nsView.window) }
    }

    final class Probe: NSView {
        private var titleObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titleObservation = nil
            hideTitle()
            titleObservation = window?.observe(\.titleVisibility, options: [.new]) { window, _ in
                MainActor.assumeIsolated {
                    if window.titleVisibility != .hidden {
                        window.titleVisibility = .hidden
                    }
                }
            }
        }

        // Apply synchronously before drawing; only the SwiftUI state callback
        // above is deferred to avoid publishing changes during a view update.
        func hideTitle() {
            if let window, window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
        }
    }
}

/// Sidebar rows keep their icons neutral; the accent color stays reserved for
/// selection and activation states.
private struct SidebarLabel: View {
    let title: String
    let icon: SourceIcon

    init(title: String, systemImage: String) {
        self.title = title
        self.icon = .symbol(systemImage)
    }

    init(title: String, icon: SourceIcon) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(Color(nsColor: .labelColor))
        } icon: {
            SidebarIcon(icon: icon)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        // Sidebar and OutlineGroup can otherwise reduce nested rows to the
        // smaller hierarchical style. Pin every navigation label to the same
        // AppKit system size while preserving indentation.
        .font(.system(size: NSFont.systemFontSize))
    }
}

/// A user-defined preset: the chip's name and the preview text it inserts.
private struct PreviewPreset: Identifiable, Equatable {
    let name: String
    var text: String

    /// Names are unique within the custom presets, so the name identifies the
    /// chip; saving a name again updates that preset instead of adding a
    /// duplicate.
    var id: String { name }
}

/// Persistent preview-text editor with quick presets, pinned below the font
/// list: a text field with a compact preset menu and add button.
private struct PreviewTextEditor: View {
    @ObservedObject var viewState: LibraryViewState
    @State private var customPresets = PreviewTextEditor.loadCustomPresets()
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var newPresetText = ""
    @State private var selectedPreset: (name: String, text: String, isCustom: Bool)?
    @FocusState private var newPresetNameFocused: Bool

    private static let presetsKey = "previewTextPresets"

    private static let builtInPresets: [(title: String, text: String)] = [
        ("123", "0123456789"),
        ("ABC", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        ("abc", "abcdefghijklmnopqrstuvwxyz"),
        ("lorem", "Lorem ipsum dolor sit amet, consectetur adipiscing elit."),
        ("fox", "The quick brown fox jumps over the lazy dog."),
        ("deutsch", "Zwölf Boxkämpfer jagen Eva quer über den großen Sylter Deich."),
        ("français", "Portez ce vieux whisky au juge blond qui fume."),
        ("日本語", FontLanguage.japanese.sampleDefault),
        ("简体中文", FontLanguage.simplifiedChinese.sampleDefault),
        ("繁體中文", FontLanguage.traditionalChinese.sampleDefault),
        ("한국어", FontLanguage.korean.sampleDefault),
        ("symbols", "→ ← ↑ ↓ ★ ☆ ♠ ♥ ♦ ♣ € £ ¥ © ® ™"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            TextField(String(localized: "Enter preview text…"), text: $viewState.previewText)
                .textFieldStyle(.plain)
                .accessibilityLabel(String(localized: "Preview text"))

            HStack(spacing: 10) {
                Menu {
                    ForEach(Self.builtInPresets, id: \.title) { preset in
                        Button(preset.title) {
                            selectedPreset = (preset.title, preset.text, false)
                            viewState.previewText = preset.text
                        }
                    }

                    if !customPresets.isEmpty {
                        Divider()
                        ForEach(customPresets) { preset in
                            Button(preset.name) {
                                selectedPreset = (preset.name, preset.text, true)
                                viewState.previewText = preset.text
                            }
                        }
                        Divider()
                        Menu(String(localized: "Remove Preset")) {
                            ForEach(customPresets) { preset in
                                Button(preset.name, role: .destructive) {
                                    removePreset(preset)
                                }
                            }
                        }
                    }
                } label: {
                    Text(presetMenuTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(String(localized: "Choose preview text"))

                Button {
                    presentAddPreset()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Add a preset with a name and preview text"))
                .accessibilityLabel(String(localized: "Add a preset with a name and preview text"))
                .popover(isPresented: $isAddingPreset, arrowEdge: .top) {
                    addPresetForm
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        // Each library window has its own editor; follow presets saved by the
        // others.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let stored = Self.loadCustomPresets()
            if stored != customPresets { customPresets = stored }
        }
    }

    private var trimmedPreviewText: String {
        viewState.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var presetMenuTitle: String {
        let text = viewState.previewText
        // Preserve the actual choice when multiple presets contain the same text.
        if let selectedPreset, selectedPreset.text == text {
            let exists = selectedPreset.isCustom
                ? customPresets.contains { $0.name == selectedPreset.name && $0.text == text }
                : Self.builtInPresets.contains { $0.title == selectedPreset.name && $0.text == text }
            if exists { return selectedPreset.name }
        }
        if let preset = customPresets.first(where: { $0.text == text }) {
            return preset.name
        }
        if let preset = Self.builtInPresets.first(where: { $0.text == text }) {
            return preset.title
        }
        return trimmedPreviewText.isEmpty ? String(localized: "Presets") : String(localized: "Custom")
    }

    /// The form behind the “+” button: a preset name and the preview text it
    /// inserts, starting from the text that is already in the field.
    private var addPresetForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetField(String(localized: "Name"), prompt: String(localized: "e.g. abc, lorem, symbols"), text: $newPresetName)
                .focused($newPresetNameFocused)
            presetField(String(localized: "Preview Text"), prompt: String(localized: "Sample preview text"), text: $newPresetText)

            HStack {
                Button(String(localized: "Cancel")) { isAddingPreset = false }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button(String(localized: "Save")) { savePreset() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedNewPresetName.isEmpty || trimmedNewPresetText.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .defaultFocus($newPresetNameFocused, true)
    }

    private func presetField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var trimmedNewPresetName: String {
        newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewPresetText: String {
        newPresetText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opens the form with the current text as its starting point, so the
    /// common case is only a name away.
    private func presentAddPreset() {
        newPresetName = ""
        newPresetText = trimmedPreviewText
        isAddingPreset = true
    }

    private func savePreset() {
        let name = trimmedNewPresetName
        let text = trimmedNewPresetText
        guard !name.isEmpty, !text.isEmpty else { return }
        if let index = customPresets.firstIndex(where: { $0.name == name }) {
            customPresets[index].text = text
        } else {
            customPresets.append(PreviewPreset(name: name, text: text))
        }
        storeCustomPresets()
        isAddingPreset = false
    }

    private func removePreset(_ preset: PreviewPreset) {
        customPresets.removeAll { $0.id == preset.id }
        storeCustomPresets()
    }

    /// Loads the stored presets, migrating the text-only ones that predated
    /// names: they keep showing their text as the chip name.
    private static func loadCustomPresets() -> [PreviewPreset] {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: presetsKey) as? [[String: String]] {
            return stored.compactMap { entry in
                guard let name = entry["name"], let text = entry["text"],
                      !name.isEmpty, !text.isEmpty else { return nil }
                return PreviewPreset(name: name, text: text)
            }
        }
        return (defaults.stringArray(forKey: presetsKey) ?? []).map {
            PreviewPreset(name: $0, text: $0)
        }
    }

    private func storeCustomPresets() {
        UserDefaults.standard.set(
            customPresets.map { ["name": $0.name, "text": $0.text] },
            forKey: Self.presetsKey
        )
    }
}

/// A three-state control toggles every file in the folder with one click.
private struct FolderActivationControl: View {
    @ObservedObject var catalog: FontCatalog
    let folder: URL
    @Environment(\.undoManager) private var undoManager

    private var files: [FontActivationState] { catalog.activationStates(in: folder) }
    private var activeCount: Int { files.filter(\.enabled).count }
    private var status: String {
        if files.isEmpty { return String(localized: "No Fonts") }
        if activeCount == files.count { return String(localized: "All Active") }
        if activeCount == 0 { return String(localized: "All Inactive") }
        return String(localized: "Partially Active")
    }
    private var symbol: String {
        if files.isEmpty || activeCount == 0 { return "circle" }
        return activeCount == files.count ? "circle.fill" : "circle.lefthalf.filled"
    }

    var body: some View {
        Button {
            catalog.setEnabled(activeCount != files.count, in: folder, undoManager: undoManager)
        } label: {
            SidebarIcon(icon: .symbol(symbol))
                .foregroundStyle(activeCount > 0 ? activationTint : Color.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(files.isEmpty || catalog.isLoading || catalog.isUpdatingActivation)
        .help(String(localized: "Active font files: \(activeCount) / \(files.count)"))
        .accessibilityLabel(Text(verbatim: folder.lastPathComponent + ": " + status))
        .accessibilityValue(Text(String(localized: "Active font files: \(activeCount) / \(files.count)")))
    }
}

private struct FolderActivationActions: View {
    @ObservedObject var catalog: FontCatalog
    let folder: URL
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let files = catalog.activationStates(in: folder)
        Button(String(localized: "Activate All Fonts")) {
            catalog.setEnabled(true, in: folder, undoManager: undoManager)
        }
        .disabled(catalog.isLoading || catalog.isUpdatingActivation || !files.contains { !$0.enabled })
        Button(String(localized: "Deactivate All Fonts")) {
            catalog.setEnabled(false, in: folder, undoManager: undoManager)
        }
        .disabled(catalog.isLoading || catalog.isUpdatingActivation || !files.contains(where: \.enabled))
    }
}
