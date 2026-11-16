import Foundation

// MARK: Caption translation

/// The two languages live captions translate between. Chinese is always Traditional (Taiwan).
public enum CaptionLanguage: String, Codable, Hashable, Sendable, CaseIterable {
    case traditionalChinese
    case english

    /// The share of Han characters among a text's letters above which it reads as Chinese.
    static let hanShare = 0.3

    /// Decides a caption's language from its script: more than 30% Han characters among its
    /// letters is Chinese, any other text with letters is English. Digits, punctuation and
    /// spaces are not letters; a text with no letters has no language and is not translated.
    public static func of(_ text: String) -> CaptionLanguage? {
        var letters = 0
        var han = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if scalar.properties.isIdeographic { han += 1 }
        }
        guard letters > 0 else { return nil }
        return Double(han) / Double(letters) > hanShare ? .traditionalChinese : .english
    }
}

/// Translates one caption on this Mac. Display only: nothing it returns is stored.
public protocol CaptionTranslator: Sendable {
    func translate(_ text: String, from source: CaptionLanguage, to target: CaptionLanguage) async throws -> String
}
