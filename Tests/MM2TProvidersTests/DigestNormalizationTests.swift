import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct DigestNormalizationTests {
    private var transcript: LLMTranscript {
        var transcript = LLMTranscript(utterances: [
            utterance("u1", "r1", 0, "下次會議上午10.5"),
            utterance("u2", "r2", 10, "好，同一時間我也會參加"),
            utterance("u3", "r3", 20, "我會準備簡報"),
        ])
        transcript.glossary = ["專案名"]
        return transcript
    }
    private let clean = #"{"paragraphs":[{"speaker":"r1","text":"下次會議上午10:30","sources":["u1"]},{"speaker":"r2","text":"確認參加同一場會議","sources":["u2"]},{"speaker":"r3","text":"簡報準備的清稿","sources":["u3"]}]}"#
    private let early = #"{"digests":[{"speaker":"r1","points":[{"text":"上午10:05開會","sources":["u1"]}]},{"speaker":"r2","points":[{"text":"上午10:05參加會議","sources":["u1","u2"]}]},{"speaker":"r3","points":[{"text":"準備簡報","sources":["u3"]}]}]}"#
    private let final = #"{"digests":[{"speaker":"r1","points":[{"text":"上午10:30開會","sources":["u1"]}]},{"speaker":"r2","points":[{"text":"上午10:30參加會議","sources":["u1","u2"]}]},{"speaker":"r3","points":[{"text":"準備簡報","sources":["u3"]}]}]}"#
    private let delta = #"{"changes":[{"speaker":"r1","remove":[],"replace":[{"index":0,"item":{"text":"上午10:30開會","sources":["u1"]}}],"append":[]},{"speaker":"r2","remove":[],"replace":[{"index":0,"item":{"text":"上午10:30參加會議","sources":["u1","u2"]}}],"append":[]}]}"#

    @Test(arguments: [false, true])
    func completedTimeReferencesReachFullAndIncrementalDigests(_ hasPreviousDigest: Bool) async throws {
        let clean = self.clean, early = self.early, final = self.final, delta = self.delta
        let server = StubServer { request in
            let result = request.geminiSystem.contains("怎麼整理：") ? clean
                : request.geminiSystem.contains("更新前次依人彙整") ? delta
                : request.geminiInput.contains("辨識正規化參考（") ? final : early
            return .status(200, Fixture.gemini(result))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        if hasPreviousDigest { _ = try await llm.digestPerPerson(transcript) }
        _ = try await llm.cleanTranscript(transcript)
        let result = try await llm.digestPerPerson(transcript)
        #expect(result[0].points[0].text == "上午10:30開會")
        #expect(result[1].points[0].text == "上午10:30參加會議")
        #expect(result[1].points[0].sources == [UtteranceID("u1"), UtteranceID("u2")])
        #expect(result[2].points[0].text == "準備簡報")
        let sent = try #require(server.requests.last)
        #expect(sent.geminiSystem.contains("更新前次依人彙整") == hasPreviousDigest)
        #expect(transcript.utterances.allSatisfy { sent.geminiInput.contains($0.text) })
        #expect(sent.geminiInput.contains("10.5") && sent.geminiInput.contains("10:30"))
        #expect(!sent.geminiInput.contains("簡報準備的清稿") && !sent.geminiInput.contains("確認參加同一場會議"))
        #expect(try await llm.digestPerPerson(transcript) == result)
        #expect(server.requests.count == (hasPreviousDigest ? 3 : 2))
    }

    @Test func anotherRecordingAndAnIncompatibleGlossaryCannotBorrowTimeReferences() async throws {
        let clean = self.clean, early = self.early, final = self.final
        let server = StubServer { request in
            .status(200, Fixture.gemini(request.geminiSystem.contains("怎麼整理：") ? clean
                : request.geminiInput.contains("辨識正規化參考（") ? final : early))
        }
        let base = GeminiLLM(apiKey: "test", session: server.session)
        let first = base.forRecording(), second = base.forRecording()
        _ = try await first.cleanTranscript(transcript)
        #expect(try await second.digestPerPerson(transcript)[0].points[0].text == "上午10:05開會")
        var changed = transcript
        changed.glossary = []
        #expect(try await first.digestPerPerson(changed)[0].points[0].text == "上午10:05開會")
        #expect(try await first.digestPerPerson(transcript)[0].points[0].text == "上午10:30開會")
    }
}
