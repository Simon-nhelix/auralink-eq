import Foundation

/// App-owned UI copy. The selected language follows macOS preferences at
/// launch, with English as the fallback. Explicit language overrides make
/// resource and formatting tests independent of the developer's system.
public enum L10n {
    public static let supportedLanguages = ["en", "ko", "ja"]
    public static let currentLanguage = language(for: Locale.preferredLanguages)
    /// Installed .app bundles keep resources in Contents/Resources. Resolve
    /// that path first so lookup never depends on SwiftPM's build-directory
    /// fallback (its generated main-bundle path varies between toolchains).
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Auralink_AuralinkLocalization.bundle"),
           let installed = Bundle(url: url) {
            return installed
        }
        return Bundle.module
    }()
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        supportedLanguages.compactMap { language in
            guard let path = resources.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        }
    )

    public static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(
            from: supportedLanguages,
            forPreferences: preferences
        ).first ?? "en"
    }

    public static func text(_ key: String, language: String? = nil) -> String {
        let selected = language.map { self.language(for: [$0]) } ?? currentLanguage
        let english = bundle(for: "en").localizedString(forKey: key, value: key, table: nil)
        return bundle(for: selected).localizedString(forKey: key, value: english, table: nil)
    }

    /// Use whole-sentence templates; positional placeholders let translators
    /// reorder arguments without concatenating fragments of translated copy.
    public static func format(_ key: String, _ arguments: CVarArg..., language: String? = nil) -> String {
        let selected = language.map { self.language(for: [$0]) } ?? currentLanguage
        return String(
            format: text(key, language: selected),
            locale: Locale(identifier: selected),
            arguments: arguments
        )
    }

    static func bundle(for language: String) -> Bundle {
        bundles[language] ?? resources
    }
}
