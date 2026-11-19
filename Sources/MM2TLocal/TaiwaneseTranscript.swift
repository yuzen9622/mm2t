import Foundation
import MM2TCore

enum TaiwaneseTranscript {
    // OpenCC 1.1.9, TWVariants.txt. See THIRD_PARTY_NOTICES.md.
    private static let variants: [Character: Character] = [
        "僞": "偽", "啓": "啟", "喫": "吃", "嫺": "嫻", "嬀": "媯", "峯": "峰",
        "幺": "么", "擡": "抬", "棱": "稜", "檐": "簷", "污": "汙", "泄": "洩",
        "潙": "溈", "潨": "潀", "爲": "為", "牀": "床", "痹": "痺", "癡": "痴",
        "皁": "皂", "着": "著", "睾": "睪", "祕": "秘", "竈": "灶", "糉": "粽",
        "繮": "韁", "纔": "才", "羣": "群", "脣": "唇", "蔘": "參", "蔿": "蒍",
        "衆": "眾", "裏": "裡", "覈": "核", "踊": "踴", "鉢": "缽", "鍼": "針",
        "鮎": "鯰", "麪": "麵", "齶": "顎",
    ]

    static func convert(_ text: String, language: String?) -> String {
        // Other Nemotron languages may use Han characters too, especially Japanese.
        if let language, language != "auto", !language.lowercased().hasPrefix("zh") { return text }
        return text.replacing(/\p{script=Han}+/) { run in
            String(TraditionalChinese.convert(String(run.output)).map { variants[$0] ?? $0 })
        }
    }

    static func convert(_ words: [TimedWord], language: String?) -> [TimedWord] {
        let text = TraditionalChinese.convert(words.map(\.text)) { convert($0, language: language) }
        return zip(words, text).map { TimedWord(text: $1, range: $0.range) }
    }
}
