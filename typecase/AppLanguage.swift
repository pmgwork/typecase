import Foundation

/// The app's language override. Foundation reads AppleLanguages at launch,
/// keeping SwiftUI, AppKit, menus, and String(localized:) in the same language.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case korean = "ko"

    var id: String { rawValue }

    /// Native names keep the choices recognizable in every interface language.
    var title: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .english: "English"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .korean: "한국어"
        }
    }

    static func load(from defaults: UserDefaults, domain: String) -> Self {
        // Read only the app domain: the global AppleLanguages value is the
        // system preference, not an explicit choice for this app.
        guard let languages = defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
              !languages.isEmpty else { return .system }
        let supported = allCases.filter { $0 != .system }.map(\.rawValue)
        let identifier = Bundle.preferredLocalizations(from: supported, forPreferences: languages).first
        return identifier.flatMap(Self.init(rawValue:)) ?? .system
    }

    func save(to defaults: UserDefaults) {
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
