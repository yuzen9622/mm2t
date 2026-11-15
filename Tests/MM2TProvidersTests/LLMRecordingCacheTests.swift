import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct LLMRecordingCacheTests {
    private func transcript(_ count: Int) -> LLMTranscript {
        LLMTranscript(utterances: (1...count).map {
            utterance("u\($0)", "r1", Double($0) * 3, String(repeating: "字", count: 100))
        })
    }

    @Test func recordingConfigurationPreservesModelAndSharesItsCache() async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"paragraphs":[]}"#))
        let provider = GeminiLLM(apiKey: "test", model: "chosen-model", session: server.session)
        let recording = provider.forRecording()
        #expect(provider.limits.cleanChunkCharacters == 2_000)
        #expect(recording.limits.cleanChunkCharacters == 300)
        #expect(recording.model == "chosen-model")
        _ = try await provider.cleanTranscript(transcript(1))
        _ = try await recording.cleanTranscript(transcript(1))
        #expect(server.requests.count == 1)
    }

    @Test func growingRecordingOnlyCleansTheChangedTailAndKeepsOrderedSources() async throws {
        let server = StubServer(GeminiLLMTests.echo)
        let provider = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        _ = try await provider.cleanTranscript(transcript(12))
        #expect(server.requests.count == 4)
        let final = try await provider.cleanTranscript(transcript(13))
        #expect(server.requests.count == 5)
        #expect(final.paragraphs.flatMap(\.sources) == (1...13).map { UtteranceID("u\($0)") })
        #expect(try await provider.cleanTranscript(transcript(13)) == final)
        #expect(server.requests.count == 5)
    }

    @Test(arguments: ["text", "id", "speaker", "time", "highlight", "glossary"])
    func changedInputsInvalidateTheChunkAndItsFollowingContext(_ field: String) async throws {
        let server = StubServer(status: 200, body: Fixture.gemini(#"{"paragraphs":[]}"#))
        let provider = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        let original = transcript(7)
        _ = try await provider.cleanTranscript(original)
        var utterances = original.utterances
        let first = utterances[0]
        utterances[0] = utterance(
            field == "id" ? "replacement" : first.id.rawValue,
            field == "speaker" ? "r2" : first.speaker.rawValue,
            field == "time" ? 0 : first.range.start,
            field == "text" ? String(repeating: "改", count: 100) : first.text,
            highlighted: field == "highlight")
        var changed = LLMTranscript(utterances: utterances)
        if field == "glossary" { changed.glossary = ["Kubernetes"] }
        _ = try await provider.cleanTranscript(changed)
        #expect(server.requests.count == 6)
    }

    @Test(arguments: [150, 200])
    func shortChunksKeepSixPrecedingUtterancesWithoutEmittingContextSources(_ characters: Int) async throws {
        let utterances = (1...10).map {
            utterance("u\($0)", "r1", Double($0) * 3, String(repeating: "字", count: characters))
        }
        let server = StubServer { request in
            let allIDs = request.geminiInput.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return String(line[line.index(after: line.startIndex)..<close])
            }
            // Deliberately include context citations; the result must keep only this chunk's sources.
            let paragraphs = [["speaker": "r1", "text": "清理結果", "sources": allIDs] as [String: Any]]
            let output = String(decoding: try! JSONSerialization.data(withJSONObject: ["paragraphs": paragraphs]), as: UTF8.self)
            return .status(200, Fixture.gemini(output))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        let result = try await llm.cleanTranscript(LLMTranscript(utterances: utterances))
        let utterancesPerChunk = characters == 150 ? 2 : 1
        #expect(server.requests.count == 10 / utterancesPerChunk)
        #expect(result.paragraphs.flatMap(\.sources) == utterances.map(\.id))
        #expect(result.paragraphs.allSatisfy { $0.sources.count == utterancesPerChunk })
        for request in server.requests {
            let firstID = try #require(request.utteranceIDs.first)
            let offset = try #require(utterances.firstIndex { $0.id.rawValue == firstID })
            let context = request.geminiInput.components(separatedBy: "逐字稿：\n")[0]
            let contextIDs = context.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return String(line[line.index(after: line.startIndex)..<close])
            }
            #expect(contextIDs == utterances.prefix(offset).suffix(6).map { $0.id.rawValue })
        }
    }

    @Test func malformedResponsesAreNotCached() async throws {
        let sequence = ResponseSequence([
            Fixture.gemini(#"{"paragraphs":"wrong type"}"#),
            Fixture.gemini(#"{"paragraphs":[{"speaker":"unknown","text":"x","sources":["u1"]}]}"#),
            Fixture.gemini(#"{"paragraphs":[]}"#),
        ])
        let server = StubServer { _ in .status(200, sequence.next()) }
        let provider = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        for _ in 0..<2 {
            await #expect(throws: ProviderError(.gemini, .malformedResponse)) {
                try await provider.cleanTranscript(transcript(1))
            }
        }
        _ = try await provider.cleanTranscript(transcript(1))
        _ = try await provider.cleanTranscript(transcript(1))
        #expect(server.requests.count == 3)
    }

    @Test func finalSummaryRetainsFullSourcesAndReplacesCancelledOrRescheduledActions() async throws {
        let early = #"{"decisions":[],"discussionPoints":[],"actionItems":[{"text":"明天下午三點寄報告","owner":"r1","sources":["u1"],"dueDate":"2026-11-15T15:00:00+08:00"},{"text":"明天通知客戶","owner":"r2","sources":["u2"],"dueDate":"2026-11-15"}]}"#
        let final = #"{"decisions":[],"discussionPoints":[],"actionItems":[{"text":"改由另一位負責後天下午四點寄報告","owner":"r2","sources":["u1","u3"],"dueDate":"2026-11-16T16:00:00+08:00"}]}"#
        let changes = #"{"headline":null,"title":null,"decisions":{"remove":[],"replace":[],"append":[]},"discussionPoints":{"remove":[],"replace":[],"append":[]},"actionItems":{"remove":[1],"replace":[{"index":0,"item":{"text":"改由另一位負責後天下午四點寄報告","owner":"r2","sources":["u1","u3"],"dueDate":"2026-11-16T16:00:00+08:00"}}],"append":[]}}"#
        let server = StubServer { request in
            let output = request.geminiSystem.contains("只輸出異動") ? changes : request.geminiInput.contains("[u3]") ? final : early
            return .status(200, Fixture.gemini(output))
        }
        let provider = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        let initial = [utterance("u1", "r1", 0, "我明天下午三點寄報告"), utterance("u2", "r2", 10, "明天通知客戶")]
        let tail = [utterance("u3", "r2", 20, "報告改成我後天下午四點寄，通知客戶取消")]
        let started = try #require(ISO8601DateFormatter().date(from: "2026-11-14T10:00:00+08:00"))
        func request(_ utterances: [LLMUtterance]) -> SummaryRequest {
            SummaryRequest(transcript: LLMTranscript(utterances: utterances), prioritized: [],
                           meetingStartedAt: started, timeZoneIdentifier: "Asia/Taipei")
        }
        #expect(try await provider.summarize(request(initial)).actionItems.count == 2)
        let summary = try await provider.summarize(request(initial + tail))
        #expect(summary.actionItems.count == 1)
        #expect(summary.actionItems[0].owner == SpeakerID("r2"))
        #expect(summary.actionItems[0].due?.dateComponents.day == 16)
        #expect(summary.actionItems[0].due?.dateComponents.hour == 16)
        #expect(summary.actionItems[0].sources == [UtteranceID("u1"), UtteranceID("u3")])
        #expect(try await provider.summarize(request(initial + tail)) == summary)
        #expect(server.requests.count == 2)
        let last = try #require(server.requests.last)
        #expect(initial.allSatisfy { last.geminiInput.contains($0.text) })
        #expect(last.geminiSystem.contains("後面已取消的事項不要列成待辦"))
    }

    @Test func openAIRecordingConfigurationUsesTheSameCacheAndDefaultQualityIsUnchanged() async throws {
        let server = StubServer(status: 200, body: Fixture.chatCompletion(#"{"paragraphs":[]}"#))
        let provider = OpenAICompatibleLLM(baseURL: URL(string: "http://local.test/v1")!, apiKey: nil,
                                           model: "chosen-model", session: server.session)
        let recording = provider.forRecording()
        #expect(provider.limits.cleanChunkCharacters == 2_000)
        #expect(recording.limits.cleanChunkCharacters == 300)
        #expect(recording.model == "chosen-model")
        _ = try await provider.cleanTranscript(transcript(1))
        _ = try await recording.cleanTranscript(transcript(1))
        #expect(server.requests.count == 1)
    }
}

private final class ResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String { lock.withLock { responses.count > 1 ? responses.removeFirst() : responses[0] } }
}
