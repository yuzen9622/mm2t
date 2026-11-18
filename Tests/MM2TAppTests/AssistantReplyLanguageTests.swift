import Foundation
import NaturalLanguage
import Testing
@testable import MM2TApp
import MM2TCore
import MM2TProviders

@MainActor @Suite struct AssistantReplyLanguageTests {
    // An explicitly supplied test key runs the synthetic conversation against Gemini.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_TEST_GEMINI_KEY"] != nil))
    func cloudModelRespectsReplyAndDocumentLanguageScopes() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["MM2T_TEST_GEMINI_KEY"])
        let provider = GeminiLLM(apiKey: Secret(key))
        let world = try World()
        let meeting = try await world.recordedMeeting()
        try await world.app.searchIndex.rebuild(from: [meeting])
        let engine = AssistantEngine(library: world.library, index: world.app.searchIndex, voiceprints: world.app.voiceprints)
        var ledger = AssistantLedger()
        let turns: [(String, NLLanguage, String?)] = [
            ("接下來這段對話都用英文。請簡單自我介紹。", .english, "en"),
            ("只限這次，請用日文向團隊道早安。", .japanese, "en"),
            ("幫我寫一封簡短的法文會議邀請信，只給信件內容。", .french, "en"),
            ("再簡單介紹一下你自己。", .english, "en"),
            ("What did the speakers discuss about 「預算」? Answer in Japanese and cite the transcript.", .japanese, "en"),
        ]
        for (question, language, tag) in turns {
            var answer = ""
            for await event in engine.events(question: question, provider: provider, preferences: "請用繁體中文回答", ledger: ledger) {
                switch event {
                case .ledger(let next): ledger = next
                case .answerDelta(let delta): answer += delta
                case .finished(let sources) where question.contains("預算"):
                    #expect(sources.contains { $0.meeting == meeting.id })
                case .failed(let reason): Issue.record(Comment(rawValue: reason))
                default: break
                }
            }
            #expect(NLLanguageRecognizer.dominantLanguage(for: answer) == language, "\(question) → \(answer)")
            #expect(ledger.chatLanguage?.split(separator: "-").first.map(String.init) == tag)
        }
    }
}
