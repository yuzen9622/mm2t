import Testing
@testable import MM2TCore

@Suite struct TraditionalChineseTests {
    @Test func wordsKeepTheirBoundariesAndTimesWhileContextPicksTheCharacter() {
        let words = TranscribedWords.labeled([
            LabeledWord(TimedWord("皇", 0, 0.2), speaker: ClusterID("speaker_0")),
            LabeledWord(TimedWord("后", 0.2, 0.4), speaker: ClusterID("speaker_0")),
            LabeledWord(TimedWord("在", 0.4, 0.6), speaker: ClusterID("speaker_0")),
            LabeledWord(TimedWord("后面", 0.6, 1.0), speaker: ClusterID("speaker_1")),
            LabeledWord(TimedWord("测试", 1.0, 1.4), speaker: ClusterID("speaker_1")),
            LabeledWord(TimedWord("API", 1.4, 1.8), speaker: ClusterID("speaker_1")),
        ])
        let converted = words.inTraditionalChinese
        #expect(converted.words.map(\.text) == ["皇", "后", "在", "後面", "測試", "API"])
        #expect(converted.words.map(\.range) == words.words.map(\.range))
        #expect(converted.labeledWords?.map(\.speaker) == words.labeledWords?.map(\.speaker))
    }

    @Test func traditionalTextIsLeftAlone() {
        #expect(TraditionalChinese.convert(["我們", "今天", "開會"]) == ["我們", "今天", "開會"])
    }

    @Test func simplifiedIsTheInverseForTheOneTargetThatAsksForIt() {
        #expect(TraditionalChinese.simplified("後面再說，這個會議記錄請寄給我們。") == "后面再说，这个会议记录请寄给我们。")
        #expect(TraditionalChinese.simplified("Q3 預算 review") == "Q3 预算 review")
        #expect(TraditionalChinese.convert(TraditionalChinese.simplified("語音辨識")) == "語音辨識")
    }
}
