import Foundation

@main
struct FolderActivationTests {
    static func main() {
        func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
        let root = URL(fileURLWithPath: "/Library/TestFonts", isDirectory: true)
        let child = URL(fileURLWithPath: "/Library/TestFonts/Collection", isDirectory: true)
        let files = [
            FontActivationState(url: child.appendingPathComponent("Regular.ttc"), names: ["Regular", "Bold"], enabled: true),
            FontActivationState(url: child.appendingPathComponent("Nested/Italic.otf"), names: ["Italic"], enabled: false),
            FontActivationState(url: root.appendingPathComponent("Sibling/Bold.otf"), names: ["Bold"], enabled: false),
            FontActivationState(url: url("/Library/TestFontsOther/Outside.otf"), names: ["Outside"], enabled: true)
        ]
        let index = FontCatalog.folderActivationIndex(files + [files[0]], roots: [root, child])
        precondition(index[root]?.count == 3, "Nested roots and collection faces must not double count files")
        precondition(index[child]?.count == 2, "Sibling styles and prefix-sharing folders must stay outside the target")
        precondition(index[child]?.filter(\.enabled).count == 1, "Mixed activation must retain per-file state")
        precondition(index[URL(fileURLWithPath: "/Library/TestFonts/Collection/Nested", isDirectory: true)] == [files[1]])
        precondition(index[url("/Library")] == nil, "Never expose a parent outside the added roots")
        precondition(FontCatalog.folderActivationIndex(files, roots: []).isEmpty)
        print("PASS: folder activation scope, descendants, mixed states, overlapping roots, collections and deduplication")
    }
}
