import Foundation
import MM2TCore
import MM2TDiarization
import Testing
@testable import MM2TApp

/// Builds a library for driving the app by hand: real AliMeeting audio through the real pipeline
/// and the real on-device diarizer, with STT replaced by the corpus's reference transcript and the
/// LLM by a deterministic stand-in. Runs only when asked:
///
///     MM2T_DEMO_LIBRARY=<new data root> MM2T_DEMO_AUDIO=<dir with mic.wav, remote.wav> swift test --filter DemoLibrary
///
/// `mic.wav` is speaker N_SPK8066's near-field channel and `remote.wav` the `nearmix_opus` mix of
/// session R8007_M8011, both cut to the same length.
@Suite(.enabled(if: DemoRequest.current != nil, "set MM2T_DEMO_LIBRARY and MM2T_DEMO_AUDIO"))
struct DemoLibraryTests {
    static let evaluation = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Evaluation/diarization")

    @Test func processesARealMeetingIntoTheLibrary() async throws {
        let (root, audio) = try #require(DemoRequest.current)
        let paths = AppPaths(root: root)
        let library = MeetingLibrary(root: paths.meetings)
        let voiceprints = try VoiceprintStore(fileURL: paths.voiceprints)
        let models = DiarizationModels(directory: Self.evaluation.appending(path: "models"))
        try #require(models.isDownloaded, "run Evaluation/diarization/run_all.sh first")
        let embedder = WeSpeakerEmbedder(models: models)

        let staging = root.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in ["mic.wav", "remote.wav"] {
            try FileManager.default.copyItem(at: audio.appending(path: name), to: staging.appending(path: name))
        }
        let length = 300.0
        let meeting = try await library.create(Recording(
            micTrack: staging.appending(path: "mic.wav"), remoteTrack: staging.appending(path: "remote.wav"),
            highlights: [Highlight(time: 95)],
            metadata: MeetingMetadata(title: "短影音使用調查討論", startedAt: Date(timeIntervalSince1970: 1_793_000_000),
                                      duration: length, platform: .googleMeet)))

        let transcript = try ReferenceTranscript(
            textGrid: Self.evaluation.appending(path: "data/raw/Eval_Ali/Eval_Ali_far/textgrid_dir/R8007_M8011.TextGrid"),
            me: "N_SPK8066", until: length)
        let pipeline = MeetingProcessingPipeline(
            library: library, voiceprints: voiceprints,
            diarizer: NemotronDiarizer(models: models, embedder: embedder), embedder: embedder,
            transcription: TranscriptionChain([.init(.cloud, transcript)]), llm: DemoLLM(),
            thresholds: .weSpeaker, vocabulary: [])
        let processed = try await pipeline.process(meeting.id)
        try? FileManager.default.removeItem(at: staging)

        #expect(processed.status == .completed)
        print("[demo] \(processed.id): \(processed.speakers.count) remote speakers, \(processed.utterances.count) utterances, attribution \(String(describing: processed.attribution).prefix(80))")
        #expect(processed.speakers.count >= 2, "the real diarizer separated the remote mix")
    }
}

enum DemoRequest {
    static var current: (root: URL, audio: URL)? {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["MM2T_DEMO_LIBRARY"], let audio = env["MM2T_DEMO_AUDIO"] else { return nil }
        return (URL(filePath: root), URL(filePath: audio))
    }
}

/// AliMeeting's reference text as an STT result: each interval's characters spread evenly over it.
struct ReferenceTranscript: TranscriptionProvider {
    let me: [TimedWord]
    let remote: [TimedWord]

    init(textGrid: URL, me speaker: String, until end: TimeInterval) throws {
        var tiers: [String: [TimedWord]] = [:]
        var tier = "", start = 0.0, stop = 0.0
        for raw in try String(contentsOf: textGrid, encoding: .utf8).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func value() -> String { String(line.split(separator: "=", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("name =") { tier = value().trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            else if line.hasPrefix("xmin =") { start = Double(value()) ?? 0 }
            else if line.hasPrefix("xmax =") { stop = Double(value()) ?? 0 }
            else if line.hasPrefix("text =") {
                let text = Array(value().trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                guard !text.isEmpty, stop <= end else { continue }
                let step = (stop - start) / Double(text.count)
                tiers[tier, default: []] += text.enumerated().map { index, character in
                    TimedWord(String(character), start + Double(index) * step, start + Double(index + 1) * step)
                }
            }
        }
        me = tiers[speaker] ?? []
        remote = tiers.filter { $0.key != speaker }.flatMap(\.value).sorted { $0.range.start < $1.range.start }
    }

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        .unlabeled(audio.lastPathComponent.hasPrefix("mic") ? me : remote)
    }
}

/// Deterministic LLM output built from the transcript, so every view has content that points
/// back at real utterances.
struct DemoLLM: LLMProvider {
    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] {
        request.unnamedSpeakers.prefix(1).map {
            NameGuess(speaker: $0, name: "小林", reason: "\(SpeakerMention.token(.me)) 在討論開頭點名小林，接著 \(SpeakerMention.token($0)) 回應")
        }
    }

    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript {
        CleanedTranscript(paragraphs: transcript.utterances.map {
            .init(speaker: $0.speaker, text: $0.text.replacingOccurrences(of: "呢", with: "").replacingOccurrences(of: "啊", with: ""), sources: [$0.id])
        })
    }

    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] {
        var order: [SpeakerID] = []
        for u in transcript.utterances where !order.contains(u.speaker) { order.append(u.speaker) }
        return order.map { speaker in
            let mine = transcript.utterances.filter { $0.speaker == speaker }.sorted { $0.text.count > $1.text.count }
            return PersonDigest(speaker: speaker, points: mine.prefix(2).map {
                SourcedText(text: String($0.text.prefix(40)), sources: [$0.id])
            })
        }
    }

    func summarize(_ request: SummaryRequest) async throws -> Summary {
        let long = request.transcript.utterances.sorted { $0.text.count > $1.text.count }
        let key = request.prioritized.first ?? long[0]
        return Summary(
            headline: "討論短影音的使用習慣，決定以 \(SpeakerMention.token(key.speaker)) 的整理作為問卷方向。",
            decisions: [SourcedText(text: "以 \(SpeakerMention.token(key.speaker)) 的整理作為問卷方向", sources: [key.id])],
            discussionPoints: long.prefix(3).map { SourcedText(text: String($0.text.prefix(30)), sources: [$0.id]) },
            actionItems: [.init(text: "整理短影音使用需求清單", owner: long[1].speaker, sources: [long[1].id])])
    }
}
