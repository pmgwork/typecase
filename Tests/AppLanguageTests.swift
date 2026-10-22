import Foundation

@main
struct AppLanguageTests {
    static func main() {
        let domain = "typecase.tests.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        precondition(AppLanguage.load(from: defaults, domain: domain) == .system)
        for language in AppLanguage.allCases where language != .system {
            language.save(to: defaults)
            precondition(defaults.stringArray(forKey: "AppleLanguages") == [language.rawValue])
            precondition(AppLanguage.load(from: defaults, domain: domain) == language)
        }
        defaults.set(["zh-TW"], forKey: "AppleLanguages")
        precondition(AppLanguage.load(from: defaults, domain: domain) == .traditionalChinese)
        defaults.set(["en-US"], forKey: "AppleLanguages")
        precondition(AppLanguage.load(from: defaults, domain: domain) == .english)
        AppLanguage.system.save(to: defaults)
        precondition(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        precondition(AppLanguage.load(from: defaults, domain: domain) == .system)
        print("PASS: language persistence, region variants, and restoring system preference")
    }
}
