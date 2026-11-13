import Foundation
import MM2TCore

extension String {
    /// Shadows Foundation's initializer in this module so text follows a live language switch;
    /// see `InterfaceLanguage`.
    init(localized keyAndValue: String.LocalizationValue, table: String? = nil, bundle: Bundle? = nil,
         locale: Locale = .current, comment: StaticString? = nil) {
        self = InterfaceLanguage.localized(keyAndValue, table: table, bundle: bundle, comment: comment)
    }
}
