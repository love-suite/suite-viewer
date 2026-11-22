import Foundation

// NSLocalizedString(bundle: .module) uses Bundle.main.preferredLocalizations to pick the
// language, which only reflects the app's own fr.lproj — not the per-app AppleLanguages
// preference we write. Load the right lproj explicitly instead.
// `value` is the English text when the key isn't it, for a word with two meanings ("Edit", the menu,
// and "Edit", the button, are "Édition" and "Modifier" in French).
func UIL(_ key: String, value: String? = nil) -> String {
    let lang = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?
        .first.map { String($0.prefix(2)) } ?? "en"
    if let path = Bundle.module.path(forResource: lang, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: value ?? key, table: nil)
    }
    return NSLocalizedString(key, bundle: .module, value: value ?? key, comment: "")
}
