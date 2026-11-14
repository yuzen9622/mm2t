import Foundation
import MM2TApp
import MM2TCore
import ObjectiveC
import SwiftUI

/// Switches the UI language while the app runs. macOS picks a bundle's language once at launch, so
/// SwiftUI's `Text` gets the language through the environment's locale, `String(localized:)` through
/// `InterfaceLanguage` (shadowed below), lookups through `Bundle.main` from the chosen `.lproj`, and
/// every root view is rebuilt. The choice is also saved as `AppleLanguages`,
/// so the next launch starts in it natively.
@MainActor @Observable
final class LiveLanguage {
    static let shared = LiveLanguage()

    /// Changes whenever the language does; roots use it as their identity to redraw every string.
    private(set) var revision = 0
    private(set) var locale = Locale.current

    func apply(_ language: AppLanguage) {
        language.save(in: .standard)
        let code = language == .system ? Self.systemLocalization : language.rawValue
        LocalizedMainBundle.use(code)
        locale = Locale(identifier: code)
        InterfaceLanguage.locale = locale
        revision += 1
    }

    /// The localization the Mac's own language order picks, ignoring the app's override.
    private static var systemLocalization: String {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: global ?? []).first ?? "en"
    }
}

extension String {
    /// Shadows Foundation's initializer in the app, which would keep the launch language, so every
    /// string follows a live switch; see `InterfaceLanguage`.
    init(localized keyAndValue: String.LocalizationValue, table: String? = nil, bundle: Bundle? = nil,
         locale: Locale = .current, comment: StaticString? = nil) {
        self = InterfaceLanguage.localized(keyAndValue, table: table, bundle: bundle, comment: comment)
    }
}

private nonisolated(unsafe) var overrideKey: UInt8 = 0

/// `Bundle.main`'s class while a language override is in place: string lookups go to that `.lproj`.
final class LocalizedMainBundle: Bundle, @unchecked Sendable {
    static func use(_ localization: String) {
        let path = Bundle.main.path(forResource: localization, ofType: "lproj")
            ?? Bundle.main.path(forResource: localization.components(separatedBy: "-").first, ofType: "lproj")
        object_setClass(Bundle.main, LocalizedMainBundle.self)
        objc_setAssociatedObject(Bundle.main, &overrideKey, path.flatMap(Bundle.init(path:)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let bundle = objc_getAssociatedObject(self, &overrideKey) as? Bundle else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension View {
    /// Redraws the view in the live UI language.
    func liveLanguage() -> some View { modifier(LiveLanguageModifier()) }
}

private struct LiveLanguageModifier: ViewModifier {
    func body(content: Content) -> some View {
        let language = LiveLanguage.shared
        content
            .environment(\.locale, language.locale)
            .id(language.revision)
    }
}
