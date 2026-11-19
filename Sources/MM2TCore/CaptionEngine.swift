import Foundation

public enum CaptionEngine: String, Codable, CaseIterable, Sendable {
    case apple, firefox, hyMT2

    public static var initial: Self {
        if #available(macOS 26, *) { return .apple }
        return .firefox
    }
}

extension TranscriptionLanguage {
    public var fixedCaptionSource: CaptionLanguage? {
        switch self {
        case .auto: nil
        case .english: .english
        case .chinese: .traditionalChinese
        }
    }
}

extension CaptionTarget {
    /// Keep existing identifiers for Firefox languages. Other targets persist by language code.
    public init?(languageCode: String) {
        let tag = languageCode.replacingOccurrences(of: "_", with: "-")
        let language = Locale.Language(identifier: tag)
        guard let base = language.languageCode?.identifier, base != "und" else { return nil }
        let code: String
        switch base {
        case "zh": code = language.script?.identifier == "Hant" ? "zh_hant" : "zh"
        case "fil": code = "tl"
        default: code = base
        }
        if let known = Self.all.first(where: { $0.code == code }) { self = known; return }
        if code == "tl" { self.init(id: "lang:tl", name: "Filipino", flag: "🇵🇭", code: code); return }
        guard Locale.LanguageCode.isoLanguageCodes.contains(.init(code)),
              let native = Locale(identifier: tag).localizedString(forLanguageCode: code) else { return nil }
        let region = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier).region?.identifier ?? ""
        let letters = region.utf8
        let flag = letters.count == 2 && letters.allSatisfy { (65...90).contains($0) }
            ? letters.map { String(UnicodeScalar(0x1F1E6 + Int($0) - 65)!) }.joined() : ""
        self.init(id: "lang:\(code)", name: native.localizedCapitalized, flag: flag, code: code)
    }

    public static let hyTargets: [Self] = all +
        "fr pt es tr ru ar th it vi ms id tl hi pl nl km my fa gu ur te mr he bn ta uk bo kk mn ug yue".split(separator: " ")
            .compactMap { Self(languageCode: String($0)) }
}
