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

/// Which part of an unfinished caption is worth translating now. Machine translation of a clause
/// still being spoken rewrites its earlier words, so only settled clauses are sent, and only when
/// they have grown since the last send.
public enum PartialTranslationPolicy {
    /// Clause boundaries in English and Chinese text.
    public static let boundaries: Set<Character> = [",", ".", "?", "!", ";", ":", "，", "。", "？", "！", "；", "：", "、"]
    /// Without a boundary, a partial this much longer than the last send is sent up to its last whole word.
    public static let wordGrowth = 8
    public static let hanGrowth = 16
    /// The least time between two sends of the same unfinished caption.
    public static let minimumGap: TimeInterval = 0.25

    /// The text to translate now, or nil to keep showing the last translation. `lastSent` is what
    /// was last sent for this same unfinished caption.
    public static func stablePart(of partial: String, lastSent: String?) -> String? {
        let sent = lastSent ?? ""
        let candidate: String
        if let boundary = partial.lastIndex(where: boundaries.contains) {
            candidate = String(partial[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard words(partial) - words(sent) >= wordGrowth || han(partial) - han(sent) >= hanGrowth,
                  let whole = wholeWords(partial) else { return nil }
            candidate = whole
        }
        return candidate.count > sent.count ? candidate : nil
    }

    /// Everything up to the last word known to be complete: a Han character always is, a word in a
    /// spaced script only once a space follows it.
    static func wholeWords(_ text: String) -> String? {
        guard let last = text.last else { return nil }
        if last.isWhitespace || isHan(last) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let space = text.lastIndex(where: \.isWhitespace) else { return nil }
        let trimmed = String(text[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains { !isHan($0) && ($0.isLetter || $0.isNumber) } }.count
    }

    static func han(_ text: String) -> Int {
        text.filter(isHan).count
    }

    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic }
    }
}
