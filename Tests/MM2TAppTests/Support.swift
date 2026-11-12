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

    init(_ behavior: Behavior = .words) { self.behavior = Box(behavior) }

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        calls.update { $0.append((audio.lastPathComponent, hints)) }
        switch behavior.get {
        case .unreachable: throw TranscriptionError.unreachable("connection refused")
        case .failed: throw TranscriptionError.failed("invalid API key")
        case .words: return .unlabeled(audio.lastPathComponent.hasPrefix("mic") ? Script.micWords : Script.remoteWords)
        }
    }
}

struct FakeLLMError: Error, CustomStringConvertible {
    var description: String { "Gemini 暫時無法服務" }
}

/// Echoes the transcript back in each output shape, naming speakers only by token.
struct FakeLLM: LLMProvider {
    let calls = Box<[String]>([])
    let failNext = Box<Set<String>>([])
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

    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] {
        try await record("inferNames")
        return request.unnamedSpeakers.filter { $0 == SpeakerID("r1") }.map {
            NameGuess(speaker: $0, name: "小明", reason: "\(SpeakerMention.token(SpeakerID("r2"))) 叫了小明，接著 \(SpeakerMention.token($0)) 回答")
        }
    }

    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript {
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
    let modelsDownloaded = Box(true)
    let onDeviceSTT = FakeSTT()
    let onDeviceLLM = FakeLLM()
    let offlineDownloaded: [OfflineModel: Box<Bool>] = [.transcription: Box(false), .llm: Box(false)]
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

    func openAICompatibleLLM(baseURL: URL, apiKey: Secret?, model: String) -> any LLMProvider {
        openAIEndpoints.update { $0.append("\(baseURL.absoluteString)|\(apiKey?.revealed ?? "-")|\(model)") }
        return llm
    }

    func llm(apiKey: Secret) -> any LLMProvider {
        keysUsed.update { $0.append("llm:" + apiKey.revealed) }
        return llm
    }

    func localSpeakerModels() -> LocalSpeakerModels? {
        modelsDownloaded.get ? LocalSpeakerModels(diarizer: diarizer, embedder: ScriptedEmbedder()) : nil
    }

    func localTranscription(language: TranscriptionLanguage) -> (any TranscriptionProvider)? {
        languagesUsed.update { $0.append(language) }
        return offlineDownloaded[.transcription]!.get ? onDeviceSTT : nil
    }

    func localLLM() -> (any LLMProvider)? {
        offlineDownloaded[.llm]!.get ? onDeviceLLM : nil
    }

    var thresholds: MatchThresholds { MatchThresholds(autoName: 0.9, suggest: 0.6) }

    var providerCalls: Int {
        selfHosted.calls.get.count + cloud.calls.get.count + llm.calls.get.count
            + onDeviceSTT.calls.get.count + onDeviceLLM.calls.get.count
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
    let downloaded: Box<Bool>
    init(_ downloaded: Box<Bool>) { self.downloaded = downloaded }
    var isDownloaded: Bool { downloaded.get }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        downloaded.set(true)
        progress(1)
    }
}

struct FakeValidator: KeyValidating {
    let requests = Box<[KeyValidation]>([])
    func validate(_ request: KeyValidation) async -> KeyCheck {
        requests.update { $0.append(request) }
        if case .gemini(let key) = request, key.revealed == "bad" { return .rejected("Gemini API Key 無效") }
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

    init(_ configuration: RecorderConfiguration) throws {
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream()
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        try RecordingManifest(title: configuration.title, startedAt: Date(), platform: configuration.platform,
                              targetBundleID: configuration.targetBundleID).write(to: configuration.directory)
    }

    nonisolated func send(_ event: RecorderEvent) { continuation.yield(event) }

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
    let defaults: UserDefaults
    let now: Box<Date>
    let app: AppController

    /// `endCountdown` is zero unless a test is about the countdown, so a meeting ending stops at once.
    init(keys: Bool = true, machine: MachineProfile = MachineProfile(isAppleSilicon: true, memoryBytes: 16 << 30),
         endCountdown: Duration = .zero) throws {
        root = try temporaryDirectory()
        defaults = UserDefaults(suiteName: "mm2t-tests-\(UUID().uuidString)")!
        if keys {
            try credentials.save("eleven-key", for: .elevenLabsAPIKey)
            try credentials.save("gemini-key", for: .geminiAPIKey)
        }
        let now = Box(Date(timeIntervalSince1970: 1_800_000_000))
        self.now = now
        app = try AppController(
            paths: AppPaths(root: root), defaults: defaults, credentials: credentials, catalog: catalog,
            recorder: recorder, permissions: permissions, installer: FakeInstaller(catalog.modelsDownloaded),
            offlineInstallers: catalog.offlineDownloaded.mapValues(FakeInstaller.init),
            machine: machine, validator: validator, now: { now.get }, endCountdown: endCountdown)
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

