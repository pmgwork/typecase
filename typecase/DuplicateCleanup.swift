import Foundation

/// File-level cleanup tracks every face, including unique faces in collections.
nonisolated struct DuplicateCleanupFile: Identifiable, Hashable, Sendable {
    let url: URL
    let names: Set<String>
    var protectionReason: String?
    let size: Int64
    let modified: Date?
    /// Loaded by Core Text. A copy TypeCase activated has no protection reason:
    /// cleanup turns it off before moving it.
    var isActive = false
    /// In use outside TypeCase but in a place the person can clean up. It
    /// stays protected until they unlock it.
    var isUnlockable = false
    /// In ~/Library/Fonts, which the sandbox lets TypeCase move only once
    /// the person adds it as a folder.
    var needsFolderAccess = false

    var id: URL { url }
}

nonisolated enum DuplicateCleanupPolicy {
    /// The files with the unlocked copies' protection lifted. An unlocked
    /// copy can be selected explicitly even if its faces have no other copy.
    static func unlocking(_ urls: Set<URL>, in files: [DuplicateCleanupFile]) -> [DuplicateCleanupFile] {
        files.map { file in
            guard file.isUnlockable, urls.contains(file.url) else { return file }
            var unlocked = file
            unlocked.protectionReason = nil
            return unlocked
        }
    }

    static func canRemove(_ selected: Set<URL>, from files: [DuplicateCleanupFile]) -> Bool {
        guard !selected.isEmpty else { return false }
        let removing = files.filter { selected.contains($0.url) }
        guard removing.count == selected.count,
              removing.allSatisfy({ $0.protectionReason == nil && !$0.names.isEmpty }) else { return false }
        return true
    }

    /// Faces that disappear when the selected files move to Trash.
    static func missingNames(afterRemoving selected: Set<URL>, from files: [DuplicateCleanupFile]) -> Set<String> {
        let removingNames = Set(files.filter { selected.contains($0.url) }.flatMap(\.names))
        let survivingNames = Set(files.filter { !selected.contains($0.url) }.flatMap(\.names))
        return removingNames.subtracting(survivingNames)
    }
}
