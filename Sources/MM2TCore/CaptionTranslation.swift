import Foundation

// MARK: Caption translation

/// The two languages live captions are spoken in, as far as translation tells them apart.
/// Chinese captions are always Traditional (Taiwan).
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

/// A language live captions can be translated into, shown by its flag and its own name. Adding
/// one is a row in `all` and its model files in `TranslationModels.mozilla`.
public struct CaptionTarget: Hashable, Sendable, Identifiable {
    /// What settings store.
    public let id: String
    /// The language's name in that language; never localized.
    public let name: String
    public let flag: String
    /// Mozilla's code for the language in its translation models.
    public let code: String

    public static let traditionalChinese = CaptionTarget(id: "traditionalChinese", name: "繁體中文", flag: "🇹🇼", code: "zh_hant")
    public static let simplifiedChinese = CaptionTarget(id: "simplifiedChinese", name: "简体中文", flag: "🇨🇳", code: "zh")
    public static let korean = CaptionTarget(id: "korean", name: "한국어", flag: "🇰🇷", code: "ko")
    public static let japanese = CaptionTarget(id: "japanese", name: "日本語", flag: "🇯🇵", code: "ja")
    public static let english = CaptionTarget(id: "english", name: "English", flag: "🇺🇸", code: "en")
    public static let german = CaptionTarget(id: "german", name: "Deutsch", flag: "🇩🇪", code: "de")
    public static let czech = CaptionTarget(id: "czech", name: "Čeština", flag: "🇨🇿", code: "cs")

    /// In the order a menu lists them.
    public static let all: [CaptionTarget] = [traditionalChinese, simplifiedChinese, korean, japanese, english, german, czech]

    public static func with(id: String) -> CaptionTarget? { all.first { $0.id == id } }

    /// How a caption in `source` reaches this language.
    public func route(from source: CaptionLanguage) -> CaptionRoute {
        switch source {
        case .english:
            return self == .english ? .none : .models(["en", code])
        case .traditionalChinese:
            if self == .traditionalChinese { return .none }
            if self == .simplifiedChinese { return .simplify }
            // Mozilla translates Chinese only into English, so other languages go through English.
            return .models(self == .english ? ["zh_hant", "en"] : ["zh_hant", "en", code])
        }
    }

    /// Every model a recording translating into this language may use, as source-target codes.
    public var modelPairs: [ModelPair] {
        var pairs: [ModelPair] = []
        for source in CaptionLanguage.allCases {
            guard case .models(let path) = route(from: source) else { continue }
            for pair in zip(path, path.dropFirst()).map(ModelPair.init) where !pairs.contains(pair) { pairs.append(pair) }
        }
        return pairs
    }
}

/// One translation model's direction, by Mozilla's language codes.
public struct ModelPair: Hashable, Sendable, CustomStringConvertible {
    public let source: String
    public let target: String

    public init(_ source: String, _ target: String) {
        self.source = source
        self.target = target
    }

    public var description: String { "\(source)-\(target)" }
}

/// What turning a caption into the target language takes.
public enum CaptionRoute: Equatable, Sendable {
    /// It is already in the target language.
    case none
    /// Chinese into Simplified characters: a script conversion, no model.
    case simplify
    /// Through these languages in turn, one model per step.
    case models([String])
}

/// Translates one caption on this Mac. Display only: nothing it returns is stored.
public protocol CaptionTranslator: Sendable {
    /// Translates `text` from `languages[0]` into the last language, one model per step.
    func translate(_ text: String, through languages: [String]) async throws -> String
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

    /// Everything up to the last word known to be complete: a Han or kana character always is, a
    /// word in a spaced script (English, Korean) only once a space follows it.
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

    /// Han and Japanese kana: scripts written without spaces, where each character stands alone.
    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
        }
    }
}
