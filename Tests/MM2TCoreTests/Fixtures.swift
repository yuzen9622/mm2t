import Foundation
@testable import MM2TCore

/// One folder per test process, removed when it exits; one a crashed run left behind is swept an hour later.
let testScratch: URL = {
    let files = FileManager.default
    let parent = files.temporaryDirectory.appending(path: "mm2t-test-runs")
    for old in (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
    where (try? old.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap { $0 } ?? .distantFuture
        < Date(timeIntervalSinceNow: -3600) {
        try? files.removeItem(at: old)
    }
    atexit { try? FileManager.default.removeItem(at: testScratch) }
    return parent.appending(path: UUID().uuidString)
}()

func temporaryDirectory() throws -> URL {
    let url = testScratch.appending(path: "mm2t-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let alice: [Float] = [1, 0, 0.05]
let bob: [Float] = [0, 0, 1]
let thresholds = MatchThresholds(autoName: 0.85, suggest: 0.6)

/// Remote track of a three-person call:
/// c1 (sounds like Alice) opens, c2 (unknown) answers being addressed as 小明,
/// c3 (vaguely like Bob) overlaps c2 at 7.5-8.5 s, c1 closes at 40 s.
enum Script {
    static let diarization = Diarization(
        segments: [
            .init(cluster: ClusterID("c1"), range: TimeRange(start: 0, end: 4)),
            .init(cluster: ClusterID("c2"), range: TimeRange(start: 4, end: 8)),
            .init(cluster: ClusterID("c3"), range: TimeRange(start: 8, end: 12)),
            .init(cluster: ClusterID("c1"), range: TimeRange(start: 40, end: 44)),
        ],
        overlaps: [TimeRange(start: 7.5, end: 8.5)],
        embeddings: [
            ClusterID("c1"): [Embedding([0.98, 0.02, 0.04])],
            ClusterID("c2"): [Embedding([0, 1, 0]), Embedding([0.05, 0.99, 0])],
            ClusterID("c3"): [Embedding([0, 0.6, 0.75])],
        ])

    static let remoteWords = [
        TimedWord("Hi", 0.5, 1), TimedWord("team,", 1, 1.4), TimedWord("小明", 1.6, 2.2), TimedWord("你覺得呢", 2.2, 3),
        TimedWord("我", 4.5, 4.8), TimedWord("覺得", 4.8, 5.4), TimedWord("可以", 5.4, 7.9),
        TimedWord("我", 8.1, 8.4), TimedWord("同意", 8.4, 9),
        TimedWord("Ship", 40.5, 41), TimedWord("it", 41, 41.3),
    ]

    /// What a diarizing cloud STT labels the same words: it hears c2 and c3 as one voice.
    static let remoteLabels = ["speaker_0", "speaker_0", "speaker_0", "speaker_0",
                               "speaker_1", "speaker_1", "speaker_1", "speaker_1", "speaker_1",
                               "speaker_0", "speaker_0"].map(ClusterID.init)

    static let micWords = [TimedWord("Thanks", 50, 50.5), TimedWord("all", 50.5, 51)]

    static let highlight = Highlight(time: 42)
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
}

struct LocalModelError: Error {}

struct ScriptedDiarizer: Diarizer {
    let result: Diarization
    let calls = Box(0)
    let fails = Box(false)
    /// What is heard on the mic of a call, which is diarized after its remote track. nil is the
    /// usual call: one voice, the user's.
    let micOnCall = Box<Diarization?>(nil)
    private let heardRemote = Box(false)
    init(_ result: Diarization = Script.diarization) { self.result = result }
    func diarize(track: URL) async throws -> Diarization {
        calls.update { $0 += 1 }
        if fails.get { throw LocalModelError() }
        guard track.lastPathComponent.hasPrefix("mic"), heardRemote.get else {
            heardRemote.update { $0 = !track.lastPathComponent.hasPrefix("mic") }
            return result
        }
        return micOnCall.get ?? Diarization(
            segments: [.init(cluster: ClusterID("m1"), range: TimeRange(start: 50, end: 51))], overlaps: [], embeddings: [:])
    }
}

/// Marks as echo whatever the mic heard in `echo`.
struct ScriptedCleaner: MicCleaner {
    let echo: TimeRange
    func clean(mic: URL, remote: URL) throws -> CleanedMic? {
        let url = mic.deletingLastPathComponent().appending(path: "mic-clean-\(UUID().uuidString).caf")
        try Data("clean mic audio".utf8).write(to: url)
        let frames = 600
        let after = (0..<frames).map { echo.intersects(TimeRange(start: Double($0) / 10, end: Double($0 + 1) / 10)) ? Float(0.01) : 1 }
        return CleanedMic(audio: url, echo: EchoProfile(frameDuration: 0.1, before: [Float](repeating: 1, count: frames), after: after))
    }
}

/// Hears the voices of `Script.diarization`: each cluster gets the vectors of the scripted
/// voice it overlaps most.
struct ScriptedEmbedder: SpeakerEmbedder {
    let calls = Box<[[String]]>([])
    let fails = Box(false)

    func embeddings(track: URL, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]] {
        calls.update { $0.append(segments.map { "\($0.cluster.rawValue)@\($0.range.start)-\($0.range.end)" }) }
        if fails.get { throw LocalModelError() }
        let voices = Script.diarization
        return Dictionary(grouping: segments, by: \.cluster).mapValues { turns in
            let voice = voices.segments.max { a, b in
                turns.map { $0.range.overlap(with: a.range) }.reduce(0, +)
                    < turns.map { $0.range.overlap(with: b.range) }.reduce(0, +)
            }
            return voice.flatMap { voices.embeddings[$0.cluster] } ?? []
        }
    }
}

struct FakeSTT: TranscriptionProvider {
    enum Behavior { case words, unreachable, failed }
    let behavior: Box<Behavior>
    /// Set for a provider that diarizes: labels for `Script.remoteWords` when asked.
    let labels: [ClusterID]?
    let calls = Box<[(file: String, hints: [String], labelSpeakers: Bool)]>([])
    /// An in-person meeting: nothing on the remote track, and the mic heard `Script.remoteWords`.
    let roomOnly = Box(false)

    init(_ behavior: Behavior = .words, labels: [ClusterID]? = nil) {
        self.behavior = Box(behavior)
        self.labels = labels
    }

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        calls.update { $0.append((audio.lastPathComponent, hints, labelSpeakers)) }
        switch behavior.get {
        case .unreachable: throw TranscriptionError.unreachable("connection refused")
        case .failed: throw TranscriptionError.failed("invalid API key")
        case .words:
            let isMic = audio.lastPathComponent.hasPrefix("mic")
            if roomOnly.get, !isMic { return .unlabeled([]) }
            let words = isMic && !roomOnly.get ? Script.micWords : Script.remoteWords
            guard labelSpeakers, let labels else { return .unlabeled(words) }
            return .labeled(zip(words, labels).map { LabeledWord($0, speaker: $1) })
        }
    }
}

struct FakeLLMError: Error {}

/// Echoes the transcript back in each output shape, referring to speakers only by id.
struct FakeLLM: LLMProvider {
    let calls = Box<[String]>([])
    let summaryRequests = Box<[SummaryRequest]>([])
    let failNext = Box<Set<String>>([])
    /// Runs inside the named task, i.e. while the pipeline is mid-step.
    let during = Box<[String: @Sendable () async -> Void]>([:])
    let glossaries = Box<[[String]]>([])
    let title = Box<String?>(nil)

    private func record(_ task: String) async throws {
        calls.update { $0.append(task) }
        if let action = during.get[task] { await action() }
        if failNext.get.contains(task) {
            failNext.update { $0.remove(task) }
            throw FakeLLMError()
        }
    }

    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] {
        try await record("inferNames")
        return request.unnamedSpeakers.filter { $0 == SpeakerID("r2") }.map {
            NameGuess(speaker: $0, name: "小明",
                      reason: "\(SpeakerMention.token(SpeakerID("r1"))) asked 小明 and \(SpeakerMention.token($0)) answered")
        } + [NameGuess(speaker: SpeakerID("r99"), name: "Ghost", reason: "not in this meeting")]
    }

    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript {
        try await record("cleanTranscript")
        glossaries.update { $0.append(transcript.glossary) }
        return CleanedTranscript(paragraphs: transcript.utterances.map {
            .init(speaker: $0.speaker, text: "clean: \($0.text)", sources: [$0.id])
        })
    }

    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] {
        try await record("digestPerPerson")
        var order: [SpeakerID] = []
        for u in transcript.utterances where !order.contains(u.speaker) { order.append(u.speaker) }
        return order.map { speaker in
            let mine = transcript.utterances.filter { $0.speaker == speaker }
            return PersonDigest(speaker: speaker, points: [
                SourcedText(text: "\(SpeakerMention.token(speaker)) spoke \(mine.count) times", sources: mine.map(\.id)),
            ])
        }
    }

    func summarize(_ request: SummaryRequest) async throws -> Summary {
        try await record("summarize")
        summaryRequests.update { $0.append(request) }
        let key = request.prioritized.first ?? request.transcript.utterances[0]
        return Summary(
            headline: "讨论软件", title: title.get, terms: ["mm2t", "软件"],
            decisions: [SourcedText(text: "Ship it, proposed by \(SpeakerMention.token(key.speaker))", sources: [key.id])],
            discussionPoints: [SourcedText(text: "Whether \(SpeakerMention.token(SpeakerID("r3"))) agrees", sources: [])],
            actionItems: [.init(text: "Follow up", owner: SpeakerID("r2"), sources: [key.id])])
    }
}

/// What the on-device speaker model can do on this machine.
enum LocalSpeakerModel { case diarizerAndEmbedder, embedderOnly, none }

/// A library, a voiceprint store that already knows Alice and Bob, and a pipeline whose
/// self-hosted STT is down so transcription falls back to a diarizing cloud STT.
struct World {
    let root: URL
    let library: MeetingLibrary
    let voiceprints: VoiceprintStore
    let diarizer: ScriptedDiarizer
    let embedder = ScriptedEmbedder()
    let localModel: LocalSpeakerModel
    let diarizationOrder: [DiarizationSource]?
    let runsConcurrently = Box(false)
    let micCleaner = Box<(any MicCleaner)?>(nil)
    let selfHosted = FakeSTT(.unreachable)
    let cloud = FakeSTT(labels: Script.remoteLabels)
    let local = FakeSTT()
    let llm = FakeLLM()
    let aliceID: PersonID
    let bobID: PersonID

    init(
        diarization: Diarization = Script.diarization,
        localModel: LocalSpeakerModel = .diarizerAndEmbedder,
        diarizationOrder: [DiarizationSource]? = nil
    ) async throws {
        self.localModel = localModel
        self.diarizationOrder = diarizationOrder
        root = try temporaryDirectory()
        library = MeetingLibrary(root: root.appending(path: "meetings"))
        voiceprints = try VoiceprintStore(fileURL: root.appending(path: "voiceprints.json"))
        diarizer = ScriptedDiarizer(diarization)
        aliceID = try await voiceprints.addPerson(name: "Alice", embeddings: [Embedding(alice)])
        bobID = try await voiceprints.addPerson(name: "Bob", embeddings: [Embedding(bob)])
    }

    var pipeline: MeetingProcessingPipeline {
        let transcription = TranscriptionChain([.init(.selfHosted, selfHosted), .init(.cloud, cloud), .init(.local, local)])
        let diarizer: (any Diarizer)? = localModel == .diarizerAndEmbedder ? diarizer : nil
        let embedder: (any SpeakerEmbedder)? = localModel == .none ? nil : embedder
        guard let diarizationOrder else {
            return MeetingProcessingPipeline(
                library: library, voiceprints: voiceprints, diarizer: diarizer, embedder: embedder,
                transcription: transcription, llm: llm, thresholds: thresholds, vocabulary: ["mm2t", "Alice"],
                runsConcurrently: runsConcurrently.get, micCleaner: micCleaner.get)
        }
        return MeetingProcessingPipeline(
            library: library, voiceprints: voiceprints, diarizer: diarizer, embedder: embedder,
            diarizationOrder: diarizationOrder,
            transcription: transcription, llm: llm, thresholds: thresholds, vocabulary: ["mm2t", "Alice"],
                runsConcurrently: runsConcurrently.get, micCleaner: micCleaner.get)
    }

    var editing: SpeakerEditing { SpeakerEditing(library: library, voiceprints: voiceprints) }

    func record(title: String = "Weekly sync", startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) async throws -> Meeting {
        let staging = root.appending(path: "staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let mic = staging.appending(path: "mic.caf"), remote = staging.appending(path: "remote.caf")
        try Data("mic audio".utf8).write(to: mic)
        try Data("remote audio".utf8).write(to: remote)
        return try await library.create(Recording(
            micTrack: mic, remoteTrack: remote, highlights: [Script.highlight],
            metadata: MeetingMetadata(title: title, startedAt: startedAt, duration: 52, platform: .zoom)))
    }

    func processed() async throws -> Meeting {
        try await pipeline.process(record().id)
    }

    func render(_ meeting: Meeting, _ view: TranscriptView, _ format: ExportFormat = .plainText) async -> String {
        MeetingRenderer(meeting: meeting, names: await voiceprints.names()).render(view, as: format)
    }

    var providerCallCount: Int {
        llm.calls.get.count + selfHosted.calls.get.count + cloud.calls.get.count + local.calls.get.count
    }
}
