import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var catalog: FontCatalog
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
        .searchable(text: $viewState.searchText, placement: .toolbar, prompt: "Font or foundry")
        .inspector(isPresented: $inspectorVisible) {
            FontInspector(catalog: catalog, viewState: viewState, comparisonVisible: $comparisonVisible)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 400)
        }
        // Keep the window's minimum size independent of sidebar and inspector visibility.
        // Otherwise AppKit changes the window frame when a split-view column is restored.
        .frame(minWidth: 860, minHeight: 520)
        .toolbar {
            ToolbarItemGroup {
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
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter by category and status")
            }

            // Keep the size control separate from the button groups so it reads
            // as its own control instead of merging into their background.
            ToolbarItem {
                PreviewSizeControl(size: $viewState.previewSize)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItemGroup {
                Button {
                    comparisonVisible = true
                } label: {
                    Label(compareTitle, systemImage: "rectangle.split.2x1")
                }
                .disabled(viewState.selection.count < 2)
                .help("Compare the selected fonts side by side")

                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
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
            viewState.reconcile(with: catalog)
        }
        .background(WindowAccessor { window = $0 })
        .onChange(of: catalog.familiesRevision) { _, _ in
            viewState.reconcile(with: catalog)
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

    private var compareTitle: String {
        viewState.selection.count > 1 ? "Compare \(viewState.selection.count)" : "Compare"
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

private struct Sidebar: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @AppStorage("systemScopesExpanded") private var systemScopesExpanded = true
    @State private var isDropTargeted = false

    var body: some View {
        List(selection: $viewState.librarySelection) {
            Section {
                ForEach([LibrarySection.all, .favorites]) { section in
                    let selection = LibrarySelection.section(section)
                    SidebarLabel(title: section.title, systemImage: section.systemImage)
                        .badge(selectedCount(for: selection))
                        .tag(selection)
                }

                DisclosureGroup(isExpanded: $systemScopesExpanded) {
                    ForEach(SystemFontScope.allCases, id: \.self) { scope in
                        // Indent with a spacer instead of leading padding: a padded row is
                        // treated as a nested sidebar row and rendered with a smaller font.
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 20, height: 1)
                            SidebarLabel(title: scope.title, systemImage: scope.systemImage)
                        }
                        .badge(selectedCount(for: .systemScope(scope)))
                        .tag(LibrarySelection.systemScope(scope))
                    }
                } label: {
                    HStack(spacing: 6) {
                        SidebarLabel(title: LibrarySection.system.title, systemImage: LibrarySection.system.systemImage)
                        Spacer(minLength: 6)
                        if viewState.librarySelection == .section(.system) {
                            Text("\(catalog.fontCount(for: .section(.system)))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(LibrarySelection.section(.system))
                }

                ForEach([LibrarySection.local, .adobe, .morisawa]) { section in
                    let selection = LibrarySelection.section(section)
                    SidebarLabel(title: section.title, systemImage: section.systemImage)
                        .badge(selectedCount(for: selection))
                        .tag(selection)
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
                Text("Folders")
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            if !catalog.allTags.isEmpty {
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
        // Sidebar-scoped toolbar item: appears in the sidebar’s own toolbar area.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    catalog.addFolder { url in viewState.librarySelection = .folder(url) }
                } label: {
                    Label("Add Font Folder", systemImage: "plus")
                }
                .help("Add a font folder")
            }
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
    @State private var expandedFamilyIDs: Set<FontFamily.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            let output = viewState.filter(catalog: catalog)
            if output.families.isEmpty {
                emptyState(output: output)
            } else {
                List(selection: $viewState.selection) {
                    ForEach(output.families) { family in
                        FontFamilyRow(
                            family: family,
                            isExpanded: expandedFamilyIDs.contains(family.id),
                            previewText: viewState.previewText(for: family),
                            previewSize: viewState.previewSize,
                            isFavorite: catalog.isFavorite(family),
                            toggleExpanded: { toggleExpanded(family) },
                            toggleFavorite: { catalog.toggleFavorite(family) },
                            toggleEnabled: {
                                catalog.setEnabled(!family.isEnabled || family.isPartiallyEnabled, family: family)
                            }
                        )
                            .equatable()
                            .tag(family.id)
                    }
                }
                .listStyle(.inset)
                // The preview-text editor stays pinned below the list.
                Divider()
                PreviewTextEditor(viewState: viewState)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 640)
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
                    Label(emptySectionTitle, systemImage: viewState.librarySelection.systemImage)
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
                    Button("Clear Filters") { viewState.clearFilters() }
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
        return parts.joined(separator: " · ")
    }

    private var emptySectionTitle: String {
        switch viewState.librarySelection {
        case .section(.favorites): "No favorites yet"
        case .section(.local): "No local fonts"
        case .section(.adobe): "No Adobe Fonts"
        case .section(.morisawa): "No Morisawa Fonts"
        case .folder(let folder): "No fonts in \(folder.lastPathComponent)"
        case .systemScope(let scope): "No fonts for \(scope.title)"
        case .section(.all), .section(.system): "No fonts"
        }
    }

    private var emptySectionMessage: String {
        switch viewState.librarySelection {
        case .section(.favorites): "Select a font and click the star to keep it here."
        case .section(.local): "Add a folder that contains font files to browse them without installing."
        case .section(.adobe): "Fonts activated in Adobe Creative Cloud appear here."
        case .section(.morisawa): "Fonts activated in Morisawa Desktop Manager appear here."
        case .folder: "This folder does not contain any supported font files."
        case .systemScope: "No fonts were found in this installation scope."
        case .section(.all), .section(.system): "Change the search text or filters."
        }
    }

    private func toggleExpanded(_ family: FontFamily) {
        if expandedFamilyIDs.contains(family.id) {
            expandedFamilyIDs.remove(family.id)
        } else {
            expandedFamilyIDs.insert(family.id)
        }
    }
}

private struct FontFamilyRow: View, Equatable {
    let family: FontFamily
    let isExpanded: Bool
    let previewText: String
    let previewSize: Double
    let isFavorite: Bool
    let toggleExpanded: () -> Void
    let toggleFavorite: () -> Void
    let toggleEnabled: () -> Void

    static func == (lhs: FontFamilyRow, rhs: FontFamilyRow) -> Bool {
        lhs.family == rhs.family
            && lhs.isExpanded == rhs.isExpanded
            && lhs.previewText == rhs.previewText
            && lhs.previewSize == rhs.previewSize
            && lhs.isFavorite == rhs.isFavorite
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
                            HStack {
                                Text(face.styleName)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if family.isManaged {
                                    Image(systemName: face.isInstalled ? "circle.inset.filled" : "circle")
                                        .font(.caption)
                                        .foregroundStyle(face.isInstalled ? Color.accentColor : Color.secondary)
                                }
                            }
                            FontPreviewText(
                                text: previewText,
                                postScriptName: face.postScriptName,
                                fileURL: face.fileURL,
                                size: previewSize
                            )
                        }
                    }
                }
            } else {
                FontPreviewText(
                    text: previewText,
                    postScriptName: family.previewFace?.postScriptName,
                    fileURL: family.previewFace?.fileURL,
                    size: previewSize
                )
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            toggleExpanded()
        }
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
        } else {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(family.source.managementHint)
        }
    }

    private var activationSymbol: String {
        if family.isPartiallyEnabled { return "circle.lefthalf.filled" }
        return family.isEnabled ? "circle.inset.filled" : "circle"
    }

    private var activationColor: Color {
        family.isEnabled ? .accentColor : .secondary
    }

    private var activationHelp: String {
        if family.isPartiallyEnabled { return "Some styles are disabled — click to enable all" }
        return family.isEnabled ? "Deactivate" : "Activate"
    }
}

private struct FontInspector: View {
    @ObservedObject var catalog: FontCatalog
    @ObservedObject var viewState: LibraryViewState
    @Binding var comparisonVisible: Bool
    @State private var newTag = ""

    var body: some View {
        if let family = catalog.family(for: viewState.selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

                    FontPreviewText(
                        text: viewState.previewText(for: family),
                        postScriptName: family.previewFace?.postScriptName,
                        fileURL: family.previewFace?.fileURL,
                        size: 40,
                        lines: 2
                    )

                    Group {
                        LabeledContent("Source", value: family.source.title)
                        LabeledContent("Language", value: family.supportsJapanese ? "Japanese" : "Latin / Other")
                        LabeledContent("Styles", value: "\(family.faces.count)")
                        LabeledContent("Classification") {
                            Picker("Classification", selection: classificationBinding(for: family)) {
                                ForEach(FontCategory.allCases) { category in
                                    Text(category.title).tag(category)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    if !family.isManaged {
                        Label(family.source.managementHint, systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    tagsSection(for: family)
                }
                .padding(20)
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
}

private struct ComparisonView: View {
    @ObservedObject var viewState: LibraryViewState
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
                    Slider(value: $viewState.previewSize, in: 18...72, step: 1)
                        .frame(width: 120)
                    Text("\(Int(viewState.previewSize)) pt")
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
                                text: viewState.previewText(for: family),
                                postScriptName: family.previewFace?.postScriptName,
                                fileURL: family.previewFace?.fileURL,
                                size: viewState.previewSize,
                                lines: 2
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
}

/// Reports the hosting `NSWindow` so menu commands can be routed to the key window.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// Sidebar rows keep their icons neutral; the accent color stays reserved for
/// selection and activation states.
private struct SidebarLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(Color(nsColor: .labelColor))
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        // Sidebar and OutlineGroup can otherwise reduce nested rows to the
        // smaller hierarchical style. Pin every navigation label to the same
        // AppKit system size while preserving indentation.
        .font(.system(size: NSFont.systemFontSize))
    }
}

/// Persistent preview-text editor with quick presets, pinned below the font
/// list: one text field above a row of sample chips.
private struct PreviewTextEditor: View {
    @ObservedObject var viewState: LibraryViewState
    @State private var customPresets = UserDefaults.standard.stringArray(forKey: PreviewTextEditor.presetsKey) ?? []

    private static let presetsKey = "previewTextPresets"

    private static let builtInPresets: [(title: String, text: String)] = [
        ("123", "0123456789"),
        ("ABC", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        ("abc", "abcdefghijklmnopqrstuvwxyz"),
        ("lorem", "Lorem ipsum dolor sit amet, consectetur adipiscing elit."),
        ("fox", "The quick brown fox jumps over the lazy dog."),
        ("deutsch", "Zwölf Boxkämpfer jagen Eva quer über den großen Sylter Deich."),
        ("français", "Portez ce vieux whisky au juge blond qui fume."),
        ("日本語", "美しい文字は、言葉の表情を豊かにする。"),
        ("symbols", "→ ← ↑ ↓ ★ ☆ ♠ ♥ ♦ ♣ € £ ¥ © ® ™"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Enter preview text…", text: $viewState.previewText)
                .textFieldStyle(.roundedBorder)

            FlowLayout(spacing: 8) {
                ForEach(Self.builtInPresets, id: \.title) { preset in
                    presetChip(preset.title) {
                        viewState.previewText = preset.text
                    }
                }

                ForEach(customPresets, id: \.self) { preset in
                    presetChip(preset) {
                        viewState.previewText = preset
                    }
                    .contextMenu {
                        Button("Remove Preset", role: .destructive) {
                            removePreset(preset)
                        }
                    }
                }

                Button {
                    addCurrentAsPreset()
                } label: {
                    chipLabel {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(.plain)
                .disabled(trimmedPreviewText.isEmpty)
                .help("Add the current text as a preset")
                .accessibilityLabel("Add the current text as a preset")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimmedPreviewText: String {
        viewState.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel {
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func chipLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(.rect)
    }

    private func addCurrentAsPreset() {
        let text = trimmedPreviewText
        guard !text.isEmpty, !customPresets.contains(text) else { return }
        customPresets.append(text)
        UserDefaults.standard.set(customPresets, forKey: Self.presetsKey)
    }

    private func removePreset(_ preset: String) {
        customPresets.removeAll { $0 == preset }
        UserDefaults.standard.set(customPresets, forKey: Self.presetsKey)
    }
}

/// Wraps chips onto as many lines as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lines: [[CGSize]] = []
        var line: [CGSize] = []
        var lineWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let candidate = line.isEmpty ? size.width : lineWidth + spacing + size.width
            if !line.isEmpty, candidate > maxWidth {
                lines.append(line)
                line = [size]
                lineWidth = size.width
            } else {
                line.append(size)
                lineWidth = candidate
            }
        }
        if !line.isEmpty { lines.append(line) }

        let height = lines.reduce(0) { $0 + ($1.map(\.height).max() ?? 0) }
            + spacing * CGFloat(max(lines.count - 1, 0))
        let width = lines.map { line in
            line.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(line.count - 1, 0))
        }.max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
