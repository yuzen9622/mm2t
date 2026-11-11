import Foundation
import MM2TCore
import MM2TProviders

/// Something the user has to configure before a meeting can be processed. The UI routes each
/// one to the setup screen that fixes it instead of letting processing fail midway.
public enum SetupIssue: Hashable, Sendable {
    case missingCredential(Credential)
    case missingSelfHostedURL
    case noTranscriptionSource
    case diarizationModelsMissing
    case offlineModelMissing(OfflineModel)
}

/// The on-device models behind the two offline switches, each downloaded separately.
public enum OfflineModel: String, Hashable, Sendable, CaseIterable {
    case transcription
    case llm
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
    func cloudTranscription(apiKey: Secret) -> any TranscriptionProvider
    func selfHostedTranscription(url: URL, token: Secret?) -> any TranscriptionProvider
    func llm(apiKey: Secret) -> any LLMProvider
    /// nil until the models are on disk.
    func localSpeakerModels() -> LocalSpeakerModels?
    /// nil until the model is on disk.
    func localTranscription() -> (any TranscriptionProvider)?
    /// nil until the model is on disk.
    func localLLM() -> (any LLMProvider)?
    var thresholds: MatchThresholds { get }
}

public enum PipelineBuild: Sendable {
    case ready(MeetingProcessingPipeline)
    case needsSetup([SetupIssue])
}

/// Turns settings and stored secrets into a pipeline, or into the list of what is missing.
public struct PipelineSetup: Sendable {
    public let library: MeetingLibrary
    public let voiceprints: VoiceprintStore
    public let credentials: any CredentialStoring
    public let catalog: any ProviderCatalog

    public init(library: MeetingLibrary, voiceprints: VoiceprintStore, credentials: any CredentialStoring, catalog: any ProviderCatalog) {
        self.library = library
        self.voiceprints = voiceprints
        self.credentials = credentials
        self.catalog = catalog
    }

    /// Throws only when the Keychain cannot be read.
    public func build(_ settings: AppSettings) throws -> PipelineBuild {
        var issues: [SetupIssue] = []
        var routes: [TranscriptionChain.Route] = []
        for source in settings.transcriptionOrder {
            switch source {
            case .cloud:
                if let key = try nonEmpty(.elevenLabsAPIKey) {
                    routes.append(.init(.cloud, catalog.cloudTranscription(apiKey: key)))
                } else {
                    issues.append(.missingCredential(.elevenLabsAPIKey))
                }
            case .selfHosted:
                if let url = settings.selfHostedURL {
                    routes.append(.init(.selfHosted, catalog.selfHostedTranscription(url: url, token: try nonEmpty(.selfHostedToken))))
                } else {
                    issues.append(.missingSelfHostedURL)
                }
            case .local:
                if let local = catalog.localTranscription() {
                    routes.append(.init(.local, local))
                } else {
                    issues.append(.offlineModelMissing(.transcription))
                }
            }
        }
        if settings.transcriptionOrder.isEmpty { issues.append(.noTranscriptionSource) }

        var llm: (any LLMProvider)?
        switch settings.llmLocation {
        case .cloud:
            if let key = try nonEmpty(.geminiAPIKey) { llm = catalog.llm(apiKey: key) } else { issues.append(.missingCredential(.geminiAPIKey)) }
        case .local:
            if let local = catalog.localLLM() { llm = local } else { issues.append(.offlineModelMissing(.llm)) }
        }

        let models = catalog.localSpeakerModels()
        if settings.diarizationOrder.contains(.local), models == nil { issues.append(.diarizationModelsMissing) }

        guard issues.isEmpty, let llm else { return .needsSetup(issues) }
        return .ready(MeetingProcessingPipeline(
            library: library, voiceprints: voiceprints,
            diarizer: models?.diarizer, embedder: models?.embedder,
            diarizationOrder: settings.diarizationOrder,
            transcription: TranscriptionChain(routes), llm: llm,
            thresholds: catalog.thresholds, vocabulary: settings.vocabulary))
    }

    private func nonEmpty(_ credential: Credential) throws -> Secret? {
        try credentials.read(credential).flatMap { $0.isEmpty ? nil : $0 }
    }
}
