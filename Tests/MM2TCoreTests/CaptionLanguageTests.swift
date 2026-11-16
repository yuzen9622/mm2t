import Testing
@testable import MM2TCore

@Suite struct CaptionLanguageTests {
    @Test func chineseTextIsChinese() {
        #expect(CaptionLanguage.of("大家好，今天討論預算。") == .traditionalChinese)
        #expect(CaptionLanguage.of("简体也是中文") == .traditionalChinese)
    }

    @Test func englishTextIsEnglish() {
        #expect(CaptionLanguage.of("Let's review the Q3 budget.") == .english)
    }

    @Test func mixedTextFollowsTheShareOfHanAmongLetters() {
        // 5 Han among 15 letters, 33%: Chinese.
        #expect(CaptionLanguage.of("我們用 Kubernetes 部署") == .traditionalChinese)
        // 2 Han among 32 letters, 6%: English.
        #expect(CaptionLanguage.of("The deployment uses 容器 orchestration") == .english)
        // 3 Han among 10 letters is exactly 30%, which is not more than 30%.
        #expect(CaptionLanguage.of("中文中 abcdefg") == .english)
    }

    @Test func digitsAndPunctuationAloneHaveNoLanguage() {
        #expect(CaptionLanguage.of("2026, 3.14 — 42%!") == nil)
        #expect(CaptionLanguage.of("，。？") == nil)
        #expect(CaptionLanguage.of("") == nil)
    }
}

@Suite struct PartialTranslationPolicyTests {
    typealias Policy = PartialTranslationPolicy

    @Test func sendsUpToTheLastClauseBoundaryInEitherScript() {
        #expect(Policy.stablePart(of: "We agreed, and then we", lastSent: nil) == "We agreed,")
        #expect(Policy.stablePart(of: "Is it done? I think", lastSent: nil) == "Is it done?")
        #expect(Policy.stablePart(of: "我們先看預算，然後", lastSent: nil) == "我們先看預算，")
        #expect(Policy.stablePart(of: "第一、第二", lastSent: nil) == "第一、")
        #expect(Policy.stablePart(of: "好。接下來", lastSent: nil) == "好。")
    }

    @Test func sendsAgainOnlyWhenTheSettledPartGrew() {
        #expect(Policy.stablePart(of: "We agreed, and then we", lastSent: "We agreed,") == nil)
        #expect(Policy.stablePart(of: "We agreed, and then we left. So", lastSent: "We agreed,") == "We agreed, and then we left.")
        #expect(Policy.stablePart(of: "我們先看預算，然後討論", lastSent: "我們先看預算，") == nil)
    }

    @Test func withoutABoundaryWaitsForEightWordsOrSixteenHan() {
        #expect(Policy.stablePart(of: "so what we really need to", lastSent: nil) == nil, "six words")
        #expect(Policy.stablePart(of: "so what we really need to do is ship", lastSent: nil) == "so what we really need to do is",
                "nine words: up to the last whole word")
        #expect(Policy.stablePart(of: "so what we really need to do is ", lastSent: nil) == "so what we really need to do is")
        #expect(Policy.stablePart(of: "我們這一季最重要的目標其實是", lastSent: nil) == nil, "fourteen Han")
        #expect(Policy.stablePart(of: "我們這一季最重要的目標其實是把延遲", lastSent: nil) == "我們這一季最重要的目標其實是把延遲")
        #expect(Policy.stablePart(of: "so what we really need to do is ship the", lastSent: "so what we really need to do is") == nil,
                "growth counts from the last send")
    }

    @Test func nothingToSendForEmptyText() {
        #expect(Policy.stablePart(of: "", lastSent: nil) == nil)
        #expect(Policy.stablePart(of: "Hello", lastSent: nil) == nil)
    }
}
