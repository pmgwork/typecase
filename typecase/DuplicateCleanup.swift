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

    /// Deterministic selection leaves at least one copy of every face, even
    /// when none is active or several collections overlap. Inactive copies
    /// go first so an active one is kept where possible.
    static func suggestedSelection(in files: [DuplicateCleanupFile], limitedTo urls: Set<URL>) -> Set<URL> {
        var selected: Set<URL> = []
        // Count once, then update only the faces in each proposed file. A
        // full-library scan per candidate makes automatic selection quadratic.
        var copies: [String: Int] = [:]
        var activeCopies: [String: Int] = [:]
        for file in files {
            for name in file.names {
                copies[name, default: 0] += 1
                if file.isActive { activeCopies[name, default: 0] += 1 }
            }
        }
        let ordered = files.filter { urls.contains($0.url) && $0.protectionReason == nil && !$0.names.isEmpty }.sorted {
            $0.isActive != $1.isActive ? !$0.isActive : $0.url.path < $1.url.path
        }
        for file in ordered {
            guard file.names.allSatisfy({ copies[$0, default: 0] > 1
                && (!file.isActive || activeCopies[$0, default: 0] > 1) }) else { continue }
            selected.insert(file.url)
            for name in file.names {
                copies[name, default: 0] -= 1
                if file.isActive { activeCopies[name, default: 0] -= 1 }
            }
        }
        return selected
    }
}
