import SwiftUI

struct ContentView: View {
    @StateObject private var store = FontLibraryStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorVisible = true
    @State private var comparisonVisible = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            FontLibraryView(store: store)
        }
        .navigationTitle("TypeCase")
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Font or foundry")
        .inspector(isPresented: $inspectorVisible) {
            FontInspector(store: store, comparisonVisible: $comparisonVisible)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 400)
        }
        // Keep the window's minimum size independent of sidebar and inspector visibility.
        // Otherwise AppKit changes the window frame when a split-view column is restored.
        .frame(minWidth: 860, minHeight: 520)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Add Font Folder…") { store.addFolder() }
                    Divider()
                    Button("Refresh Font Library") { store.refresh() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a font folder or refresh the library")

                Menu {
                    Picker("Category", selection: $store.category) {
                        Text("All Categories").tag(FontCategory?.none)
                        ForEach(FontCategory.allCases) { category in
                            Text(category.title).tag(Optional(category))
                        }
                    }
                    Divider()
                    Picker("Status", selection: $store.activationFilter) {
                        ForEach(ActivationFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter by category and status")

                Button {
                    comparisonVisible = true
                } label: {
                    Label(compareTitle, systemImage: "rectangle.split.2x1")
                }
                .disabled(store.selection.count < 2)
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
            ComparisonView(store: store, families: store.selectedFamilies)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFontFolder)) { _ in
            store.addFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshFontLibrary)) { _ in
            store.refresh()
        }
        .alert("TypeCase", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var compareTitle: String {
        store.selection.count > 1 ? "Compare \(store.selection.count)" : "Compare"
    }
}

private struct Sidebar: View {
    @ObservedObject var store: FontLibraryStore
    @State private var isDropTargeted = false

    var body: some View {
        List(selection: $store.librarySelection) {
            Section {
                ForEach([LibrarySection.all, .favorites]) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(section == .all ? store.families.count : 0)
                        .tag(LibrarySelection.section(section))
                }

                Label(LibrarySection.system.title, systemImage: LibrarySection.system.systemImage)
                    .badge(systemFontCount)
                    .tag(LibrarySelection.section(.system))

                ForEach(SystemFontScope.allCases, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.systemImage)
                        .padding(.leading, 20)
                        .tag(LibrarySelection.systemScope(scope))
                }

                ForEach([LibrarySection.local, .adobe, .morisawa]) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(LibrarySelection.section(section))
                }
            }

            Section("Folders") {
                if store.folders.isEmpty {
                    Label("Drop folders here", systemImage: "plus")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    OutlineGroup(store.folderTrees, children: \.children) { node in
                        Label(node.url.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .tag(LibrarySelection.folder(node.url))
                            .help(node.url.path)
                            .contextMenu {
                                Button("Show in Finder") { store.revealFolder(node.url) }
                                if store.folders.contains(where: { $0.standardizedFileURL == node.url.standardizedFileURL }) {
                                    Divider()
                                    Button("Remove", role: .destructive) { store.removeFolder(node.url) }
                                }
                            }
                    }
                }
            }

            if !store.allTags.isEmpty {
                Section("Tags") {
                    ForEach(store.allTags, id: \.self) { tag in
                        Button {
                            store.librarySelection = .section(.all)
                            store.searchText = tag
                        } label: {
                            Label(tag, systemImage: "tag")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            store.addFolders(urls)
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

    private var systemFontCount: Int {
        store.families.filter { $0.source == .system }.count
    }

}

private struct FontLibraryView: View {
    @ObservedObject var store: FontLibraryStore
    @State private var expandedFamilyIDs: Set<FontFamily.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            if !store.families.isEmpty {
                previewControls
                Divider()
            }
            if store.filteredFamilies.isEmpty {
                emptyState
            } else {
                List(selection: $store.selection) {
                    ForEach(store.filteredFamilies) { family in
                        FontFamilyRow(
                            store: store,
                            family: family,
                            isExpanded: expandedFamilyIDs.contains(family.id),
                            toggleExpanded: { toggleExpanded(family) }
                        )
                            .tag(family.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 640)
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if store.families.isEmpty {
                ContentUnavailableView {
                    Label("No fonts in the library", systemImage: "textformat")
                } description: {
                    Text("Installed fonts are read automatically. Add a folder to include the font files stored on disk.")
                } actions: {
                    Button("Add Font Folder…") { store.addFolder() }
                    Button("Refresh") { store.refresh() }
                }
            } else if store.sectionIsEmpty {
                ContentUnavailableView {
                    Label(emptySectionTitle, systemImage: store.librarySelection.systemImage)
                } description: {
                    Text(emptySectionMessage)
                } actions: {
                    if store.librarySelection == .section(.local) {
                        Button("Add Font Folder…") { store.addFolder() }
                    }
                    Button("Show All Fonts") { store.librarySelection = .section(.all) }
                }
            } else {
                ContentUnavailableView {
                    Label("No fonts match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(filterSummary.isEmpty ? "Change the search text or filters." : filterSummary)
                } actions: {
                    Button("Clear Filters") { store.clearFilters() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterSummary: String {
        var parts: [String] = []
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append("Search: “\(query)”") }
        if let category = store.category { parts.append("Category: \(category.title)") }
        if store.activationFilter != .all { parts.append("Status: \(store.activationFilter.title)") }
        return parts.joined(separator: " · ")
    }

    private var emptySectionTitle: String {
        switch store.librarySelection {
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
        switch store.librarySelection {
        case .section(.favorites): "Select a font and click the star to keep it here."
        case .section(.local): "Add a folder that contains font files to browse them without installing."
        case .section(.adobe): "Fonts activated in Adobe Creative Cloud appear here."
        case .section(.morisawa): "Fonts activated in Morisawa Desktop Manager appear here."
        case .folder: "This folder does not contain any supported font files."
        case .systemScope: "No fonts were found in this installation scope."
        case .section(.all), .section(.system): "Change the search text or filters."
        }
    }

    private var previewControls: some View {
        HStack(spacing: 12) {
            TextField("Sample text", text: $store.previewText)
                .textFieldStyle(.roundedBorder)
                .help("Leave empty to use the built-in sample for each language")

            Slider(value: $store.previewSize, in: 18...72, step: 1)
                .frame(minWidth: 80, maxWidth: 160)
                .help("Preview size")

            Text("\(Int(store.previewSize)) pt")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleExpanded(_ family: FontFamily) {
        if expandedFamilyIDs.contains(family.id) {
            expandedFamilyIDs.remove(family.id)
        } else {
            expandedFamilyIDs.insert(family.id)
        }
    }
}

private struct FontFamilyRow: View {
    @ObservedObject var store: FontLibraryStore
    let family: FontFamily
    let isExpanded: Bool
    let toggleExpanded: () -> Void

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
                if family.faces.count > 1 {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if family.source != .system {
                    Text(family.source.shortTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    store.toggleFavorite(family)
                } label: {
                    Image(systemName: store.isFavorite(family) ? "star.fill" : "star")
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
                                text: store.previewText(for: family),
                                postScriptName: face.postScriptName,
                                size: store.previewSize
                            )
                        }
                    }
                }
            } else {
                FontPreviewText(
                    text: store.previewText(for: family),
                    postScriptName: family.previewFace?.postScriptName,
                    size: store.previewSize
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
                store.setEnabled(!family.isEnabled || family.isPartiallyEnabled, family: family)
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
    @ObservedObject var store: FontLibraryStore
    @Binding var comparisonVisible: Bool
    @State private var newTag = ""

    var body: some View {
        if let family = store.selectedFamily {
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
                        text: store.previewText(for: family),
                        postScriptName: family.previewFace?.postScriptName,
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

                    activationControl(for: family)

                    Divider()

                    tagsSection(for: family)

                    Divider()

                    stylesSection(for: family)
                }
                .padding(20)
            }
        } else if store.selection.count > 1 {
            ContentUnavailableView {
                Label("\(store.selection.count) fonts selected", systemImage: "rectangle.split.2x1")
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
            set: { store.setCategory($0, for: family) }
        )
    }

    @ViewBuilder
    private func activationControl(for family: FontFamily) -> some View {
        if family.isManaged {
            Toggle("Enabled", isOn: Binding(
                get: { family.isEnabled },
                set: { store.setEnabled($0, family: family) }
            ))
            .toggleStyle(.switch)
        } else {
            Label(managementMessage(for: family), systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func tagsSection(for family: FontFamily) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(.headline)
            ForEach(store.tags(for: family), id: \.self) { tag in
                HStack {
                    Label(tag, systemImage: "tag")
                    Spacer()
                    Button {
                        store.removeTag(tag, from: family)
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
                    store.addTag(newTag, to: family)
                    newTag = ""
                }
        }
    }

    private func stylesSection(for family: FontFamily) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Styles")
                .font(.headline)
            ForEach(family.faces) { face in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(face.styleName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if family.isManaged {
                            Image(systemName: face.isInstalled ? "circle.inset.filled" : "circle")
                                .font(.callout)
                                .foregroundStyle(face.isInstalled ? Color.accentColor : Color.secondary)
                                .help(face.isInstalled ? "Enabled" : "Disabled")
                        }
                    }
                    FontPreviewText(
                        text: store.previewText(for: family),
                        postScriptName: face.postScriptName,
                        size: 21
                    )
                }
            }
        }
    }

    private func managementMessage(for family: FontFamily) -> String {
        family.source.managementHint
    }
}

private struct ComparisonView: View {
    @ObservedObject var store: FontLibraryStore
    @State private var families: [FontFamily]
    @Environment(\.dismiss) private var dismiss

    init(store: FontLibraryStore, families: [FontFamily]) {
        self.store = store
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
                    TextField("Sample text", text: $store.previewText)
                        .textFieldStyle(.roundedBorder)
                    Slider(value: $store.previewSize, in: 18...72, step: 1)
                        .frame(width: 120)
                    Text("\(Int(store.previewSize)) pt")
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
                                text: store.previewText(for: family),
                                postScriptName: family.previewFace?.postScriptName,
                                size: store.previewSize,
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
}
