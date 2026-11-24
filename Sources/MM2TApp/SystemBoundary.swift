import AppKit
import Foundation
import MM2TCore
import MM2TDiarization
import MM2TLocal
import MM2TProviders
import MM2TSystem

// The protocols here are the seams between app logic and the machine: audio hardware, TCC,
// the network and model files. Live conformances follow each protocol; tests script them.

// MARK: Recording

/// One running two-track recording.
public protocol RecordingSession: AnyObject, Sendable {
    var events: AsyncStream<RecorderEvent> { get }
    var elapsed: TimeInterval { get async }
    func pause() async
    func resume() async
    func markHighlight() async throws -> Highlight
    func stop() async throws -> Recording
    /// Both tracks mixed to mono at the recording's rate as they are captured, for live captions.
    func audioStream() async -> AsyncStream<[Float]>
}

public protocol Recorder: Sendable {
    func start(_ configuration: RecorderConfiguration) async throws -> any RecordingSession
}

extension AudioRecorder: RecordingSession {}

public struct LiveRecorder: Recorder {
    public init() {}
    public func start(_ configuration: RecorderConfiguration) async throws -> any RecordingSession {
        try await AudioRecorder.start(configuration)
    }
}

// MARK: Permissions

public protocol PermissionsProviding: Sendable {
    var microphone: PermissionState { get }
    func requestMicrophone() async -> Bool
    var systemAudio: PermissionState { get }
    var accessibility: PermissionState { get }
    func requestAccessibility()
    func automation(of bundleID: String) -> PermissionState
    func requestAutomation(of bundleID: String) async -> PermissionState
}

public struct LivePermissions: PermissionsProviding {
    public init() {}
    public var microphone: PermissionState { Permissions.microphone }
    public func requestMicrophone() async -> Bool { await Permissions.requestMicrophone() }
    public var systemAudio: PermissionState { Permissions.systemAudio }
    public var accessibility: PermissionState { Permissions.accessibility }
    public func requestAccessibility() { Permissions.requestAccessibility() }
    public func automation(of bundleID: String) -> PermissionState { Permissions.automation(of: bundleID) }
    public func requestAutomation(of bundleID: String) async -> PermissionState {
        await Task.detached { Permissions.requestAutomation(of: bundleID) }.value
    }
}

// MARK: Models

public protocol ModelInstalling: Sendable {
    var isDownloaded: Bool { get }
    /// What a download from nothing fetches, for the setup screen's total.
    var downloadBytes: Int64 { get }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Some of it is on disk and an update needs the rest, which the app then fetches on its own.
    var needsCompleting: Bool { get }
}

extension ModelInstalling {
    public var needsCompleting: Bool { false }
}

extension DiarizationModels: ModelInstalling {}

extension HyTranslationModels: ModelInstalling {}

extension TranslationModels: ModelInstalling {
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(configuration: .default, progress: progress)
    }
}

extension ModelSnapshot: ModelInstalling {
    public var downloadBytes: Int64 { approximateBytes }

    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(configuration: .default, progress: progress)
    }
}

// MARK: Providers

public final class LiveProviderCatalog: ProviderCatalog {
    public let models: DiarizationModels
    private let parakeet: ParakeetTranscription
    public let transcriptionModel: LocalTranscriptionModel
    public let translationModels: TranslationModels
    private let speakerModels: LocalSpeakerModels
    private let cpu: WhisperCPU
    private let coreML: LocalTranscription
    private let machine: MachineProfile
    private let transcription: BreezeMLX
    /// One for the app's lifetime, so a retried meeting reuses its lease and the pieces already sent.
    private let hostedLeases = HostedLeases(
        recall: { UserDefaults.standard.stringArray(forKey: "hostedPlanLeases") ?? [] },
        keep: { UserDefaults.standard.set($0, forKey: "hostedPlanLeases") })

    public init(models: DiarizationModels, transcriptionModel: LocalTranscriptionModel,
                translationModels: TranslationModels, machine: MachineProfile = .current) {
        self.machine = machine
        self.parakeet = ParakeetTranscription(directory: LocalSpeechModel.parakeet.snapshot(in: models.directory).directory)
        self.models = models
        self.transcriptionModel = transcriptionModel
        self.translationModels = translationModels
        cpu = WhisperCPU(folder: LocalSpeechModel.whisperCPU.snapshot(in: models.directory).directory)
        coreML = LocalTranscription(model: .breeze(in: models.directory))
        transcription = BreezeMLX(folder: transcriptionModel.snapshot.directory)
        let embedder = VoiceprintEmbedder(models: models)
        // One diarizer for the app's lifetime so the CoreML models load once, not per meeting.
        speakerModels = LocalSpeakerModels(diarizer: NemotronDiarizer(models: models, embedder: embedder), embedder: embedder)
    }

    public func cloudTranscription(apiKey: Secret, language: TranscriptionLanguage) -> any TranscriptionProvider {
        ElevenLabsScribe(apiKey: apiKey, languageCode: language.code)
    }
    public func selfHostedTranscription(url: URL, token: Secret?, language: TranscriptionLanguage) -> any TranscriptionProvider {
        SelfHostedTranscription(baseURL: url, token: token, languageCode: language.code)
    }
    public func hostedTranscription(url: URL, authorization: HostedAuthorization, language: TranscriptionLanguage) -> any TranscriptionProvider {
        HostedTranscription(baseURL: url, authorization: authorization, languageCode: language.code, leases: hostedLeases)
    }
    public func hostedLLM(url: URL, authorization: HostedAuthorization) -> any LLMProvider {
        OpenAICompatibleLLM(baseURL: url, apiKey: nil, model: "mm2t", authorization: authorization)
    }
    public func hostedCaptions(url: URL, authorization: HostedAuthorization, traditionalChinese: Bool) -> any StreamingTranscriptionProvider {
        HostedCaptions(url: url, authorization: authorization, traditionalChinese: traditionalChinese, leases: hostedLeases)
    }
    public func streamingTranscription(apiKey: Secret) -> any StreamingTranscriptionProvider {
        ElevenLabsRealtime(apiKey: apiKey)
    }
    /// An offline server fails its 3 s health check and the captions move to the next source.
    public func selfHostedStreamingTranscription(url: URL, token: Secret?) -> any StreamingTranscriptionProvider {
        WindowedStreamingTranscription(SelfHostedTranscription(baseURL: url, token: token, probeTimeout: 3, timeout: 30))
    }
    public func localStreamingTranscription(model: LocalSpeechModel, alongsideBreeze: Bool) -> (any StreamingTranscriptionProvider)? {
        guard model.isSupported(on: machine) else { return nil }
        switch model {
        case .whisperCPU: return model.snapshot(in: models.directory).isDownloaded ? WindowedStreamingTranscription(cpu) : nil
        case .breezeCoreML:
            return model.snapshot(in: models.directory).isDownloaded ? WindowedStreamingTranscription(coreML) : nil
        case .breeze:
            return transcriptionModel.snapshot.isDownloaded ? WindowedStreamingTranscription(transcription) : nil
        case .parakeet:
            guard model.snapshot(in: models.directory).isDownloaded else { return nil }
            return WindowedStreamingTranscription(parakeet)
        case .nemotron:
            let snapshot = model.snapshot(in: models.directory)
            return snapshot.isDownloaded ? NemotronTranscription(directory: snapshot.directory, cpuOnly: alongsideBreeze) : nil
        }
    }
    public func llm(apiKey: Secret) -> any LLMProvider { GeminiLLM(apiKey: apiKey) }
    public func openAICompatibleLLM(baseURL: URL, apiKey: Secret?, model: String) -> any LLMProvider {
        OpenAICompatibleLLM(baseURL: baseURL, apiKey: apiKey, model: model)
    }
    public func localSpeakerModels() -> LocalSpeakerModels? { models.isDownloaded ? speakerModels : nil }
    public func localTranscription(model: LocalSpeechModel, language: TranscriptionLanguage) -> (any TranscriptionProvider)? {
        guard model.isSupported(on: machine) else { return nil }
        switch model {
        case .whisperCPU: return model.snapshot(in: models.directory).isDownloaded ? cpu.speaking(language) : nil
        case .breezeCoreML: return model.snapshot(in: models.directory).isDownloaded ? coreML.speaking(language) : nil
        case .breeze: return transcriptionModel.snapshot.isDownloaded ? transcription.speaking(language) : nil
        case .parakeet:
            guard model.snapshot(in: models.directory).isDownloaded else { return nil }
            return parakeet
        case .nemotron:
            let snapshot = model.snapshot(in: models.directory)
            return snapshot.isDownloaded ? NemotronTranscription(directory: snapshot.directory, language: language.code) : nil
        }
    }
    /// A fresh translator per recording, so its model is freed when the recording's captions end.
    public func captionTranslator(for target: CaptionTarget, engine: CaptionEngine, source: CaptionLanguage?) async -> (any CaptionTranslator)? {
        switch engine {
        case .apple:
            guard await AppleCaptionTranslator.isInstalled(for: target, source: source) else { return nil }
            return AppleCaptionTranslator()
        case .firefox:
            let needed = translationModels.for(target)
            return CaptionTarget.all.contains(target) && needed.isDownloaded ? BergamotTranslator(models: needed) : nil
        case .hyMT2:
            let hy = HyTranslationModels(in: models.directory)
            return CaptionTarget.hyTargets.contains(target) && hy.isDownloaded ? HyCaptionTranslator(models: hy) : nil
        }
    }
    public var thresholds: MatchThresholds { .campPlus }
}

/// One "verify" press; the self-hosted token can only be checked against a configured server.
public enum KeyValidation: Hashable, Sendable {
    case hostedTranscription(url: URL, token: Secret)
    case hostedSummaries(url: URL, token: Secret)
    case elevenLabs(Secret)
    case gemini(Secret)
    case selfHosted(url: URL, token: Secret)
    /// `model` is only used when the server has no `/models` route and a one-token completion stands in.
    case openAICompatible(baseURL: URL, apiKey: Secret, model: String)
}

public protocol KeyValidating: Sendable {
    func validate(_ request: KeyValidation) async -> KeyCheck
}

public struct LiveKeyValidator: KeyValidating {
    private let session: URLSession
    private let account: CollabService?

    public init(session: URLSession = .shared, account: CollabService? = nil) {
        self.session = session
        self.account = account
    }

    private func authorization(_ token: Secret) -> HostedAuthorization {
        account.map { HostedAuthorization(stored: token, account: $0) } ?? .fixed(token)
    }

    public func validate(_ request: KeyValidation) async -> KeyCheck {
        switch request {
        case .hostedTranscription(let url, let token):
            await HostedTranscription.validateKey(baseURL: url, authorization: authorization(token), session: session)
        case .hostedSummaries(let url, let token):
            await OpenAICompatibleLLM(baseURL: url, apiKey: nil, model: "mm2t", session: session,
                                      authorization: authorization(token)).validateKey()
        case .elevenLabs(let key): await ElevenLabsScribe(apiKey: key).validateKey()
        case .gemini(let key): await GeminiLLM(apiKey: key).validateKey()
        case .selfHosted(let url, let token): await SelfHostedTranscription(baseURL: url, token: token).validateKey()
        case .openAICompatible(let url, let key, let model): await OpenAICompatibleLLM(baseURL: url, apiKey: key, model: model).validateKey()
        }
    }
}

// MARK: Apps the user can record

public struct RecordableApp: Hashable, Sendable, Identifiable {
    public let bundleID: String
    public let name: String
    public var id: String { bundleID }
    public var isBrowser: Bool { MeetingDetector.browsers.contains(bundleID) }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum RunningApps {
    /// Regular (Dock) apps other than this one, browsers and known meeting apps first.
    @MainActor public static func recordable() -> [RecordableApp] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RecordableApp? in
                guard let id = app.bundleIdentifier, id != own else { return nil }
                return RecordableApp(bundleID: id, name: app.localizedName ?? id)
            }
        return apps.sorted { ($0.isBrowser ? 0 : 1, $0.name) < ($1.isBrowser ? 0 : 1, $1.name) }
    }
}
