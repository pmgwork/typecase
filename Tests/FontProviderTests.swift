import Foundation

@main
struct FontProviderTests {
    static func main() throws {
        let registry = FontProviderRegistry.self
        precondition(registry.all.map(\.id) == ["adobe", "morisawa", "fontworks", "monotype"])
        precondition(registry.fontworks.title == "LETS")
        precondition(registry.all.allSatisfy { $0.icon == .symbol("cloud") })
        // The service's actual cache marker, including randomized temp roots.
        for prefix in ["/private/var/folders/ab/cd/T", "/tmp"] {
            precondition(registry.match(path: prefix + "/.monotypefonts-501/font.otf", manufacturer: "Independent Foundry")?.id == "monotype")
        }
        // Foundry metadata is not evidence of a service subscription.
        for manufacturer in ["Monotype Imaging", "Adobe Systems Incorporated", "Fontworks"] {
            precondition(registry.match(path: "/Users/test/Fonts/Purchased/font.otf", manufacturer: manufacturer) == nil)
        }
        precondition(registry.match(path: "/System/Library/Fonts/Times.ttc", manufacturer: "Monotype") == nil)
        precondition(registry.match(path: "/Users/test/Fonts/Adobe/font.otf", manufacturer: "Adobe") == nil)
        precondition(registry.match(path: "/Users/test/Library/Application Support/Adobe/CoreSync/plugins/livetype/.r/font", manufacturer: "Other")?.id == "adobe")
        precondition(registry.match(path: "/Users/test/Library/Fonts/MorisawaFonts/font.otf", manufacturer: "Other")?.id == "morisawa")
        // LETS uses a manifest because its files can live in Library/Fonts.
        let manifests: [String: Set<String>] = ["fontworks": ["lets-face.otf"]]
        precondition(registry.match(path: "/Users/test/Library/Fonts/LETS-face.otf", manufacturer: "Monotype", manifestNames: manifests, fileName: "LETS-face.otf")?.id == "fontworks")
        precondition(registry.provider(withID: "fontworks")?.title == "LETS")
        precondition(registry.match(path: "/tmp/.monotypefonts-501/font.otf", manufacturer: "Other", manifestNames: ["fontworks": ["font.otf"]], fileName: "font.otf")?.id == "fontworks")
        print("PASS: Monotype cache detection, LETS identity/manifest priority, owned/system font exclusions, neutral icons")
    }
}
