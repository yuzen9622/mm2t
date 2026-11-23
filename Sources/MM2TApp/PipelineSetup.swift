import Foundation
import MM2TCore
import MM2TProviders
import MM2TLocal
import MM2TSystem

/// Something the user has to configure before a meeting can be processed. The UI routes each
/// one to the setup screen that fixes it instead of letting processing fail midway.
public enum SetupIssue: Hashable, Sendable {
    case transcriptionServiceNotConfigured(TranscriptionService)
    case summaryServiceNotConfigured(SummaryService)
    case hostedPlanCheck(HostedPlanJob, String)
    case diarizationModelsMissing

    public var service: ModelService? {
        switch self {
        case .transcriptionServiceNotConfigured(let source): source.connection
        case .summaryServiceNotConfigured(let source): source.connection
        case .hostedPlanCheck: .mm2t
        case .diarizationModelsMissing: nil
        }
    }
}

public enum HostedPlanJob: String, CaseIterable, Sendable {
    case transcription = "stt"
    case summaries = "llm"
}

public enum OfflineModel: String, Hashable, Sendable, CaseIterable {
    case transcription, parakeet, nemotron, breezeCoreML, whisperCPU

    public init(_ speech: LocalSpeechModel) {
        switch speech {
        case .whisperCPU: self = .whisperCPU
        case .breezeCoreML: self = .breezeCoreML
        case .breeze: self = .transcription
        case .parakeet: self = .parakeet
        case .nemotron: self = .nemotron
        }
    }
}

public protocol CredentialStoring: Sendable {
    func read(_ credential: Credential) throws -> Secret?
    func save(_ secret: Secret, for credential: Credential) throws
}

extension KeychainCredentialStore: CredentialStoring {}

/// The on-device diarizer and embedder, or nothing when the models are not downloaded.
public struct LocalSpeakerModels: Sendable {
    public let diarizer: any Diarizer
    public let embedder: any SpeakerEmbedder
    public init(diarizer: any Diarizer, embedder: any SpeakerEmbedder) {
        self.diarizer = diarizer
        self.embedder = embedder
    }
}

/// Makes the providers behind the pipeline's interfaces. The live catalog builds the network
/// clients and the on-device models; tests substitute scripted ones.
public protocol ProviderCatalog: Sendable {
    func cloudTranscription(apiKey: Secret, language: TranscriptionLanguage) -> any TranscriptionProvider
    func selfHostedTranscription(url: URL, token: Secret?, language: TranscriptionLanguage) -> any TranscriptionProvider
    /// Live captions while recording; display only.
    func streamingTranscription(apiKey: Secret) -> any StreamingTranscriptionProvider
    func selfHostedStreamingTranscription(url: URL, token: Secret?) -> any StreamingTranscriptionProvider
    /// nil until the model is on disk.
    func localStreamingTranscription(model: LocalSpeechModel, alongsideBreeze: Bool) -> (any StreamingTranscriptionProvider)?
    func llm(apiKey: Secret) -> any LLMProvider
    func openAICompatibleLLM(baseURL: URL, apiKey: Secret?, model: String) -> any LLMProvider
    /// nil until the models are on disk.
    func localSpeakerModels() -> LocalSpeakerModels?
    func hostedTranscription(url: URL, authorization: HostedAuthorization, language: TranscriptionLanguage) -> any TranscriptionProvider
    func hostedLLM(url: URL, authorization: HostedAuthorization) -> any LLMProvider
    func localTranscription(model: LocalSpeechModel, language: TranscriptionLanguage) -> (any TranscriptionProvider)?
    /// Live caption translation into `target` on this Mac; nil until the models it needs are on disk.
    func captionTranslator(for target: CaptionTarget, engine: CaptionEngine, source: CaptionLanguage?) async -> (any CaptionTranslator)?
    var thresholds: MatchThresholds { get }
}

public enum PipelineBuild: Sendable {
    case ready(MeetingProcessingPipeline)
    case needsSetup([SetupIssue])
}

public enum LLMBuild: Sendable {
    case ready(any LLMProvider)
    case needsSetup([SetupIssue])
}

/// Turns settings and stored secrets into a pipeline, or into the list of what is missing.
public struct PipelineSetup: Sendable {
    public let library: MeetingLibrary
    public let voiceprints: VoiceprintStore
    public let credentials: any CredentialStoring
    public let catalog: any ProviderCatalog
    /// Renews the hosted token before it expires and after a 401; without it the stored token is used as is.
    public let account: CollabService?

    public init(library: MeetingLibrary, voiceprints: VoiceprintStore, credentials: any CredentialStoring,
                catalog: any ProviderCatalog, account: CollabService? = nil) {
        self.library = library
        self.voiceprints = voiceprints
        self.credentials = credentials
        self.catalog = catalog
        self.account = account
    }

    public static func hostedURL(_ apiURL: URL, job: String) -> URL {
        apiURL.appending(path: "v1/hosted").appending(component: job)
    }

    /// Throws only when the Keychain cannot be read.
    public func build(_ settings: AppSettings, accountURL: URL? = nil) throws -> PipelineBuild {
        var issues: [SetupIssue] = []
        let route = try transcriptionRoute(settings, accountURL: accountURL)
        if route == nil { issues.append(.transcriptionServiceNotConfigured(settings.transcriptionService)) }

        let llm: (any LLMProvider)?
        switch try buildLLM(settings, accountURL: accountURL) {
        case .ready(let provider): llm = provider
        case .needsSetup(let missing):
            llm = nil
            if settings.summaryService != .mm2t { issues += missing }
        }

        let models = catalog.localSpeakerModels()
        if models == nil { issues.append(.diarizationModelsMissing) }

        guard issues.isEmpty, let route, let models else { return .needsSetup(issues) }
        return .ready(MeetingProcessingPipeline(
            library: library, voiceprints: voiceprints,
            diarizer: models.diarizer, embedder: models.embedder,
            diarizationOrder: AppSettings.diarizationOrder,
            transcription: TranscriptionChain([route]), llm: llm,
            thresholds: catalog.thresholds, vocabulary: settings.vocabulary,
            runsConcurrently: true, transcribesConcurrently: true, micCleaner: EchoRemover()))
    }

    func transcriptionRoute(_ settings: AppSettings, accountURL: URL?) throws -> TranscriptionChain.Route? {
        let language = settings.transcriptionLanguage
        switch settings.transcriptionService {
        case .elevenLabs:
            guard let key = try nonEmpty(.elevenLabsAPIKey) else { return nil }
            return .init(.cloud, catalog.cloudTranscription(apiKey: key, language: language))
        case .server:
            guard let url = settings.selfHostedURL else { return nil }
            return .init(.selfHosted, catalog.selfHostedTranscription(url: url, token: try nonEmpty(.selfHostedToken), language: language))
        case .mm2t:
            guard let accountURL, let token = try accountToken(for: accountURL) else {
                guard let model = settings.localSpeechModel,
                      let local = catalog.localTranscription(model: model, language: language) else { return nil }
                return .init(.local, local)
            }
            return .init(.selfHosted, catalog.hostedTranscription(url: Self.hostedURL(accountURL, job: "stt"),
                                                                  authorization: authorization(token), language: language))
        }
    }

    public func buildCaptions(_ settings: AppSettings) -> StreamingTranscriptionChain? {
        let routes: [StreamingTranscriptionChain.Route] = settings.captionSources.compactMap { source in
            switch source {
            case .cloud:
                guard let key = try? nonEmpty(.elevenLabsAPIKey) else { return nil }
                return .init(.cloud, catalog.streamingTranscription(apiKey: key))
            case .selfHosted:
                guard let url = settings.selfHostedURL,
                      case .success(let token) = Result(catching: { try nonEmpty(.selfHostedToken) }) else { return nil }
                return .init(.selfHosted, catalog.selfHostedStreamingTranscription(url: url, token: token))
            case .local:
                guard let choice = settings.effectiveCaptionModel,
                      let local = catalog.localStreamingTranscription(model: choice, alongsideBreeze: false) else { return nil }
                return .init(.local, local)
            }
        }
        return routes.isEmpty ? nil : StreamingTranscriptionChain(routes)
    }

    /// Text-only tasks need the selected LLM, independently of recording and speaker setup.
    public func buildLLM(_ settings: AppSettings, accountURL: URL? = nil) throws -> LLMBuild {
        let llm: (any LLMProvider)?
        switch settings.summaryService {
        case .gemini:
            llm = try nonEmpty(.geminiAPIKey).map(catalog.llm(apiKey:))
        case .openAICompatible:
            let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = settings.openAIBaseURL, !model.isEmpty else {
                return .needsSetup([.summaryServiceNotConfigured(.openAICompatible)])
            }
            llm = catalog.openAICompatibleLLM(baseURL: url, apiKey: try nonEmpty(.openAICompatibleAPIKey), model: model)
        case .mm2t:
            if let accountURL, let token = try accountToken(for: accountURL) {
                llm = catalog.hostedLLM(url: Self.hostedURL(accountURL, job: "llm"), authorization: authorization(token))
            } else { llm = nil }
        }
        guard let llm else { return .needsSetup([.summaryServiceNotConfigured(settings.summaryService)]) }
        return .ready(llm)
    }

    func hostedChecks(_ settings: AppSettings, accountURL: URL?) -> [HostedPlanJob: KeyValidation] {
        guard let accountURL, let token = try? accountToken(for: accountURL) else { return [:] }
        var checks: [HostedPlanJob: KeyValidation] = [:]
        if settings.transcriptionService == .mm2t {
            checks[.transcription] = .hostedTranscription(url: Self.hostedURL(accountURL, job: HostedPlanJob.transcription.rawValue), token: token)
        }
        if settings.summaryService == .mm2t {
            checks[.summaries] = .hostedSummaries(url: Self.hostedURL(accountURL, job: HostedPlanJob.summaries.rawValue), token: token)
        }
        return checks
    }

    private func authorization(_ token: Secret) -> HostedAuthorization {
        account.map { HostedAuthorization(stored: token, account: $0) } ?? .fixed(token)
    }

    private func accountToken(for url: URL) throws -> Secret? {
        try nonEmpty(.collabAccount).flatMap { CollabService.storedAccessToken($0, for: url) }
    }

    private func nonEmpty(_ credential: Credential) throws -> Secret? {
        try credentials.read(credential).flatMap { $0.isEmpty ? nil : $0 }
    }
}
