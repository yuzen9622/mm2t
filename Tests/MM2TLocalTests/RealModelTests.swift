import AVFoundation
import Darwin
import Foundation
import llama
@testable import MM2TCore
import Testing
@testable import MM2TLocal
@testable import MM2TProviders

/// Runs against real weights from `MM2T_LOCAL_MODELS` and prints what came out, timing and peak
/// memory. `MM2T_LOCAL_DOWNLOAD=1` first installs both models from the Hub into that folder.
@Suite(.serialized) struct RealModelTests {
    static let environment = ProcessInfo.processInfo.environment
    static var transcription: LocalTranscriptionModel? { RealModels.root.map { LocalTranscriptionModel.breeze(in: $0) } }
    /// `MM2T_LOCAL_LLM_GGUF` swaps in another GGUF with the same prompt format, to compare models.
    static var llm: LocalLLMModel? {
        guard let root = RealModels.root else { return nil }
        let shipped = LocalLLMModel.qwen35(in: root)
        guard let other = environment["MM2T_LOCAL_LLM_GGUF"].map({ URL(filePath: $0) }) else { return shipped }
        return LocalLLMModel(
            snapshot: ModelSnapshot(directory: other.deletingLastPathComponent(), sources: [], approximateBytes: 0),
            file: other.lastPathComponent, contextTokens: shipped.contextTokens, format: shipped.format)
    }

    @Test(.enabled(if: RealModels.root != nil && environment["MM2T_LOCAL_DOWNLOAD"] == "1"))
    func installsBothModelsFromTheHub() async throws {
        for snapshot in [Self.transcription!.snapshot, Self.llm!.snapshot] {
            let started = Date()
            try await snapshot.download { _ in }
            #expect(snapshot.isDownloaded)
            print("installed \(snapshot.directory.lastPathComponent): \(directoryBytes(snapshot.directory) / 1_000_000) MB in \(Int(Date().timeIntervalSince(started))) s")
        }
    }

    @Test(.enabled(if: transcription?.snapshot.isDownloaded == true && environment["MM2T_LOCAL_STT_CLIP"] != nil))
    func transcribesAMandarinClip() async throws {
        let clip = URL(filePath: Self.environment["MM2T_LOCAL_STT_CLIP"]!)
        let duration = try audioDuration(clip)
        let provider = LocalTranscription(model: Self.transcription!)
        let hints = Self.environment["MM2T_LOCAL_STT_HINTS"].map { $0.components(separatedBy: ",") } ?? []

        let started = Date()
        let words = try await provider.transcribe(audio: clip, hints: hints, labelSpeakers: true).words
        let first = Date().timeIntervalSince(started)
        let again = Date()
        _ = try await provider.transcribe(audio: clip, hints: hints, labelSpeakers: true)
        let warm = Date().timeIntervalSince(again)

        print("clip \(clip.lastPathComponent) \(String(format: "%.1f", duration)) s; first call \(String(format: "%.1f", first)) s (includes model load), warm \(String(format: "%.1f", warm)) s, RTF \(String(format: "%.3f", warm / duration)); peak footprint \(peakFootprintMB()) MB")
        print(words.map { String(format: "[%.2f-%.2f]", $0.range.start, $0.range.end) + $0.text }.joined(separator: " "))
        #expect(words.contains { $0.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }, "Chinese text came back")
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.range.start <= $1.range.start }, "words are in time order")
        #expect(words.allSatisfy { $0.range.start >= 0 && $0.range.end <= duration + 1 })
    }

    @Test(.enabled(if: llm.map { FileManager.default.fileExists(atPath: $0.path.path) } == true))
    func llamaAcceptsEveryTaskGrammar() throws {
        let speakers = [SpeakerID.me, SpeakerID("r1")]
        var params = llama_model_default_params()
        params.vocab_only = true
        let model = try #require(llama_model_load_from_file(Self.llm!.path.path, params))
        defer { llama_model_free(model) }
        for schema in [LLMPrompts.nameSchema(speakers), LLMPrompts.cleanSchema(speakers),
                       LLMPrompts.digestSchema(speakers), LLMPrompts.summarySchema(speakers)] {
            let sampler = llama_sampler_init_grammar(llama_model_get_vocab(model), try Grammar.gbnf(for: schema), "root")
            #expect(sampler != nil, "llama.cpp parsed the grammar")
            llama_sampler_free(sampler)
        }
    }

    @Test(.enabled(if: llm.map { FileManager.default.fileExists(atPath: $0.path.path) } == true))
    func producesAllFourOutputsForAShortMandarinMeeting() async throws {
        let lines: [(String, String)] = [
            ("r1", "好那我們開始，今天主要是看下一季的 Kubernetes migration 進度。"),
            ("r2", "小明，你那邊 cluster 升級的狀況怎麼樣？"),
            ("r1", "嗯，那個，staging 已經升到 1.31 了，production 預計禮拜三，不對，禮拜四晚上做。"),
            ("me", "那 rollback plan 有寫好嗎？上次出事就是因為沒有 rollback。"),
            ("r1", "有，我禮拜二之前會把 rollback plan 放到 Confluence。"),
            ("r2", "好，那預算的部分，雲端費用這一季大概會多百分之十五，我會跟財務確認。"),
            ("me", "OK，那就這樣決定，禮拜四升級 production，小明負責 rollback plan，阿華跟財務確認預算。"),
        ]
        let utterances = lines.enumerated().map { index, line in
            LLMUtterance(id: UtteranceID("u\(index + 1)"), speaker: SpeakerID(line.0),
                         range: TimeRange(start: Double(index * 8), end: Double(index * 8 + 7)), text: line.1,
                         isHighlighted: index == 6)
        }
        let transcript = LLMTranscript(utterances: utterances)
        let llm = LocalLLM(model: Self.llm!)

        var started = Date()
        let names = try await llm.inferNames(NameInferenceRequest(transcript: transcript, unnamedSpeakers: [SpeakerID("r1"), SpeakerID("r2")], knownNames: [:]))
        print("inferNames \(seconds(since: started)) s (includes model load):", names.map { "\($0.speaker.rawValue)=\($0.name) (\($0.reason))" })
        started = Date()
        let cleaned = try await llm.cleanTranscript(transcript)
        print("cleanTranscript \(seconds(since: started)) s:")
        cleaned.paragraphs.forEach { print("  \($0.speaker.rawValue) \($0.sources.map(\.rawValue)): \($0.text)") }
        started = Date()
        let digests = try await llm.digestPerPerson(transcript)
        print("digestPerPerson \(seconds(since: started)) s:")
        digests.forEach { digest in digest.points.forEach { print("  \(digest.speaker.rawValue): \($0.text) \($0.sources.map(\.rawValue))") } }
        started = Date()
        let summary = try await llm.summarize(SummaryRequest(transcript: transcript, prioritized: [utterances[6]]))
        print("summarize \(seconds(since: started)) s:")
        print("  headline: \(summary.headline ?? "-")")
        summary.decisions.forEach { print("  decision: \($0.text) \($0.sources.map(\.rawValue))") }
        summary.discussionPoints.forEach { print("  point: \($0.text) \($0.sources.map(\.rawValue))") }
        summary.actionItems.forEach { print("  action: \($0.text) owner=\($0.owner?.rawValue ?? "-") \($0.sources.map(\.rawValue))") }
        print("peak footprint \(peakFootprintMB()) MB")

        #expect(names.contains { $0.speaker == SpeakerID("r1") && $0.name.contains("小明") })
        #expect(!cleaned.paragraphs.isEmpty)
        #expect(Set(cleaned.paragraphs.flatMap(\.sources)).count >= utterances.count - 1, "the cleaned text covers the meeting")
        #expect(Set(digests.map(\.speaker)) == [SpeakerID("r1"), SpeakerID("r2"), .me])
        #expect(summary.headline?.isEmpty == false && !summary.actionItems.isEmpty)
        let everything = cleaned.paragraphs.map(\.text) + digests.flatMap { $0.points.map(\.text) } + summary.actionItems.map(\.text)
        #expect(!everything.joined().contains("{{speaker:r9}}"))
    }
}

private func seconds(since date: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(date)) }

private func audioDuration(_ url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

private func directoryBytes(_ url: URL) -> Int64 {
    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    var total: Int64 = 0
    while let file = enumerator?.nextObject() as? URL {
        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

/// The process's peak physical footprint, the number Activity Monitor's memory column tracks.
func peakFootprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak / 1_048_576) : -1
}
