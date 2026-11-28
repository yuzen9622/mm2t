import MM2TCore
@testable import MM2TLocal
import Testing

@Suite struct TaiwaneseTranscriptTests {
    @Test func preservesEnglishAndContextAcrossWordBoundaries() {
        let words = [TimedWord("皇", 0, 1), TimedWord("后在后面，启", 1, 2), TimedWord("动", 2, 3),
                     TimedWord("Q&A / eBay API-v2.0!", 3, 5)]
        let output = TaiwaneseTranscript.convert(words, language: "zh-CN")
        #expect(output.map(\.text) == ["皇", "后在後面，啟", "動", "Q&A / eBay API-v2.0!"])
        #expect(output.map(\.range) == words.map(\.range))
        #expect(TaiwaneseTranscript.convert("裏面著手", language: nil) == "裡面著手")
        #expect(TaiwaneseTranscript.convert("中国のAPI", language: "ja-JP") == "中国のAPI")
    }
}
