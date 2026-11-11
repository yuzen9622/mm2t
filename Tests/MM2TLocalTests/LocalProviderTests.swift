import Foundation
@testable import MM2TCore
import Testing
import WhisperKit
@testable import MM2TLocal
@testable import MM2TProviders

@Suite struct LocalTranscriptionTests {
    @Test func wordTimingsBecomeTimedWordsInTimeOrder() {
        let segments = [
            TranscriptionSegment(start: 3, end: 5, text: " 我們用 Kubernetes", words: [
                WordTiming(word: "我們", tokens: [1], start: 3.0, end: 3.4, probability: 0.9),
                WordTiming(word: "用", tokens: [2], start: 3.4, end: 3.6, probability: 0.9),
                WordTiming(word: " Kubernetes", tokens: [3], start: 3.6, end: 4.5, probability: 0.9),
            ]),
            TranscriptionSegment(start: 0, end: 2, text: "<|zh|><|transcribe|> 大家好<|endoftext|>", words: [
                WordTiming(word: "<|zh|>", tokens: [9], start: 0, end: 0, probability: 1),
                WordTiming(word: "大家", tokens: [4], start: 0.2, end: 0.8, probability: 0.9),
                WordTiming(word: "好", tokens: [5], start: 0.8, end: 1.1, probability: 0.9),
            ]),
        ]
        #expect(WhisperEngine.words(segments) == [
            TimedWord("大家", 0.2, 0.8), TimedWord("好", 0.8, 1.1),
            TimedWord("我們", 3.0, 3.4), TimedWord("用", 3.4, 3.6), TimedWord("Kubernetes", 3.6, 4.5),
        ])
    }

    @Test func aSegmentWithoutWordTimingsKeepsItsOwnSpan() {
        let segments = [TranscriptionSegment(start: 1, end: 4, text: "<|zh|> 先看預算 <|endoftext|>", words: nil)]
        #expect(WhisperEngine.words(segments) == [TimedWord("先看預算", 1, 4)])
    }

    @Test func aMissingModelStopsTheChainWithAnActionableMessage() async throws {
        let model = LocalTranscriptionModel.breeze(in: try scratchDirectory())
        let error = await #expect(throws: TranscriptionError.self) {
            try await LocalTranscription(model: model).transcribe(audio: URL(filePath: "/nonexistent.wav"), hints: [], labelSpeakers: true)
        }
        #expect(error == .failed(ProviderError(.localTranscription, .modelUnavailable).description), "the last source never falls through")
    }
}

@Suite struct LocalLLMTests {
    @Test func aMissingModelFailsWithAnActionableMessage() async throws {
        let model = LocalLLMModel.qwen35(in: try scratchDirectory())
        let transcript = LLMTranscript(utterances: [
            LLMUtterance(id: UtteranceID("u1"), speaker: .me, range: TimeRange(start: 0, end: 1), text: "大家好", isHighlighted: false),
        ])
        let error = await #expect(throws: ProviderError.self) { try await LocalLLM(model: model).digestPerPerson(transcript) }
        #expect(error == ProviderError(.localLLM, .modelUnavailable))
    }

    @Test func speakerFieldsOnlyAcceptThisMeetingsIDs() throws {
        let speakers = [SpeakerID.me, SpeakerID("r1")]
        for schema in [LLMPrompts.nameSchema(speakers), LLMPrompts.cleanSchema(speakers), LLMPrompts.digestSchema(speakers)] {
            #expect(try Grammar.gbnf(for: schema).contains(#"("\"me\"" | "\"r1\"")"#))
        }
        #expect(try Grammar.gbnf(for: LLMPrompts.summarySchema(speakers)).contains("(string | null)"), "an owner may be absent")
        #expect(throws: Grammar.Unsupported.self) { try Grammar.gbnf(for: .dict([("type", .text("number"))])) }
    }
}
