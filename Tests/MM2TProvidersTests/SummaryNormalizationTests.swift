import Foundation
import Testing
@testable import MM2TCore
@testable import MM2TProviders

@Suite struct SummaryNormalizationTests {
    private let raw = [utterance("u1", "r1", 0, "下次會議十二月三日上午10.5，報告要在會議前完成")]
    private let clean = #"{"paragraphs":[{"speaker":"r1","text":"下次會議十二月三日上午10:30，報告要在會議前完成","sources":["u1"]}]}"#
    private let early = #"{"decisions":[],"discussionPoints":[],"actionItems":[{"text":"下次會議前完成報告","owner":"r1","sources":["u1"],"dueDate":"2026-12-03"}]}"#
    private let final = #"{"decisions":[],"discussionPoints":[],"actionItems":[{"text":"下次會議前完成報告","owner":"r1","sources":["u1"],"dueDate":"2026-12-03T10:30:00+08:00"}]}"#
    private let delta = #"{"headline":null,"title":null,"decisions":{"remove":[],"replace":[],"append":[]},"discussionPoints":{"remove":[],"replace":[],"append":[]},"actionItems":{"remove":[],"replace":[{"index":0,"item":{"text":"下次會議前完成報告","owner":"r1","sources":["u1"],"dueDate":"2026-12-03T10:30:00+08:00"}}],"append":[]}}"#

    private func request(_ utterances: [LLMUtterance], glossary: [String] = []) -> SummaryRequest {
        var transcript = LLMTranscript(utterances: utterances)
        transcript.glossary = glossary
        return SummaryRequest(transcript: transcript, prioritized: [],
                              meetingStartedAt: ISO8601DateFormatter().date(from: "2026-11-28T09:00:00+08:00")!,
                              timeZoneIdentifier: "Asia/Taipei")
    }

    @Test func newlyCompletedNormalizationUpdatesAnOtherwiseIdenticalSummaryRequest() async throws {
        let clean = self.clean, early = self.early, delta = self.delta
        let server = StubServer { request in
            let result = request.geminiSystem.contains("怎麼整理：") ? clean
                : request.geminiSystem.contains("只輸出異動") ? delta : early
            return .status(200, Fixture.gemini(result))
        }
        let llm = GeminiLLM(apiKey: "test", session: server.session).forRecording()
        let request = request(raw, glossary: ["專案名"])
        #expect(try await llm.summarize(request).actionItems.first?.due?.hasTime == false)
        _ = try await llm.cleanTranscript(request.transcript)
        let summary = try await llm.summarize(request)
        #expect(summary.actionItems.first?.due?.dateComponents.minute == 30)
        #expect(summary.actionItems.first?.sources == [UtteranceID("u1")])
        let sent = try #require(server.requests.last)
        #expect(sent.geminiSystem.contains("只輸出異動"))
        #expect(sent.geminiInput.contains("10.5") && sent.geminiInput.contains("10:30"))
        #expect(sent.geminiInput.contains("辨識正規化參考（") && sent.geminiInput.contains(#""sources":["u1"]"#))
        #expect(try await llm.summarize(request) == summary)
        #expect(server.requests.count == 3)
    }

    @Test func recordingReferencesDoNotLeakToAnotherRecordingOrTheBaseProvider() async throws {
        let clean = self.clean, early = self.early, final = self.final
        let server = StubServer { request in
            .status(200, Fixture.gemini(request.geminiSystem.contains("怎麼整理：") ? clean
                : request.geminiInput.contains("辨識正規化參考（") ? final : early))
        }
        let base = GeminiLLM(apiKey: "test", session: server.session)
        let first = base.forRecording(), second = base.forRecording()
        let request = request(raw)
        _ = try await first.cleanTranscript(request.transcript)
        #expect(try await second.summarize(request).actionItems.first?.due?.hasTime == false)
        #expect(try await base.summarize(request).actionItems.first?.due?.hasTime == false)
        #expect(try await first.summarize(request).actionItems.first?.due?.hasTime == true)
    }

    @Test(arguments: ["text", "speaker", "id", "time", "highlight", "glossary", "language"])
    func changedRawInputsOrGlossaryRejectTheNormalizationReference(_ field: String) async throws {
        let store = CleanedCheckpointStore()
        let original = request(raw, glossary: ["原詞彙"]).transcript
        let cleaned = CleanedTranscript(paragraphs: [.init(speaker: SpeakerID("r1"), text: "上午10:30", sources: [UtteranceID("u1")])])
        let revision = await store.begin()
        await store.accept(cleaned, for: original, revision: revision)
        #expect(await store.reference(for: original) != nil)
        let first = utterance(field == "id" ? "other" : "u1", field == "speaker" ? "r2" : "r1",
                              field == "time" ? 1 : 0, field == "text" ? "新的內容" : raw[0].text,
                              highlighted: field == "highlight")
        let tail = utterance("u2", "r1", 10, field == "language" ? String(repeating: "English discussion ", count: 1_000) : "繼續討論")
        let changed = request([first, tail], glossary: field == "glossary" ? [] : ["原詞彙"]).transcript
        #expect(await store.reference(for: changed) == nil)
    }

    @Test(arguments: ["emptySources", "unknownSource", "duplicateSource", "unknownSpeaker", "emptyText"])
    func unusableCleanupCannotBecomeANormalizationReference(_ fault: String) async {
        let store = CleanedCheckpointStore()
        let sources = fault == "emptySources" ? [] : fault == "unknownSource" ? ["unknown"]
            : fault == "duplicateSource" ? ["u1", "u1"] : ["u1"]
        let cleaned = CleanedTranscript(paragraphs: [.init(speaker: SpeakerID(fault == "unknownSpeaker" ? "unknown" : "r1"),
            text: fault == "emptyText" ? " \n" : "上午10:30", sources: sources.map(UtteranceID.init))])
        await store.accept(cleaned, for: request(raw).transcript, revision: await store.begin())
        #expect(await store.reference(for: request(raw).transcript) == nil)
    }

    @Test func anOlderCleanupCannotOverwriteTheLatestCompletedReference() async throws {
        let store = CleanedCheckpointStore()
        let older = await store.begin(), newer = await store.begin()
        let original = request(raw).transcript
        let extended = request(raw + [utterance("u2", "r1", 10, "補充內容")]).transcript
        let old = CleanedTranscript(paragraphs: [.init(speaker: SpeakerID("r1"), text: "舊時間10:05", sources: [UtteranceID("u1")])])
        let new = CleanedTranscript(paragraphs: [.init(speaker: SpeakerID("r1"), text: "新時間10:30", sources: [UtteranceID("u1"), UtteranceID("u2")])])
        await store.accept(new, for: extended, revision: newer)
        await store.accept(old, for: original, revision: older)
        #expect(await store.reference(for: extended)?.cleaned == new)
    }

    @Test func referencesContainOnlyExplicitClockTimesAndKeepTheirOriginalSources() async throws {
        let texts = ["上午10:30開會", "確認交付物的清稿", "版本10.5", "比例3:2", "無效24:00", "無效12:99", "晚上23：59結束"]
        let utterances = texts.indices.map { utterance("u\($0)", "r1", Double($0), "原始發言\($0)") }
        let transcript = request(utterances).transcript
        let cleaned = CleanedTranscript(paragraphs: texts.enumerated().map { index, text in
            .init(speaker: SpeakerID("r1"), text: text, sources: [UtteranceID("u\(index)")])
        })
        let store = CleanedCheckpointStore()
        await store.accept(cleaned, for: transcript, revision: await store.begin())
        let reference = try #require(await store.reference(for: transcript))
        #expect(reference.cleaned.paragraphs == [cleaned.paragraphs[0], cleaned.paragraphs[6]])
        let input = LLMPrompts.summaryRequest(request(utterances), normalization: reference)
        #expect(utterances.allSatisfy { input.contains($0.text) })
        #expect(input.contains("10:30") && input.contains("23：59"))
        #expect(!input.contains("確認交付物的清稿") && !input.contains("版本10.5") && !input.contains("無效24:00"))
        let noTimes = CleanedTranscript(paragraphs: Array(cleaned.paragraphs[1...5]))
        await store.accept(noTimes, for: transcript, revision: await store.begin())
        #expect(await store.reference(for: transcript) == nil)
    }

    @Test func summaryUsesTheCompletedPrefixWithoutWaitingForFinalCleanup() async throws {
        let store = CleanedCheckpointStore()
        let prefix = request(raw).transcript
        let cleaned = CleanedTranscript(paragraphs: [.init(speaker: SpeakerID("r1"), text: "上午10:30", sources: [UtteranceID("u1")])])
        await store.accept(cleaned, for: prefix, revision: await store.begin())
        let generator = GatedCleanup(summary: final)
        let tasks = LLMTasks(generator, cleanChunkCharacters: 300, maxInputCharacters: 40_000, cleanConcurrency: 4,
                             responseCache: nil, summaryUpdates: SummaryCheckpointStore(), cleanedCheckpoints: store)
        let current = request(raw + [utterance("u2", "r1", 10, "會議結束")])
        let cleanup = Task { try await tasks.cleanTranscript(current.transcript) }
        let cleanupStarted = await waitUntil { await generator.cleanupStarted }
        let summary = Task { try await tasks.summarize(current) }
        let summaryStartedBeforeRelease = await waitUntil { await generator.summaryInput != nil }
        await generator.release()
        _ = try await cleanup.value
        let result = try await summary.value
        #expect(cleanupStarted && summaryStartedBeforeRelease)
        #expect(result.actionItems.first?.due?.dateComponents.minute == 30)
        let input = try #require(await generator.summaryInput)
        #expect(input.contains("10.5") && input.contains("10:30") && input.contains("會議結束"))
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private actor GatedCleanup: StructuredGenerator {
        nonisolated let service = Service.gemini
        let summary: String
        var cleanupStarted = false
        var summaryInput: String?
        private var pending: CheckedContinuation<String, Never>?
        init(summary: String) { self.summary = summary }
        func generate(system: String, input: String, schema: JSON) async throws -> String {
            if system.contains("怎麼整理：") {
                cleanupStarted = true
                return await withCheckedContinuation { pending = $0 }
            }
            summaryInput = input
            return summary
        }
        func release() { pending?.resume(returning: #"{"paragraphs":[]}"#); pending = nil }
    }
}
