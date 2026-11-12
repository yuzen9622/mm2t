import Foundation
import MM2TApp
import ObjectiveC
import SwiftUI

/// Switches the UI language while the app runs. macOS picks a bundle's language once at launch, so
/// `Bundle.main` is pointed at the chosen `.lproj` (which `String(localized:)` and SwiftUI's `Text`
/// both read through) and every root view is rebuilt. The choice is also saved as `AppleLanguages`,
/// so the next launch starts in it natively.
@MainActor @Observable
final class LiveLanguage {
    static let shared = LiveLanguage()

    /// Changes whenever the language does; roots use it as their identity to redraw every string.
    private(set) var revision = 0
    private(set) var locale = Locale.current

    /// `persist: false` switches this run only (debug snapshots must not touch the user's defaults).
    func apply(_ language: AppLanguage, persist: Bool = true) {
        if persist { language.save(in: .standard) }
        let code = language == .system ? Self.systemLocalization : language.rawValue
        LocalizedMainBundle.use(code)
        locale = Locale(identifier: code)
        revision += 1
    }

    /// The localization the Mac's own language order picks, ignoring the app's override.
    private static var systemLocalization: String {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: global ?? []).first ?? "en"
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
