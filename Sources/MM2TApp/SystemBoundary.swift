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
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
}

extension DiarizationModels: ModelInstalling {}

extension ModelSnapshot: ModelInstalling {
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(configuration: .default, progress: progress)
    }
}

// MARK: Providers

public final class LiveProviderCatalog: ProviderCatalog {
    public let models: DiarizationModels
    public let transcriptionModel: LocalTranscriptionModel
    public let llmModel: LocalLLMModel
    private let speakerModels: LocalSpeakerModels
    private let transcription: LocalTranscription

    public init(models: DiarizationModels, transcriptionModel: LocalTranscriptionModel, llmModel: LocalLLMModel) {
        self.models = models
        self.transcriptionModel = transcriptionModel
        self.llmModel = llmModel
        // Kept for the app's lifetime like the diarizer: preparing the speech model for the Neural
        // Engine takes minutes, so it happens once per launch, on the first offline transcription.
        transcription = LocalTranscription(model: transcriptionModel)
        let embedder = WeSpeakerEmbedder(models: models)
        // One diarizer for the app's lifetime so the CoreML models load once, not per meeting.
        speakerModels = LocalSpeakerModels(diarizer: NemotronDiarizer(models: models, embedder: embedder), embedder: embedder)
    }

    public func cloudTranscription(apiKey: Secret, language: TranscriptionLanguage) -> any TranscriptionProvider {
        ElevenLabsScribe(apiKey: apiKey, languageCode: language.code)
    }
    public func selfHostedTranscription(url: URL, token: Secret?, language: TranscriptionLanguage) -> any TranscriptionProvider {
        SelfHostedTranscription(baseURL: url, token: token, languageCode: language.code)
    }
    public func llm(apiKey: Secret) -> any LLMProvider { GeminiLLM(apiKey: apiKey) }
    public func openAICompatibleLLM(baseURL: URL, apiKey: Secret?, model: String) -> any LLMProvider {
        OpenAICompatibleLLM(baseURL: baseURL, apiKey: apiKey, model: model)
    }
    public func localSpeakerModels() -> LocalSpeakerModels? { models.isDownloaded ? speakerModels : nil }
    public func localTranscription(language: TranscriptionLanguage) -> (any TranscriptionProvider)? {
        transcriptionModel.snapshot.isDownloaded ? transcription.speaking(language) : nil
    }
    /// A fresh provider per pipeline: the LLM loads in seconds, so it holds its gigabytes only
    /// while a meeting is being processed rather than while the app idles in the menu bar.
    public func localLLM() -> (any LLMProvider)? { llmModel.snapshot.isDownloaded ? LocalLLM(model: llmModel) : nil }
    public var thresholds: MatchThresholds { .weSpeaker }
}

/// One "verify" press; the self-hosted token can only be checked against a configured server.
public enum KeyValidation: Hashable, Sendable {
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
    public init() {}
    public func validate(_ request: KeyValidation) async -> KeyCheck {
        switch request {
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
