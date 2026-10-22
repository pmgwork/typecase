import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let languages = ["en", "ja", "zh-Hans", "zh-Hant", "ko"]
let keys = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
let strings = keys["strings"] as! [String: Any]
for language in languages {
    let bundle = Bundle(url: root.appendingPathComponent("\(language).lproj"))!
    for key in strings.keys {
        let result = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
        precondition(result != "__MISSING__", "Missing \(language): \(key)")
    }
    let locale = Locale(identifier: language)
    let one = String(localized: "\(1) styles", bundle: bundle, locale: locale)
    let many = String(localized: "\(12) styles", bundle: bundle, locale: locale)
    let percent = String(localized: "Custom (\(25)%)", bundle: bundle, locale: locale)
    let reordered = String(localized: "\(3) of \(12) characters", bundle: bundle, locale: locale)
    precondition(!percent.contains("%lld") && percent.contains("25"))
    if language == "en" {
        precondition(one == "1 style" && many == "12 styles")
    }
    print("PASS \(language): \(one) / \(many) / \(percent) / \(reordered)")
}
