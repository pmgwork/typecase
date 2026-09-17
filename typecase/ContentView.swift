import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var catalog: FontCatalog
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewState = LibraryViewState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorVisible = true
    @State private var comparisonVisible = false
    @State private var window: NSWindow?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(catalog: catalog, viewState: viewState)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            FontLibraryView(catalog: catalog, viewState: viewState)
        }
        .navigationTitle("TypeCase")
        // Preserve the principal region so trailing controls stay right-aligned.
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .inspector(isPresented: $inspectorVisible) {
            FontInspector(catalog: catalog, viewState: viewState, comparisonVisible: $comparisonVisible)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 400)
        }
        // Keep the window's minimum size independent of sidebar and inspector visibility.
        // Otherwise AppKit changes the window frame when a split-view column is restored.
        .frame(minWidth: 860, minHeight: 520)
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
            }
            .sharedBackgroundVisibility(.hidden)

            // The specimen colors keep their own item so the swatch is not
            // drawn inside the button group's shared background.
            ToolbarItem(placement: .navigation) {
                PreviewColorsControl()
            }
            .sharedBackgroundVisibility(.hidden)

            // On macOS, confirmationAction is the trailing toolbar region;
            // automatic and primaryAction items can remain on the leading side.
            ToolbarItem(placement: .confirmationAction) {
                Menu {
                    Picker("Category", selection: $viewState.category) {
                        Text("All Categories").tag(FontCategory?.none)
                        ForEach(FontCategory.allCases) { category in
                            Text(category.title).tag(Optional(category))
                        }
                    }
                    Divider()
                    Picker("Status", selection: $viewState.activationFilter) {
                        ForEach(ActivationFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    Divider()
                    Picker("Sort By", selection: $viewState.sortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter by category and status, and choose the list order")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "info.circle")
                }
                .help("Show or hide the inspector")
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
            ComparisonView(viewState: viewState, families: viewState.selectedFamilies(catalog: catalog))
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFontFolder)) { _ in
            // The File menu command is not tied to a window; only the key window navigates
            // to the newly added folder.
            guard window?.isKeyWindow == true else { return }
            catalog.addFolder { url in viewState.librarySelection = .folder(url) }
        }
        .task {
            viewState.restoreStartupState(from: settings)
            viewState.reconcile(with: catalog)
        }
        .background(WindowAccessor {
            window = $0
        })
        .onChange(of: catalog.familiesRevision) { _, _ in
            viewState.reconcile(with: catalog)
        }
        .onChange(of: viewState.librarySelection) { _, selection in
            settings.remember(location: selection)
        }
        .onChange(of: viewState.selection) { _, selection in
            settings.remember(selection: selection)
        }
        .alert("TypeCase", isPresented: Binding(
            get: { catalog.errorMessage != nil },
            set: { if !$0 { catalog.errorMessage = nil } }
        )) {
            Button("OK") { catalog.errorMessage = nil }
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
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
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
    }
}

/// Compact preview-size control for the toolbar: small “A”, slider, large “A”.
private struct PreviewSizeControl: View {
    @Binding var size: Double

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

            Slider(value: roundedSize, in: 18...72)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 96)
                .accessibilityLabel("Preview size")

            Text("A")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 20)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .help("Preview size: \(Int(size)) pt")
    }
}

/// The copy actions shared by the font row's context menu and the inspector:
/// the names a designer needs when using the font somewhere else.
private struct FontNameCopyItems: View {
    @EnvironmentObject private var catalog: FontCatalog
    let family: FontFamily

    var body: some View {
        Button("Family Name") {
            catalog.copyStrings([family.name])
        }
        Button("English Name") {
            catalog.copyStrings([family.localizedName])
        }
        Button("PostScript Names") {
            catalog.copyStrings(family.faces.map(\.postScriptName))
        }
        Button("CSS font-family") {
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
                                        fallback: Color(nsColor: .windowBackgroundColor), title: "Background Color") {
                        Color.clear.frame(width: 27, height: 36).contentShape(.rect)
                    }
                    SpecimenColorPicker(color: $settings.previewTextColor,
                                        fallback: Color(nsColor: .labelColor), title: "Text Color") {
                        Color.clear.frame(width: 27, height: 36).contentShape(.rect)
                    }
                }
            }
            .contextMenu {
                Button("System") { settings.setPreviewColors(background: nil, text: nil) }
                Button("Light") { settings.setPreviewColors(background: .white, text: .black) }
                Button("Dark") {
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

private struct Sidebar: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("systemScopesExpanded") private var systemScopesExpanded = true
    @State private var isDropTargeted = false

    /// The font service sections the settings leave visible.
    private var providerSections: [LibrarySection] {
        FontProviderRegistry.all
            .filter { settings.isProviderSectionVisible($0.id) }
            .map { .provider($0) }
    }

    var body: some View {
        List(selection: $viewState.librarySelection) {
            Section {
                if settings.showAllSection { sectionRow(.all) }
                if settings.showFavoritesSection { sectionRow(.favorites) }
                if settings.showSystemSection { systemGroup }
                if settings.showLocalSection { sectionRow(.local) }
            }

            if !providerSections.isEmpty {
                Section {
                    ForEach(providerSections) { section in
                        sectionRow(section)
                    }
                } header: {
                    Text("Providers")
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }

            Section {
                if catalog.folders.isEmpty {
                    SidebarLabel(title: "Drop folders here", systemImage: "plus")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    OutlineGroup(catalog.folderTrees, children: \.children) { node in
                        SidebarLabel(title: node.url.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .background(TableRowEmphasisConfigurator())
                            .badge(selectedCount(for: .folder(node.url)))
                            .tag(LibrarySelection.folder(node.url))
                            .help(node.url.path)
                            .contextMenu {
                                Button("Show in Finder") { catalog.revealFolder(node.url) }
                                if catalog.folders.contains(where: { $0.standardizedFileURL == node.url.standardizedFileURL }) {
                                    Divider()
                                    Button("Remove", role: .destructive) {
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
            } header: {
                HStack(spacing: 8) {
                    Text("Folders")
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    Spacer(minLength: 0)
                    Button {
                        catalog.addFolder { url in viewState.librarySelection = .folder(url) }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Add a font folder")
                    .accessibilityLabel("Add a font folder")
                }
                .padding(.trailing, 12)
            }

            if settings.showTagsSection, !catalog.allTags.isEmpty {
                Section {
                    ForEach(catalog.allTags, id: \.self) { tag in
                        Button {
                            viewState.librarySelection = .section(.all)
                            viewState.searchText = tag
                        } label: {
                            SidebarLabel(title: tag, systemImage: "tag")
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("Tags")
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
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
                  let fallback = sections.first else { return }
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
}

private struct FontLibraryView: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.undoManager) private var environmentUndoManager
    @FocusState private var listFocused: Bool
    @State private var expandedFamilyID: FontFamily.ID?

    var body: some View {
        VStack(spacing: 0) {
            let output = viewState.filter(catalog: catalog, favoritesFirst: settings.favoritesFirst)
            if output.families.isEmpty {
                emptyState(output: output)
            } else {
                List(selection: $viewState.selection) {
                    ForEach(output.families) { family in
                        FontFamilyRow(
                            family: family,
                            isExpanded: expandedFamilyID == family.id,
                            previewText: settings.effectivePreviewText(for: family, entered: viewState.previewText),
                            previewSize: settings.previewSize,
                            previewTextColor: settings.previewTextColor,
                            isSelected: viewState.selection.contains(family.id),
                            selectionTint: selectionTint,
                            isFavorite: catalog.isFavorite(family),
                            variations: settings.variationValues(for: family.faces),
                            toggleExpanded: { toggleExpanded(family) },
                            toggleFavorite: { catalog.toggleFavorite(family) },
                            toggleEnabled: {
                                setEnabled(!family.isEnabled || family.isPartiallyEnabled, families: [family])
                            },
                            toggleFaceEnabled: { face in
                                setEnabled(!face.isInstalled, faces: [face], in: family)
                            }
                        )
                            .equatable()
                            .tag(family.id)
                            .contextMenu {
                                let targets = activationTargets(for: family)
                                Button(activationTitle("Activate", count: targets.count)) {
                                    setEnabled(true, families: targets)
                                }
                                .disabled(!targets.contains(where: \.canActivate))

                                Button(activationTitle("Deactivate", count: targets.count)) {
                                    setEnabled(false, families: targets)
                                }
                                .disabled(!targets.contains(where: \.canDeactivate))

                                Divider()

                                Button("Show in Finder") {
                                    catalog.revealFiles(family.fileURLs)
                                }
                                .disabled(family.fileURLs.isEmpty)

                                Button("Copy Path") {
                                    catalog.copyPaths(family.fileURLs)
                                }
                                .disabled(family.fileURLs.isEmpty)

                                Divider()

                                Menu("Copy Name") {
                                    FontNameCopyItems(family: family)
                                }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
                .environment(\.controlActiveState, .key)
                .focused($listFocused)
                .simultaneousGesture(TapGesture().onEnded { listFocused = true })
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
        // The chosen background paints the whole font list area, so specimens
        // sit directly on it. The inspector keeps the system surface.
        .background(canvasColor)
        // Coverage depends on the preview text and the family list, so the check
        // is requested here rather than from inside the cached filter.
        .task(id: viewState.coverageRequest(catalog: catalog)) {
            viewState.updateCoverage(catalog: catalog)
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 640)
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

    /// The veil drawn over a selected row while the canvas has a custom color.
    /// It takes the specimen text color so the selection stays readable and
    /// belongs to the chosen palette; `nil` keeps the system accent selection.
    private var selectionTint: Color? {
        guard settings.previewBackgroundColor != nil else { return nil }
        return settings.previewTextColor ?? Color(nsColor: .labelColor)
    }


    @ViewBuilder
    private func emptyState(output: LibraryViewState.FilterOutput) -> some View {
        Group {
            if catalog.families.isEmpty && catalog.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading fonts…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.families.isEmpty {
                ContentUnavailableView {
                    Label("No fonts in the library", systemImage: "textformat")
                } description: {
                    Text("Installed fonts are read automatically. Add a folder to include the font files stored on disk.")
                } actions: {
                    Button("Add Font Folder…") {
                        catalog.addFolder { url in viewState.librarySelection = .folder(url) }
                    }
                    Button("Refresh") { catalog.refresh() }
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
                        Button("Add Font Folder…") {
                            catalog.addFolder { url in viewState.librarySelection = .folder(url) }
                        }
                    }
                    Button("Show All Fonts") { viewState.librarySelection = .section(.all) }
                }
            } else {
                ContentUnavailableView {
                    Label("No fonts match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(filterSummary.isEmpty ? "Change the search text or filters." : filterSummary)
                } actions: {
                    if hasActiveToolbarFilters {
                        Button("Clear Filters") { viewState.clearFilters() }
                    }
                    if !activeCoverageText.isEmpty {
                        Button("Clear Preview Text") { viewState.previewText = "" }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterSummary: String {
        var parts: [String] = []
        let query = viewState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append("Search: “\(query)”") }
        if let category = viewState.category { parts.append("Category: \(category.title)") }
        if viewState.activationFilter != .all { parts.append("Status: \(viewState.activationFilter.title)") }
        if !activeCoverageText.isEmpty { parts.append("Contains: “\(activeCoverageText)”") }
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
            if let provider = section.provider { return "No \(provider.title)" }
            switch section {
            case .favorites: return "No favorites yet"
            case .local: return "No local fonts"
            default: return "No fonts"
            }
        case .folder(let folder): return "No fonts in \(folder.lastPathComponent)"
        case .systemScope(let scope): return "No fonts for \(scope.title)"
        }
    }

    private var emptySectionMessage: String {
        switch viewState.librarySelection {
        case .section(let section):
            if let provider = section.provider { return provider.emptyMessage }
            switch section {
            case .favorites: return "Select a font and click the star to keep it here."
            case .local: return "Add a folder that contains font files to browse them without installing."
            default: return "Change the search text or filters."
            }
        case .folder: return "This folder does not contain any supported font files."
        case .systemScope: return "No fonts were found in this installation scope."
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

    /// Activation acts on the whole multi-selection when the clicked row is part
    /// of it, and on the clicked family otherwise.
    private func activationTargets(for family: FontFamily) -> [FontFamily] {
        guard viewState.selection.contains(family.id), viewState.selection.count > 1 else { return [family] }
        return viewState.selectedFamilies(catalog: catalog)
    }

    private func activationTitle(_ action: String, count: Int) -> String {
        count > 1 ? "\(action) \(count) Fonts" : action
    }

    private func toggleExpanded(_ family: FontFamily) {
        expandedFamilyID = expandedFamilyID == family.id ? nil : family.id
    }
}

/// The tint of the list-row activation indicators. System green marks fonts
/// that TypeCase manages, including the lock for sources it cannot change;
/// an inactive style keeps a secondary-gray outline.
private let activationTint = Color.green

private struct FontFamilyRow: View, Equatable {
    let family: FontFamily
    let isExpanded: Bool
    let previewText: String
    let previewSize: Double
    let previewTextColor: Color?
    let isSelected: Bool
    /// The selection veil while a custom canvas color paints the list; `nil`
    /// keeps the system accent selection.
    let selectionTint: Color?
    let isFavorite: Bool
    let variations: [FontFace.ID: [UInt32: Double]]
    let toggleExpanded: () -> Void
    let toggleFavorite: () -> Void
    let toggleEnabled: () -> Void
    let toggleFaceEnabled: (FontFace) -> Void

    static func == (lhs: FontFamilyRow, rhs: FontFamilyRow) -> Bool {
        lhs.family == rhs.family
            && lhs.isExpanded == rhs.isExpanded
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
                Text(family.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(family.faces.count) styles")
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
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .help("Favorite")
            }
            if isExpanded {
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
                                    .help(face.isInstalled ? "Deactivate" : "Activate")
                                    .frame(width: 16)
                                } else {
                                    ActivationLock(hint: faceLockHint)
                                }
                                Text(face.styleName)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            FontPreviewText(
                                text: previewText,
                                postScriptName: face.postScriptName,
                                fileURL: face.fileURL,
                                size: previewSize,
                                variations: variations[face.id],
                                textColor: previewTextColor
                            )
                        }
                    }
                }
            } else {
                FontPreviewText(
                    text: previewText,
                    postScriptName: family.previewFace?.postScriptName,
                    fileURL: family.previewFace?.fileURL,
                    size: previewSize,
                    variations: family.previewFace.flatMap { variations[$0.id] },
                    textColor: previewTextColor
                )
            }
        }
        .padding(.vertical, 6)
        .background {
            if isSelected, let selectionTint {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectionTint.opacity(0.22))
            }
        }
        // The system's accent selection is suppressed while the row draws its
        // own veil, otherwise the blue fights the custom canvas color.
        .background(TableRowEmphasisConfigurator(
            isEmphasized: selectionTint == nil,
            hidesSelectionHighlight: selectionTint != nil
        ))
        .contentShape(.rect)
        // Let the List select on the first click without waiting for the
        // double-click recognizer to fail.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { toggleExpanded() }
        )
        .help(isExpanded ? "Double-click to hide styles" : "Double-click to show all styles")
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
        if family.isPartiallyEnabled { return "Some styles are disabled — click to enable all" }
        return family.isEnabled ? "Deactivate" : "Activate"
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
private struct TableRowEmphasisConfigurator: NSViewRepresentable {
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

private struct FontInspector: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @EnvironmentObject private var settings: AppSettings
    @Binding var comparisonVisible: Bool
    @State private var newTag = ""
    @State private var missingCharacters: [String] = []
    @State private var variableAxes: VariableAxesState?
    @State private var metadata: FontNameTable.Metadata?

    /// The size of the inspector's specimen; also the point size the variable
    /// axis values are read at, so the sliders match what the specimen shows.
    private static let previewSize: CGFloat = 40

    private struct VariableAxesState {
        let faceID: FontFace.ID
        let info: VariableFontInfo
    }

    var body: some View {
        if let family = catalog.family(for: viewState.selection) {
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
                            Text(family.manufacturer)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer(minLength: 8)

                        Menu {
                            FontNameCopyItems(family: family)
                        } label: {
                            Label("Copy Name", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Copy the font names")
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

                    Group {
                        inspectorDetail("Source", family.source.title)
                        inspectorDetail("Language", family.languageDescription)
                        inspectorDetail("Styles", "\(family.faces.count)")
                    }

                    if let metadata {
                        metadataSection(metadata)
                    }

                    if let face = family.previewFace,
                       let variableAxes,
                       variableAxes.faceID == face.id,
                       !variableAxes.info.axes.isEmpty {
                        variableAxesSection(face: face, info: variableAxes.info)
                    }

                    if !family.isManaged {
                        Label(family.source.managementHint, systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    classificationSection(for: family)

                    tagsSection(for: family)
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
                let info = catalog.variableInfo(for: family, size: Self.previewSize)
                variableAxes = face.flatMap { face in
                    info.map { VariableAxesState(faceID: face.id, info: $0) }
                }
                // Clear while reading so the metadata never describes the
                // previously selected font.
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
                Label("\(viewState.selection.count) fonts selected", systemImage: "rectangle.split.2x1")
            } description: {
                Text("Compare them side by side, or select a single font to edit its details.")
            } actions: {
                Button("Compare") { comparisonVisible = true }
            }
        } else {
            ContentUnavailableView("Select a font", systemImage: "textformat")
        }
    }

    private func classificationBinding(for family: FontFamily) -> Binding<FontCategory> {
        Binding(
            get: { family.category },
            set: { catalog.setCategory($0, for: family) }
        )
    }

    /// The user-editable classification. While it differs from the value the
    /// font file implies, the detected value stays visible as a caption.
    private func classificationSection(for family: FontFamily) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            inspectorDetail("Classification") {
                Picker("Classification", selection: classificationBinding(for: family)) {
                    ForEach(FontCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
            }
            if family.category != family.detectedCategory {
                Text("Detected: \(family.detectedCategory.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - File metadata

    /// The details read from the font file: version, glyph count, embedding
    /// permission, designer, and the legal notices. Fields the file does not
    /// carry are omitted.
    @ViewBuilder
    private func metadataSection(_ metadata: FontNameTable.Metadata) -> some View {
        let hasSummary = metadata.versionNumber != nil
            || metadata.glyphCount != nil
            || metadata.embedding != nil
            || metadata.designer != nil
        if hasSummary {
            Group {
                if let version = metadata.versionNumber {
                    inspectorDetail("Version", version)
                }
                if let glyphCount = metadata.glyphCount {
                    inspectorDetail("Glyphs", glyphCount.formatted())
                }
                if let embedding = metadata.embedding {
                    inspectorDetail("Embedding", embedding.title)
                }
                if let designer = metadata.designer {
                    inspectorDetail("Designer", designer)
                }
            }
        }
        if let copyright = metadata.copyright {
            inspectorDetail("Copyright", copyright, lineLimit: 4)
        }
        if let license = metadata.license, license != metadata.copyright {
            inspectorDetail("License", license, lineLimit: 4)
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
                Text("Variable Axes")
                    .font(.headline)
                Spacer(minLength: 8)
                Button("Reset") {
                    settings.resetVariations(for: face.postScriptName)
                }
                .controlSize(.small)
                .disabled(settings.variationValues(for: face.postScriptName).isEmpty)
                .help("Return to the style's own axis values")
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

    private func tagsSection(for family: FontFamily) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(.headline)
            ForEach(catalog.tags(for: family), id: \.self) { tag in
                HStack {
                    Label(tag, systemImage: "tag")
                    Spacer()
                    Button {
                        catalog.removeTag(tag, from: family)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove tag")
                }
                .font(.callout)
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    catalog.addTag(newTag, to: family)
                    newTag = ""
                }
        }
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
                ? "Missing characters: \(list) … (+\(remaining))"
                : "Missing characters: \(list)")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .help("The selected font cannot display these characters of the preview text")
    }
}

/// Re-checks the inspector's missing characters only when the font or the
/// preview text changes.
private struct MissingCharactersKey: Equatable {
    let familyID: String
    let text: String
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
                    Text("Compare")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                HStack(spacing: 10) {
                    TextField("Sample text", text: $viewState.previewText)
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
                ContentUnavailableView("Nothing to compare", systemImage: "rectangle.split.2x1")
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
                                .help("Remove from comparison")
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
            SourceIconView(icon: icon)
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
            TextField("Enter preview text…", text: $viewState.previewText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Preview text")

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
                        Menu("Remove Preset") {
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
                .help("Choose preview text")

                Button {
                    presentAddPreset()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Add a preset with a name and preview text")
                .accessibilityLabel("Add a preset with a name and preview text")
                .popover(isPresented: $isAddingPreset, arrowEdge: .top) {
                    addPresetForm
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
        return trimmedPreviewText.isEmpty ? "Presets" : "Custom"
    }

    /// The form behind the “+” button: a preset name and the preview text it
    /// inserts, starting from the text that is already in the field.
    private var addPresetForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetField("Name", prompt: "e.g. abc, lorem, symbols", text: $newPresetName)
                .focused($newPresetNameFocused)
            presetField("Preview Text", prompt: "Sample preview text", text: $newPresetText)

            HStack {
                Button("Cancel") { isAddingPreset = false }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button("Save") { savePreset() }
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
