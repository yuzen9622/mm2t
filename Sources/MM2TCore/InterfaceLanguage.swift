import Foundation
import os

/// The language the UI shows, which the app can switch while it runs. Foundation's
/// `String(localized:)` settles on a language once at launch and keeps it, so modules that show
/// text shadow that initializer with one that calls `localized(_:table:bundle:comment:)`, which asks
/// for this language by name.
public enum InterfaceLanguage {
    private static let chosen = OSAllocatedUnfairLock<Locale?>(initialState: nil)

    /// The language switched to while running; `nil` keeps the one the app launched in.
    public static var locale: Locale? {
        get { chosen.withLock { $0 } }
        set { chosen.withLock { $0 = newValue } }
    }

    public static func localized(_ value: String.LocalizationValue, table: String?, bundle: Bundle?, comment: StaticString?) -> String {
        let bundle = bundle ?? .main
        let locale = locale ?? Locale(identifier: bundle.preferredLocalizations.first ?? "en")
        return String(localized: LocalizedStringResource(value, table: table, locale: locale,
                                                         bundle: .atURL(bundle.bundleURL), comment: comment))
    }
}
