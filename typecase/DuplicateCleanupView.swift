import SwiftUI

struct DuplicateCleanupView: View {
    @ObservedObject var catalog: FontCatalog
    let duplicates: [FontDuplicate]
    @Environment(\.dismiss) private var dismiss
    @State private var scannedFiles: [DuplicateCleanupFile] = []
    @State private var files: [DuplicateCleanupFile] = []
    @State private var filesByURL: [URL: DuplicateCleanupFile] = [:]
    @State private var visibleURLs: Set<URL> = []
    @State private var folderGroups: [FolderGroup] = []
    @State private var trashMessage = ""
    /// Copies in use that the person unlocked to clean up.
    @State private var unlocked: Set<URL> = []
    @State private var selected: Set<URL> = []
    @State private var versions: [URL: String] = [:]
    @State private var confirmsTrash = false
    @State private var failure: String?
    @State private var expandedFolders: Set<URL> = []
    @State private var isTrashing = false
    /// Set while a folder just added is being scanned, to reload the list.
    @State private var reloadsAfterScan = false

    private struct FolderGroup: Identifiable {
        let url: URL
        let files: [DuplicateCleanupFile]
        var id: URL { url }
    }

    private var isBusy: Bool { catalog.isLoading || catalog.isUpdatingActivation || isTrashing }
    private var canRemove: Bool {
        !isBusy && !selected.isEmpty && selected.allSatisfy {
            guard let file = filesByURL[$0] else { return false }
            return file.protectionReason == nil && !file.names.isEmpty
        }
    }

    private var selectedSize: Int64 {
        selected.reduce(0) { $0 + (filesByURL[$1]?.size ?? 0) }
    }

    private func makeTrashMessage() -> String {
        var paragraphs = [String(localized: "The selected files will move to Trash. You can restore them from Finder.")]
        if files.contains(where: { $0.isActive && selected.contains($0.url) }) {
            paragraphs.append(String(localized: "Enabled fonts in the selected files will be turned off. Styles without another enabled copy will no longer be available."))
        }
        let missing = DuplicateCleanupPolicy.missingNames(afterRemoving: selected, from: files)
        if !missing.isEmpty {
            paragraphs.append(String(localized: "These styles exist only in the selected files and will also be removed:") + "\n" + missing.sorted().joined(separator: "\n"))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Selection changes do not change the file list. Build its index and
    /// folder groups only after scanning or unlocking, not on each render.
    private func rebuildFiles() {
        files = DuplicateCleanupPolicy.unlocking(unlocked, in: scannedFiles)
        filesByURL = Dictionary(uniqueKeysWithValues: files.map { ($0.url, $0) })
        let visibleFiles = files.filter { visibleURLs.contains($0.url) }.sorted {
            if ($0.protectionReason == nil) != ($1.protectionReason == nil) { return $0.protectionReason == nil }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        folderGroups = Dictionary(grouping: visibleFiles, by: { $0.url.deletingLastPathComponent() })
            .map { FolderGroup(url: $0.key, files: $0.value) }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            footer
        }
        .padding(20)
        .frame(width: 620, height: 480)
        .task { await loadFiles() }
        .onChange(of: catalog.isLoading) { _, isLoading in
            // The scan can finish after the sheet opens, or after a folder is
            // added from here; fill the list then.
            guard !isLoading, scannedFiles.isEmpty || reloadsAfterScan else { return }
            reloadsAfterScan = false
            Task { await loadFiles() }
        }
        .confirmationDialog(String(localized: "Move selected font files to Trash?"), isPresented: $confirmsTrash, titleVisibility: .visible) {
            Button(String(localized: "Move to Trash"), role: .destructive) {
                Task {
                    isTrashing = true
                    defer { isTrashing = false }
                    do {
                        try await catalog.trashDuplicateFiles(selected, unlocked: unlocked, reviewed: files)
                        dismiss()
                    } catch {
                        failure = error.localizedDescription
                        scannedFiles = catalog.duplicateCleanupFiles()
                        rebuildFiles()
                        selected = []
                    }
                }
            }
        } message: {
            Text(trashMessage)
        }
        .alert(String(localized: "Could Not Clean Up Duplicates"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(String(localized: "OK")) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Clean Up Duplicates"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Keep the copies in use and move unneeded local files to Trash."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if catalog.isLoading && files.isEmpty {
            ProgressView(String(localized: "Loading fonts…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folderGroups.isEmpty {
            ContentUnavailableView(String(localized: "No duplicates"), image: "font.duplicate")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // One panel; folders and their files read as a single list.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(folderGroups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider() }
                        folderSection(group)
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if !selected.isEmpty && !canRemove {
                Label(String(localized: "The font files changed. Review the list again before cleaning up."), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    Text("\(selected.count) files selected")
                        .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                    if !selected.isEmpty {
                        Text(verbatim: "· " + Self.byteString(selectedSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .contentTransition(.numericText())
            }
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Move to Trash"), role: .destructive) {
                trashMessage = makeTrashMessage()
                confirmsTrash = true
            }
                .disabled(!canRemove)
        }
        .animation(.snappy(duration: 0.15), value: selected)
    }

    private func loadFiles() async {
        scannedFiles = catalog.duplicateCleanupFiles()
        selected = []
        unlocked = []
        versions = [:]
        visibleURLs = Set(duplicates.flatMap(\.copies).map { $0.url.standardizedFileURL })
        rebuildFiles()
        // Folders start folded; the row's count says what a folder holds.
        expandedFolders = []
        var loadedVersions: [URL: String] = [:]
        for file in folderGroups.flatMap(\.files) {
            guard let name = file.names.sorted().first else { continue }
            let metadata = await catalog.fontMetadata(forPostScriptName: name, fileURL: file.url)
            guard !Task.isCancelled else { return }
            // Drop the build notes after the first ";" (hotconv, ttfautohint…).
            loadedVersions[file.url] = metadata?.versionNumber?
                .split(separator: ";", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        versions = loadedVersions
    }

    private func folderSection(_ group: FolderGroup) -> some View {
        VStack(spacing: 0) {
            folderRow(group)
            if expandedFolders.contains(group.url) {
                VStack(spacing: 0) {
                    ForEach(group.files) { file in
                        fileRow(file)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func toggleExpanded(_ url: URL) {
        withAnimation(.snappy(duration: 0.2)) {
            if expandedFolders.contains(url) { expandedFolders.remove(url) } else { expandedFolders.insert(url) }
        }
    }

    private func folderRow(_ group: FolderGroup) -> some View {
        let removable = group.files.filter { protectionReason(for: $0) == nil }.map(\.url)
        let selectedHere = selected.intersection(removable)
        let allSelected = !removable.isEmpty && selectedHere.count == removable.count
        let isExpanded = expandedFolders.contains(group.url)
        let unlock = removable.isEmpty ? unlockAction(for: group.files) : nil

        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)

            // Mixed while only some of the folder's removable copies are picked.
            // A folder kept whole shows a locked box in its place.
            ZStack {
                // Two aggregate bindings preserve the mixed state without
                // one State mutation for every file in a folder.
                Toggle(sources: [
                    folderSelectionBinding(removable, value: allSelected),
                    folderSelectionBinding(removable, value: !selectedHere.isEmpty),
                ], isOn: \.self) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(removable.isEmpty || isBusy)
                    .accessibilityLabel(group.url.lastPathComponent)
                    .opacity(removable.isEmpty ? 0 : 1)
                    .accessibilityHidden(removable.isEmpty)
                if removable.isEmpty {
                    LockedCheckbox(reason: folderProtectionReason(group), action: unlock).disabled(isBusy)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(group.url.lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text((group.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(group.url.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if removable.isEmpty {
                    Text(folderProtectionReason(group)).help(folderProtectionReason(group))
                } else if selectedHere.isEmpty {
                    Text("\(group.files.count) files")
                } else {
                    Text("\(selectedHere.count) of \(group.files.count) selected")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded(group.url) }
        .accessibilityAddTraits(.isButton)
    }

    private func fileRow(_ file: DuplicateCleanupFile) -> some View {
        let reason = protectionReason(for: file)
        let isEnabled = reason == nil && !isBusy
        let details = [
            versions[file.url].map { "v" + $0 },
        ].compactMap { $0 }

        let unlock = reason == nil ? nil : unlockAction(for: [file])

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                Toggle(isOn: selectionBinding(file.url)) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!isEnabled)
                    .accessibilityLabel(file.url.lastPathComponent)
                    // A kept copy shows a locked box instead.
                    .opacity(reason == nil ? 1 : 0)
                    .accessibilityHidden(reason != nil)
                if let reason { LockedCheckbox(reason: reason, action: unlock).disabled(isBusy) }
            }

            Text(file.url.lastPathComponent)
                .foregroundStyle(reason == nil ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: (reason.map { [$0] } ?? details).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        // Checkboxes sit under the folder's checkbox, one step in.
        .padding(.leading, 30)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // The whole row toggles, not only the small checkbox.
        .onTapGesture { if isEnabled { selectionBinding(file.url).wrappedValue.toggle() } }
        .help(([file.url.path] + file.names.sorted()).joined(separator: "\n"))
    }

    /// What the locked box does for copies in use: unlock the ones TypeCase
    /// can move, or ask for ~/Library/Fonts, which the sandbox reaches only
    /// once it is a folder here. Nil when nothing can be unlocked.
    private func unlockAction(for files: [DuplicateCleanupFile]) -> (() -> Void)? {
        let lockable = files.filter {
            $0.isUnlockable && !unlocked.contains($0.url) && protectionReason(for: $0) == $0.protectionReason
        }.map(\.url)
        if !lockable.isEmpty {
            return {
                unlocked.formUnion(lockable)
                rebuildFiles()
            }
        }
        if files.contains(where: \.needsFolderAccess) {
            return { catalog.addUserFontsFolder { _ in reloadsAfterScan = true } }
        }
        return nil
    }

    private func selectionBinding(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { selected.contains(url) },
            set: { if $0 { selected.insert(url) } else { selected.remove(url) } }
        )
    }

    private func folderSelectionBinding(_ urls: [URL], value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { isSelected in
            let updated = isSelected ? selected.union(urls) : selected.subtracting(urls)
            if updated != selected { selected = updated }
        })
    }

    /// Why nothing in a folder can go: the shared reason when every file has
    /// the same one, otherwise the general rule.
    private func folderProtectionReason(_ group: FolderGroup) -> String {
        let reasons = Set(group.files.compactMap(protectionReason(for:)))
        return reasons.count == 1 ? reasons.first! : String(localized: "Contains styles with no other copy")
    }

    private func protectionReason(for file: DuplicateCleanupFile) -> String? {
        file.protectionReason
    }
}

/// A checkbox-sized box with a lock, standing in for the checkbox of copies
/// that stay. With an action, clicking it unlocks them; without one, the
/// lock is fixed and says why.
private struct LockedCheckbox: View {
    let reason: String
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { box(lock: .secondary) }
                .buttonStyle(.plain)
                .help(String(localized: "Unlock to select the copies in use"))
                .accessibilityLabel(String(localized: "Unlock"))
        } else {
            box(lock: .tertiary)
                .help(reason)
                .accessibilityLabel(reason)
        }
    }

    private func box(lock: HierarchicalShapeStyle) -> some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(lock)
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
    }
}
