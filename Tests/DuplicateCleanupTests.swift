import Foundation

@main
struct DuplicateCleanupTests {
    static func main() {
        func file(_ name: String, _ names: Set<String>, protected: Bool = false) -> DuplicateCleanupFile {
            DuplicateCleanupFile(url: URL(fileURLWithPath: "/fixtures/\(name)"), names: names,
                                 protectionReason: protected ? "In Use" : nil, size: 100, modified: nil, isActive: protected)
        }
        let active = file("active.ttf", ["Regular"], protected: true)
        let old = file("old.ttf", ["Regular"])
        let third = file("third.ttf", ["Regular"])
        let collection = file("collection.ttc", ["Regular", "UniqueBold"])
        let files = [active, old, third, collection]
        precondition(DuplicateCleanupPolicy.canRemove([old.url, third.url], from: files))
        precondition(!DuplicateCleanupPolicy.canRemove([active.url], from: files))
        precondition(DuplicateCleanupPolicy.canRemove([collection.url], from: files), "Unique faces may be removed explicitly")
        precondition(DuplicateCleanupPolicy.missingNames(afterRemoving: [collection.url], from: files) == ["UniqueBold"])
        precondition(DuplicateCleanupPolicy.missingNames(afterRemoving: [old.url, third.url], from: files).isEmpty)
        precondition(!DuplicateCleanupPolicy.canRemove([], from: files))
        precondition(!DuplicateCleanupPolicy.canRemove([URL(fileURLWithPath: "/unknown.ttf")], from: files))
        let inactive = [file("a.ttf", ["Regular"]), file("b.ttf", ["Regular"])]
        precondition(DuplicateCleanupPolicy.canRemove(Set(inactive.map(\.url)), from: inactive), "Every copy may be selected explicitly")
        precondition(DuplicateCleanupPolicy.missingNames(afterRemoving: Set(inactive.map(\.url)), from: inactive) == ["Regular"])

        func enabled(_ name: String, _ names: Set<String>) -> DuplicateCleanupFile {
            DuplicateCleanupFile(url: URL(fileURLWithPath: "/fixtures/\(name)"), names: names,
                                 protectionReason: nil, size: 100, modified: nil, isActive: true)
        }
        let bothOn = [enabled("a.ttf", ["Regular"]), enabled("b.ttf", ["Regular"])]
        precondition(DuplicateCleanupPolicy.canRemove([bothOn[0].url], from: bothOn), "An enabled copy can go while another stays on")
        precondition(DuplicateCleanupPolicy.canRemove(Set(bothOn.map(\.url)), from: bothOn), "Every enabled copy may be selected explicitly")
        let onAndOff = [enabled("a.ttf", ["Regular"]), file("b.ttf", ["Regular"])]
        precondition(DuplicateCleanupPolicy.canRemove([onAndOff[0].url], from: onAndOff), "The only enabled copy may be selected explicitly")
        precondition(DuplicateCleanupPolicy.missingNames(afterRemoving: [onAndOff[0].url], from: onAndOff).isEmpty)
        precondition(DuplicateCleanupPolicy.canRemove([onAndOff[1].url], from: onAndOff))
        let installedAndOn = [active, enabled("b.ttf", ["Regular"])]
        precondition(DuplicateCleanupPolicy.canRemove([installedAndOn[1].url], from: installedAndOn),
                     "An installed copy keeps the face on")
        var lockedInstall = enabled("installed.ttf", ["Regular"])
        lockedInstall.protectionReason = "In Use"
        lockedInstall.isUnlockable = true
        let withLocked = [lockedInstall, enabled("b.ttf", ["Regular"])]
        precondition(!DuplicateCleanupPolicy.canRemove([lockedInstall.url], from: withLocked), "A copy in use stays locked")
        let opened = DuplicateCleanupPolicy.unlocking([lockedInstall.url], in: withLocked)
        precondition(DuplicateCleanupPolicy.canRemove([lockedInstall.url], from: opened), "An unlocked copy can go while another stays on")
        precondition(DuplicateCleanupPolicy.canRemove(Set(withLocked.map(\.url)), from: opened), "Unlocked copies allow explicit removal of all copies")
        let fixed = DuplicateCleanupPolicy.unlocking([active.url], in: files)
        precondition(fixed == files, "Only unlockable copies unlock")
        print("PASS: explicit removal, unique-face warnings, unlocking, and protected copies")
    }
}
