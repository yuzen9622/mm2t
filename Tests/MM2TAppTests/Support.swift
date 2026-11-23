import Foundation
import MM2TCore
import MM2TLocal
import MM2TProviders
import MM2TSystem
import Testing
@testable import MM2TApp

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
    let url = testScratch.appending(path: "mm2t-app-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func set(_ new: T) { lock.withLock { value = new } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
}

/// Suspends a caller until the test opens it, e.g. the user answering a permission prompt.
actor Gate<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func open(_ value: Value) {
        self.value = value
        waiters.forEach { $0.resume(returning: value) }
        waiters = []
    }
}

/// Polls the main actor until `condition` holds, for states reached by a task the test started.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

// MARK: Speech

/// A call where the remote voice c1 opens and is addressed as 小明 by c2, then c1 answers.
enum Script {
    static let diarization = Diarization(
        segments: [
            .init(cluster: ClusterID("c1"), range: TimeRange(start: 0, end: 4)),
            .init(cluster: ClusterID("c2"), range: TimeRange(start: 4, end: 8)),
            .init(cluster: ClusterID("c1"), range: TimeRange(start: 20, end: 24)),
        ],
        overlaps: [TimeRange(start: 5.5, end: 6.5)],
        embeddings: [
            ClusterID("c1"): [Embedding([1, 0, 0])],
            ClusterID("c2"): [Embedding([0, 1, 0])],
        ])

    static let remoteWords = [
        TimedWord("大家好", 0.5, 1.5), TimedWord("今天", 1.6, 2.2), TimedWord("討論預算", 2.2, 3.5),
        TimedWord("小明", 4.5, 5), TimedWord("你覺得呢", 5, 6),
        TimedWord("我同意", 20.5, 21.5),
    ]
    static let micWords = [TimedWord("那就這樣", 30, 31), TimedWord("決定", 31, 31.5)]
}

struct FakeSTT: TranscriptionProvider {
    enum Behavior: Sendable { case words, unreachable, failed }
    let behavior: Box<Behavior>
    let calls = Box<[(file: String, hints: [String])]>([])
    /// Whether each call asked for speaker labels.
    let labelRequests = Box<[Bool]>([])

    init(_ behavior: Behavior = .words) { self.behavior = Box(behavior) }

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        calls.update { $0.append((audio.lastPathComponent, hints)) }
        labelRequests.update { $0.append(labelSpeakers) }
        switch behavior.get {
        case .unreachable: throw TranscriptionError.unreachable("connection refused")
        case .failed: throw TranscriptionError.failed("invalid API key")
        case .words: return .unlabeled(audio.lastPathComponent.hasPrefix("mic") ? Script.micWords : Script.remoteWords)
        }
    }
}

/// A scripted streaming speech service: each `open` hands out a session the test drives.
final class FakeStreamingSTT: StreamingTranscriptionProvider, @unchecked Sendable {
    let requests = Box<[StreamingTranscriptionRequest]>([])
    let sessions = Box<[FakeStreamingSession]>([])
    /// Thrown by the next opens, in order, before any succeeds.
    let openFailures = Box<[TranscriptionError]>([])

    func open(_ request: StreamingTranscriptionRequest) async throws -> any StreamingTranscriptionSession {
        requests.update { $0.append(request) }
        var failure: TranscriptionError?
        openFailures.update { if !$0.isEmpty { failure = $0.removeFirst() } }
        if let failure { throw failure }
        let session = FakeStreamingSession()
        sessions.update { $0.append(session) }
        return session
    }

    var last: FakeStreamingSession? { sessions.get.last }
}

final class FakeStreamingSession: StreamingTranscriptionSession, @unchecked Sendable {
    let events: AsyncThrowingStream<StreamingTranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation
    let sent = Box<[[Float]]>([])
    let closed = Box(false)
    let discardGate = Box<Gate<Bool>?>(nil)

    func discard() async {
        if let gate = discardGate.get { _ = await gate.wait() }
        await close()
    }

    init() { (events, continuation) = AsyncThrowingStream.makeStream() }

    func send(_ samples: [Float]) async throws { sent.update { $0.append(samples) } }
    func close() async {
        closed.set(true)
        continuation.finish()
    }

    func say(_ event: StreamingTranscriptEvent) { continuation.yield(event) }
    func drop(_ error: Error = TranscriptionError.unreachable("connection lost")) { continuation.finish(throwing: error) }
    var sentSeconds: Double { Double(sent.get.reduce(0) { $0 + $1.count }) / 16_000 }
}

func assistantDecision(_ action: String, query: String = "", people: [String] = [], from: String? = nil,
                       to: String? = nil, cursor: String? = nil, handles: [String] = [], status: String = "unmarked") -> String {
    let object: [String: Any] = ["reasoning": "查詢會議", "action": action, "query": query, "people": people,
        "owner": "me", "status": status, "sort": "due", "dateFrom": from as Any? ?? NSNull(),
        "dateTo": to as Any? ?? NSNull(), "dueFrom": NSNull(), "dueTo": NSNull(), "cursor": cursor as Any? ?? NSNull(), "handles": handles]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

struct FakeLLMError: Error, CustomStringConvertible {
    var description: String { "Gemini 暫時無法服務" }
}

/// Echoes the transcript back in each output shape, naming speakers only by token.
struct FakeLLM: LLMProvider, StructuredGenerator {
    let decisions = Box([assistantDecision("search_meetings", query: "預算"), assistantDecision("read_meeting"), assistantDecision("answer")])
    let generationInputs = Box<[String]>([])
    let scopeDirective = Box("keep")
    let memoryJSON = Box(#"{"preference":null}"#)
    let answerChunks = Box(["Answer [m1] [m1.u1] [m99]"])
    let resumedAnswerChunks = Box<[String]>([])
    let answerInputs = Box<[String]>([])
    let streamCancelled = Box(false)
    let holdsStream = Box(false)
    let failsStream = Box(false)
    let providerStreamError = Box<ProviderError?>(nil)
    let lateAfterCancellation = Box<[String]>([])
    var service: Service { .gemini }
    func generate(system: String, input: String, schema: JSON) async throws -> String {
        if system.hasPrefix("Scope of referenced meetings:") { return "{\"choice\":\"\(scopeDirective.get)\"}" }
        if system.hasPrefix("Memory intent:") { return memoryJSON.get }
        generationInputs.update { $0.append(input) }
        try await record("plan")
        var result = assistantDecision("answer")
        decisions.update { if !$0.isEmpty { result = $0.removeFirst() } }
        return result
    }
    func streamText(system: String, input: String) -> AsyncThrowingStream<String, Error> {
        answerInputs.update { $0.append(input) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for text in answerChunks.get { continuation.yield(text) }
                if let gate = holds.get["answer"] { _ = await gate.wait() }
                for text in resumedAnswerChunks.get { continuation.yield(text) }
                if holdsStream.get {
                    do { try await Task.sleep(for: .seconds(60)) } catch {
                        for text in lateAfterCancellation.get { continuation.yield(text) }
                        streamCancelled.set(true)
                    }
                }
                if let error = providerStreamError.get { continuation.finish(throwing: error) }
                else if failsStream.get { continuation.finish(throwing: FakeLLMError()) }
                else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    let calls = Box<[String]>([])
    let failNext = Box<Set<String>>([])
    let corrections = Box<[VocabularyCorrection]>([])
    let correctionRequests = Box<[(String, String)]>([])
    let cleanGlossaries = Box<[[String]]>([])
    /// Suspends the named task until the gate opens, to observe the app mid-step.
    let holds = Box<[String: Gate<Bool>]>([:])

    private func record(_ task: String) async throws {
        calls.update { $0.append(task) }
        if let gate = holds.get[task] { _ = await gate.wait() }
        if failNext.get.contains(task) {
            failNext.update { $0.remove(task) }
            throw FakeLLMError()
        }
    }

    func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection] {
        correctionRequests.update { $0.append((old, new)) }
        let result = corrections.get
        try await record("vocabularyCorrections")
        return result
    }

    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] {
        try await record("inferNames")
        return request.unnamedSpeakers.filter { $0 == SpeakerID("r1") }.map {
            NameGuess(speaker: $0, name: "小明", reason: "\(SpeakerMention.token(SpeakerID("r2"))) 叫了小明，接著 \(SpeakerMention.token($0)) 回答")
        }
    }

    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript {
        cleanGlossaries.update { $0.append(transcript.glossary) }
        try await record("cleanTranscript")
        return CleanedTranscript(paragraphs: transcript.utterances.map {
            .init(speaker: $0.speaker, text: "整理：\($0.text)", sources: [$0.id])
        })
    }

    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] {
        try await record("digestPerPerson")
        var order: [SpeakerID] = []
        for u in transcript.utterances where !order.contains(u.speaker) { order.append(u.speaker) }
        return order.map { speaker in
            let mine = transcript.utterances.filter { $0.speaker == speaker }
            return PersonDigest(speaker: speaker, points: [
                SourcedText(text: "\(SpeakerMention.token(speaker)) 發言 \(mine.count) 次", sources: mine.map(\.id)),
            ])
        }
    }

    func summarize(_ request: SummaryRequest) async throws -> Summary {
        try await record("summarize")
        let last = request.transcript.utterances.last!
        return Summary(
            headline: "\(SpeakerMention.token(last.speaker)) 拍板預算，\(SpeakerMention.token(.me)) 整理報價。",
            terms: ["Kubernetes", "報價單"],
            decisions: [SourcedText(text: "由 \(SpeakerMention.token(last.speaker)) 拍板", sources: [last.id])],
            discussionPoints: [SourcedText(text: "預算", sources: [request.transcript.utterances[0].id])],
            actionItems: [.init(text: "整理報價", owner: SpeakerID("r1"), sources: [last.id])])
    }
}

struct LocalModelError: Error {}

struct ScriptedDiarizer: Diarizer {
    let fails = Box(false)
    func diarize(track: URL) async throws -> Diarization {
        if fails.get { throw LocalModelError() }
        return Script.diarization
    }
}

struct ScriptedEmbedder: SpeakerEmbedder {
    let dimensions = 3
    func embeddings(track: URL, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]] {
        Script.diarization.embeddings
    }
}

/// Hands out the fakes and records which keys and URLs reached them.
final class FakeCatalog: ProviderCatalog, @unchecked Sendable {
    let selfHosted = FakeSTT(.unreachable)
    let cloud = FakeSTT()
    let llm = FakeLLM()
    let diarizer = ScriptedDiarizer()
    let recordingDiarizer = Box<(any Diarizer)?>(nil)
    let modelsDownloaded = Box(true)
    let onDeviceSTT = FakeSTT()
    let offlineDownloaded: [OfflineModel: Box<Bool>] = Dictionary(uniqueKeysWithValues: OfflineModel.allCases.map { ($0, Box(false)) })
    let keysUsed = Box<[String]>([])
    let selfHostedURLs = Box<[URL]>([])
    let languagesUsed = Box<[TranscriptionLanguage]>([])
    let openAIEndpoints = Box<[String]>([])

    func cloudTranscription(apiKey: Secret, language: TranscriptionLanguage) -> any TranscriptionProvider {
        keysUsed.update { $0.append("stt:" + apiKey.revealed) }
        languagesUsed.update { $0.append(language) }
        return cloud
    }

    func selfHostedTranscription(url: URL, token: Secret?, language: TranscriptionLanguage) -> any TranscriptionProvider {
        selfHostedURLs.update { $0.append(url) }
        languagesUsed.update { $0.append(language) }
        return selfHosted
    }

    let streaming = FakeStreamingSTT()
    func streamingTranscription(apiKey: Secret) -> any StreamingTranscriptionProvider {
        keysUsed.update { $0.append("captions:" + apiKey.revealed) }
        return streaming
    }

    let selfHostedStreaming = FakeStreamingSTT()
    func selfHostedStreamingTranscription(url: URL, token: Secret?) -> any StreamingTranscriptionProvider {
        selfHostedURLs.update { $0.append(url) }
        return selfHostedStreaming
    }

    let localStreaming = FakeStreamingSTT()
    func localStreamingTranscription(model: LocalSpeechModel, alongsideBreeze: Bool) -> (any StreamingTranscriptionProvider)? {
        offlineDownloaded[OfflineModel(model)]!.get ? localStreaming : nil
    }

    func openAICompatibleLLM(baseURL: URL, apiKey: Secret?, model: String) -> any LLMProvider {
        openAIEndpoints.update { $0.append("\(baseURL.absoluteString)|\(apiKey?.revealed ?? "-")|\(model)") }
        return llm
    }

    func llm(apiKey: Secret) -> any LLMProvider {
        keysUsed.update { $0.append("llm:" + apiKey.revealed) }
        return llm
    }

    func localSpeakerModels() -> LocalSpeakerModels? {
        modelsDownloaded.get ? LocalSpeakerModels(diarizer: recordingDiarizer.get ?? diarizer, embedder: ScriptedEmbedder()) : nil
    }

    func localTranscription(model: LocalSpeechModel, language: TranscriptionLanguage) -> (any TranscriptionProvider)? {
        languagesUsed.update { $0.append(language) }
        return offlineDownloaded[OfflineModel(model)]!.get ? onDeviceSTT : nil
    }

    func hostedTranscription(url: URL, token: Secret, language: TranscriptionLanguage) -> any TranscriptionProvider {
        keysUsed.update { $0.append("hosted-stt:" + token.revealed) }
        return selfHostedTranscription(url: url, token: token, language: language)
    }

    func hostedLLM(url: URL, token: Secret) -> any LLMProvider {
        openAICompatibleLLM(baseURL: url, apiKey: token, model: "mm2t")
    }

    let translator = FakeTranslator()
    let translationDownloaded = Box(false)
    let translatorTargets = Box<[CaptionTarget]>([])
    func captionTranslator(for target: CaptionTarget, engine: CaptionEngine, source: CaptionLanguage?) -> (any CaptionTranslator)? {
        translatorTargets.update { $0.append(target) }
        return translationDownloaded.get ? translator : nil
    }

    var thresholds: MatchThresholds { MatchThresholds(autoName: 0.9, suggest: 0.6) }

    var providerCalls: Int {
        selfHosted.calls.get.count + cloud.calls.get.count + llm.calls.get.count
            + onDeviceSTT.calls.get.count
    }
}

final class MemoryCredentials: CredentialStoring, @unchecked Sendable {
    let values = Box<[Credential: String]>([:])
    func read(_ credential: Credential) throws -> Secret? { values.get[credential].map { Secret($0) } }
    func save(_ secret: Secret, for credential: Credential) throws {
        values.update { $0[credential] = secret.isEmpty ? nil : secret.revealed }
    }
}

final class FakePermissions: PermissionsProviding, @unchecked Sendable {
    let mic = Box(PermissionState.granted)
    let answer = Gate<Bool>()
    let micRequests = Box(0)
    var microphone: PermissionState { mic.get }
    func requestMicrophone() async -> Bool {
        micRequests.update { $0 += 1 }
        let granted = await answer.wait()
        mic.set(granted ? .granted : .denied)
        return granted
    }
    var systemAudio: PermissionState { .unknown }
    var accessibility: PermissionState { .denied }
    func requestAccessibility() {}
    func automation(of bundleID: String) -> PermissionState { .notDetermined }
    func requestAutomation(of bundleID: String) async -> PermissionState { .granted }
}

final class FakeInstaller: ModelInstalling, @unchecked Sendable {
    struct Failed: Error {}
    let downloaded: Box<Bool>
    let downloadBytes: Int64
    /// When set, a download stops half way until the gate opens; true lets it finish, false fails it.
    let hold = Box<Gate<Bool>?>(nil)
    let downloads = Box(0)
    init(_ downloaded: Box<Bool>, bytes: Int64 = 100_000_000) {
        self.downloaded = downloaded
        downloadBytes = bytes
    }
    var isDownloaded: Bool { downloaded.get }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        downloads.update { $0 += 1 }
        progress(0.5)
        if let gate = hold.get, !(await gate.wait()) { throw Failed() }
        downloaded.set(true)
        progress(1)
    }
}

/// A caption translator whose answers the test controls: each call waits for its own release,
/// so results can come back in any order. Unless `holds` is set, it answers at once.
final class FakeTranslator: CaptionTranslator, @unchecked Sendable {
    struct Call: Equatable { let text: String; let languages: [String] }
    let calls = Box<[Call]>([])
    let holds = Box(false)
    let failing = Box<Set<String>>([])
    /// Fixed answers by input; anything else comes back bracketed.
    let answers = Box<[String: String]>([:])
    private let gates = Box<[String: Gate<Bool>]>([:])

    func translate(_ text: String, through languages: [String]) async throws -> String {
        calls.update { $0.append(Call(text: text, languages: languages)) }
        if holds.get {
            let gate = Gate<Bool>()
            gates.update { $0[text] = gate }
            _ = await gate.wait()
        }
        if failing.get.contains(text) { throw CaptionTranslationError.engine("model failed") }
        return answers.get[text] ?? "⟨\(text)⟩"
    }

    /// Lets the held call for `text` return.
    func release(_ text: String) async {
        let gate = gates.get[text]
        gates.update { $0[text] = nil }
        await gate?.open(true)
    }

    var held: [String] { gates.get.keys.sorted() }
}

struct FakeValidator: KeyValidating {
    let requests = Box<[KeyValidation]>([])
    func validate(_ request: KeyValidation) async -> KeyCheck {
        requests.update { $0.append(request) }
        if case .gemini(let key) = request, key.revealed == "bad" { return .rejected("Gemini API Key 無效") }
        if case .gemini(let key) = request, key.revealed == "timeout" { return .inconclusive("Could not reach Gemini") }
        return .valid
    }
}

/// Writes two short WAV tracks into the session directory on stop, as the real recorder does.
actor FakeSession: RecordingSession {
    nonisolated let events: AsyncStream<RecorderEvent>
    nonisolated let configuration: RecorderConfiguration
    private let continuation: AsyncStream<RecorderEvent>.Continuation
    private(set) var isPaused = false
    private var highlights: [Highlight] = []
    private var clock: TimeInterval = 0
    private var audio: AsyncStream<[Float]>.Continuation?
    private(set) var audioRequests = 0

    init(_ configuration: RecorderConfiguration) throws {
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream()
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        try RecordingManifest(title: configuration.title, startedAt: Date(), platform: configuration.platform,
                              targetBundleID: configuration.targetBundleID).write(to: configuration.directory)
    }

    nonisolated func send(_ event: RecorderEvent) { continuation.yield(event) }

    func audioStream() -> AsyncStream<[Float]> {
        audioRequests += 1
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        audio = continuation
        return stream
    }

    /// Plays `seconds` of mixed audio into the caption stream, as the recorder would.
    func speak(seconds: Double = 0.25) { audio?.yield([Float](repeating: 0.1, count: Int(16_000 * seconds))) }

    var elapsed: TimeInterval { clock }
    func advance(_ seconds: TimeInterval) { clock += seconds }
    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func markHighlight() throws -> Highlight {
        let highlight = Highlight(time: clock)
        highlights.append(highlight)
        return highlight
    }

    func stop() throws -> Recording {
        continuation.finish()
        audio?.finish()
        let directory = configuration.directory
        for name in [RecordingManifest.micFile, RecordingManifest.remoteFile] {
            let writer = try WAVWriter(url: directory.appending(path: name), sampleRate: 16_000)
            writer.appendSilence(frames: 16_000)
            try writer.close()
        }
        return Recording(
            micTrack: directory.appending(path: RecordingManifest.micFile),
            remoteTrack: directory.appending(path: RecordingManifest.remoteFile),
            highlights: highlights,
            metadata: MeetingMetadata(title: configuration.title, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      duration: 35, platform: configuration.platform))
    }
}

final class FakeRecorder: Recorder, @unchecked Sendable {
    let sessions = Box<[FakeSession]>([])
    let failure = Box<RecorderError?>(nil)

    func start(_ configuration: RecorderConfiguration) async throws -> any RecordingSession {
        if let error = failure.get { throw error }
        let session = try FakeSession(configuration)
        sessions.update { $0.append(session) }
        return session
    }

    var last: FakeSession? { sessions.get.last }
}

@MainActor
final class FakePlayback: MeetingPlayback {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var loaded: [URL] = []
    func load(mic: URL, remote: URL) { loaded = [mic, remote] }
    func play(from time: TimeInterval) {
        currentTime = time
        isPlaying = true
    }
    func pause() { isPlaying = false }
}

let testLabels = PresentationLabels(
    me: "我",
    viewTitle: { ["raw": "逐字稿", "cleaned": "整理版", "perPerson": "依人彙整", "summary": "摘要"][$0.rawValue]! },
    overlapping: "重疊", notGenerated: "尚未產生", stale: "說話者已變更，請重新產生",
    decisions: "決議", discussionPoints: "討論重點", actionItems: "待辦事項", owner: { "負責人：\($0)" })

enum Signals {
    static func zoom(mic: Bool = true) -> SystemSignals {
        SystemSignals(micBundleIDs: mic ? ["us.zoom.xos"] : [])
    }
    static let teams = SystemSignals(micBundleIDs: ["com.microsoft.teams2"])
    static let quiet = SystemSignals(micBundleIDs: [])
}

/// The app's real composition root with every machine boundary scripted: a fresh data folder,
/// fake STT and LLM behind the real pipeline, in-memory keys and a fake recorder.
@MainActor
struct World {
    let root: URL
    let catalog = FakeCatalog()
    let credentials = MemoryCredentials()
    let recorder = FakeRecorder()
    let permissions = FakePermissions()
    let validator = FakeValidator()
    let speakerInstaller: FakeInstaller
    let translationInstaller: FakeInstaller
    let offlineInstallers: [OfflineModel: FakeInstaller]
    let defaults: UserDefaults
    let now: Box<Date>
    let app: AppController

    /// `endCountdown` is zero unless a test is about the countdown, so a meeting ending stops at once.
    init(keys: Bool = true, machine: MachineProfile = MachineProfile(isAppleSilicon: true, memoryBytes: 16 << 30),
         endCountdown: Duration = .zero, setupValidator: (any KeyValidating)? = nil,
         collabConfiguration: CollabConfiguration? = nil) throws {
        root = try temporaryDirectory()
        defaults = UserDefaults(suiteName: "mm2t-tests-\(UUID().uuidString)")!
        if keys {
            try credentials.save("eleven-key", for: .elevenLabsAPIKey)
            try credentials.save("gemini-key", for: .geminiAPIKey)
        }
        let now = Box(Date(timeIntervalSince1970: 1_800_000_000))
        self.now = now
        speakerInstaller = FakeInstaller(catalog.modelsDownloaded, bytes: 220_000_000)
        let translation = FakeInstaller(catalog.translationDownloaded, bytes: 75_000_000)
        translationInstaller = translation
        offlineInstallers = catalog.offlineDownloaded.mapValues { FakeInstaller($0, bytes: 1_000_000_000) }
        app = try AppController(
            paths: AppPaths(root: root), defaults: defaults, credentials: credentials, catalog: catalog,
            recorder: recorder, permissions: permissions, installer: speakerInstaller,
            offlineInstallers: offlineInstallers,
            translationInstaller: { _, _ in translation },
            machine: machine, validator: setupValidator ?? validator, now: { now.get }, endCountdown: endCountdown,
            collabConfiguration: collabConfiguration)
        app.settings.settings.translationEnabled = true
        app.settings.settings.captionEngine = .firefox
    }

    var capture: CaptureController { app.capture }
    var queue: ProcessingQueue { app.queue }
    var library: MeetingLibrary { app.library }

    /// A meeting recorded through the capture controller and processed by the real pipeline.
    func recordedMeeting(title: String = "預算會議") async throws -> Meeting {
        await capture.startManually(RecordingTarget(bundleID: "us.zoom.xos", name: title, platform: .zoom))
        await capture.stop()
        let meetings = try await library.list()
        return try #require(meetings.first { $0.metadata.title == title })
    }

    func detail(_ id: MeetingID, playback: FakePlayback? = nil) -> MeetingDetailModel {
        app.detail(id, labels: testLabels, playback: playback)
    }
}

