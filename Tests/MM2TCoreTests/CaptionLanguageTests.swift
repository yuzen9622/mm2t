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
