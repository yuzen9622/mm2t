import AppKit
import Foundation
import MM2TCore
import MM2TLocal
import MM2TProviders
import MM2TSystem
import Observation

public enum ModelService: String, CaseIterable, Identifiable, Sendable {
    case mm2t, elevenLabs, gemini, openAICompatible, transcriptionServer

    public var id: Self { self }
}

extension TranscriptionService {
    public var connection: ModelService {
        switch self {
        case .mm2t: .mm2t
        case .elevenLabs: .elevenLabs
        case .server: .transcriptionServer
        }
    }
}

extension SummaryService {
    public var connection: ModelService {
        switch self {
        case .mm2t: .mm2t
        case .gemini: .gemini
        case .openAICompatible: .openAICompatible
        }
    }
}

public enum KeyState: Equatable, Sendable {
    case empty
    case saved
    case validating
    case checked(KeyCheck)
    /// The self-hosted token and the OpenAI-compatible key are checked against their server, so its URL must be set first.
    case needsServerURL
    case storageFailed(String)
}

/// One API key or token field: saves to the Keychain, never to UserDefaults, and validates on request.
@MainActor @Observable
public final class CredentialField: Identifiable {
    public let credential: Credential
    public var text = ""
    public private(set) var state: KeyState = .empty
    public private(set) var hasSavedValue = false
    public nonisolated var id: Credential { credential }

    @ObservationIgnored private let store: any CredentialStoring
    @ObservationIgnored private let validator: any KeyValidating
    @ObservationIgnored private let selfHostedURL: @MainActor () -> URL?
    @ObservationIgnored private let openAIEndpoint: @MainActor () -> (baseURL: URL, model: String)?

    public init(credential: Credential, store: any CredentialStoring, validator: any KeyValidating,
                selfHostedURL: @escaping @MainActor () -> URL?,
                openAIEndpoint: @escaping @MainActor () -> (baseURL: URL, model: String)? = { nil }) {
        self.credential = credential
        self.store = store
        self.validator = validator
        self.selfHostedURL = selfHostedURL
        self.openAIEndpoint = openAIEndpoint
        load()
    }

    public func load() {
        do {
            text = try store.read(credential)?.revealed ?? ""
            hasSavedValue = !text.isEmpty
            state = hasSavedValue ? .saved : .empty
        } catch {
            state = .storageFailed(String(describing: error))
        }
    }

    public func savedSecret() throws -> Secret? { try store.read(credential) }

    /// Saving an empty field deletes the stored key.
    public func save() {
        do {
            try store.save(Secret(text), for: credential)
            text = Secret(text).revealed
            hasSavedValue = !text.isEmpty
            state = hasSavedValue ? .saved : .empty
        } catch {
            state = .storageFailed(String(describing: error))
        }
    }

    public func validate() async {
        save()
        guard state == .saved else { return }
        let secret = Secret(text)
        let request: KeyValidation
        switch credential {
        case .elevenLabsAPIKey: request = .elevenLabs(secret)
        case .geminiAPIKey: request = .gemini(secret)
        case .selfHostedToken:
            guard let url = selfHostedURL() else {
                state = .needsServerURL
                return
            }
            request = .selfHosted(url: url, token: secret)
        case .openAICompatibleAPIKey:
            guard let endpoint = openAIEndpoint() else {
                state = .needsServerURL
                return
            }
            request = .openAICompatible(baseURL: endpoint.baseURL, apiKey: secret, model: endpoint.model)
        case .googleCalendarRefreshToken, .microsoftCalendarRefreshToken, .collabAccount:
            return  // Written by account sign-in, never typed into a key field.
        }
        state = .validating
        state = .checked(await validator.validate(request))
    }
}

public enum ModelDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case downloaded
    case failed(String)
}

/// The permissions and model the recorder and pipeline need (stories 12, 13).
public enum PermissionKind: String, CaseIterable, Sendable {
    case microphone
    case systemAudio
    case accessibility
    case automation

    public var pane: SettingsPane {
        switch self {
        case .microphone: .microphone
        case .systemAudio: .systemAudio
        case .accessibility: .accessibility
        case .automation: .automation
        }
    }
}

/// Onboarding and settings share this: permission states, the speaker-model download and key entry.
@MainActor @Observable
public final class SetupModel {
    public private(set) var microphone: PermissionState = .unknown
    public private(set) var systemAudio: PermissionState = .unknown
    public private(set) var accessibility: PermissionState = .unknown
    /// Automation per running browser; macOS can only answer for a running app.
    public private(set) var automation: [String: PermissionState] = [:]
    public private(set) var models: ModelDownloadState = .notDownloaded
    public private(set) var offlineModels: [OfflineModel: ModelDownloadState] = [:]
    /// The live caption translation models the chosen target language needs.
    public private(set) var translationModels: ModelDownloadState = .notDownloaded
    public let suitability: OfflineSuitability
    public private(set) var issues: [SetupIssue] = []
    public private(set) var preparingCoreML = false
    public private(set) var coreMLPreparationError: String?
    @ObservationIgnored private let prepareCoreML: @MainActor () async throws -> Void
    public let fields: [CredentialField]
    /// What the speaker model and the translation models each download from nothing.
    public var speakerModelBytes: Int64 { installer.downloadBytes }
    public var translationModelBytes: Int64 { selectedInstaller?.downloadBytes ?? 0 }
    /// The language captions are translated into; nil when translation is off and needs no models.
    public var translationTarget: CaptionTarget? {
        !settings.settings.translationEnabled || settings.settings.captionEngine == .apple ? nil : settings.settings.captionTranslation.target
    }

    private var selectedInstaller: (any ModelInstalling)? {
        installerTarget(for: settings.settings.captionEngine).flatMap { translationInstaller(settings.settings.captionEngine, $0) }
    }

    private func installerTarget(for engine: CaptionEngine) -> CaptionTarget? {
        switch engine {
        case .apple: nil
        case .hyMT2: .english // One shared model, even when translated captions are off.
        case .firefox: settings.settings.captionTranslation.target.flatMap { CaptionTarget.all.contains($0) ? $0 : nil }
        }
    }

    public func missingTranslationBytes(for engine: CaptionEngine) -> Int64? {
        guard let target = installerTarget(for: engine), let installer = translationInstaller(engine, target),
              !installer.isDownloaded else { return nil }
        return installer.downloadBytes
    }

    private struct DownloadKey: Hashable {
        let engine: CaptionEngine
        // Hy-MT2 has one file for all languages; Firefox installs per target.
        let target: CaptionTarget?
    }
    private var downloadKey: DownloadKey? {
        guard settings.settings.translationEnabled else { return nil }
        return installerTarget(for: settings.settings.captionEngine).map { DownloadKey(engine: settings.settings.captionEngine,
                                           target: settings.settings.captionEngine == .hyMT2 ? nil : $0) }
    }
    @ObservationIgnored private var downloadTasks: [DownloadKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadStates: [DownloadKey: ModelDownloadState] = [:]
    @ObservationIgnored private var lastDownload: Task<Void, Never>?
    public func offlineModelBytes(_ model: OfflineModel) -> Int64 { offlineInstallers[model]?.downloadBytes ?? 0 }

    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let installer: any ModelInstalling
    @ObservationIgnored private let offlineInstallers: [OfflineModel: any ModelInstalling]
    @ObservationIgnored private let translationInstaller: @MainActor (CaptionEngine, CaptionTarget) -> (any ModelInstalling)?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let runningBrowsers: @MainActor () -> [String]
    @ObservationIgnored private let checkSetup: @MainActor () -> [SetupIssue]

    public init(
        permissions: any PermissionsProviding,
        installer: any ModelInstalling,
        offlineInstallers: [OfflineModel: any ModelInstalling],
        translationInstaller: @escaping @MainActor (CaptionEngine, CaptionTarget) -> (any ModelInstalling)?,
        suitability: OfflineSuitability,
        credentials: any CredentialStoring,
        validator: any KeyValidating,
        settings: SettingsStore,
        runningBrowsers: @escaping @MainActor () -> [String],
        prepareCoreML: @escaping @MainActor () async throws -> Void = {},
        checkSetup: @escaping @MainActor () -> [SetupIssue]
    ) {
        self.settings = settings
        self.permissions = permissions
        self.installer = installer
        let supportedSpeech = LocalSpeechModel.allCases.filter { $0.isSupported(on: settings.machine) }
        let availableModels = Set(supportedSpeech.map(OfflineModel.init))
        self.offlineInstallers = offlineInstallers.filter { availableModels.contains($0.key) }
        self.translationInstaller = translationInstaller
        self.suitability = suitability
        self.runningBrowsers = runningBrowsers
        self.prepareCoreML = prepareCoreML
        self.checkSetup = checkSetup
        fields = [Credential.elevenLabsAPIKey, .geminiAPIKey, .selfHostedToken, .openAICompatibleAPIKey].map {
            CredentialField(credential: $0, store: credentials, validator: validator,
                            selfHostedURL: { settings.settings.selfHostedURL },
                            openAIEndpoint: {
                                settings.settings.openAIBaseURL.map { ($0, settings.settings.openAIModel) }
                            })
        }
        refresh()
    }

    public func field(_ credential: Credential) -> CredentialField {
        fields.first { $0.credential == credential }!
    }

    /// Re-reads every state without prompting; call when the app becomes active again, since
    /// the user grants permissions in System Settings.
    public func refresh() {
        refreshPermissions()
        if case .downloading = models {} else { models = installer.isDownloaded ? .downloaded : .notDownloaded }
        for (model, installer) in offlineInstallers {
            if case .downloading = offlineModels[model] { continue }
            if installer.isDownloaded {
                offlineModels[model] = .downloaded
            } else if case .failed = offlineModels[model] {
                continue
            } else {
                offlineModels[model] = .notDownloaded
            }
        }
        refreshTranslation()
        issues = checkSetup()
    }

    /// Cheap enough to poll while a permissions list is on screen: the user flips these switches in
    /// System Settings, and macOS sends no notification when they do.
    public func refreshPermissions() {
        let browsers = Dictionary(uniqueKeysWithValues: runningBrowsers().map { ($0, permissions.automation(of: $0)) })
        if microphone != permissions.microphone { microphone = permissions.microphone }
        if systemAudio != permissions.systemAudio { systemAudio = permissions.systemAudio }
        if accessibility != permissions.accessibility { accessibility = permissions.accessibility }
        if automation != browsers { automation = browsers }
    }

    public func requestMicrophone() async {
        _ = await permissions.requestMicrophone()
        refresh()
    }

    public func requestAccessibility() {
        permissions.requestAccessibility()
        refresh()
    }

    public func requestAutomation(of bundleID: String) async {
        automation[bundleID] = await permissions.requestAutomation(of: bundleID)
    }

    public func downloadModels() async {
        if case .downloading = models { return }
        models = .downloading(0)
        do {
            try await installer.download { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.models { self?.models = .downloading(fraction) }
                }
            }
            models = .downloaded
        } catch {
            models = .failed(String(describing: error))
        }
        issues = checkSetup()
    }

    /// After an update that changed a speaker model, fetches it when the rest was already set up,
    /// so speaker separation keeps working without a trip to setup.
    public var needsCompletingModels: Bool { installer.needsCompleting }

    public func completeModelsAfterUpdate() async {
        if installer.needsCompleting { await downloadModels() }
    }

    public func fit(for model: OfflineModel) -> OfflineFit {
        switch model {
        case .whisperCPU: .suited
        default: suitability.transcription
        }
    }

    public var speechModelChoices: [LocalSpeechModel] {
        let machine = settings.machine
        let showsCPU = !machine.isAppleSilicon || machine.isTranslated
            || settings.settings.localSpeechModel == .whisperCPU || settings.settings.localCaptionModel == .whisperCPU
        return LocalSpeechModel.allCases.filter {
            $0.isSupported(on: machine) && ($0 != .whisperCPU || showsCPU)
        }
    }

    /// Each use keeps its selection; both selectors share the same installer.
    @discardableResult
    public func selectSpeechModel(_ choice: LocalSpeechModel, for field: WritableKeyPath<AppSettings, LocalSpeechModel?>) -> Task<Void, Never> {
        guard choice.isSupported(on: settings.machine) else { return Task {} }
        settings.chooseSpeechModel(choice, for: field)
        recheck()
        return Task { await downloadOfflineModel(OfflineModel(choice)) }
    }

    /// Same as `downloadModels`, for one offline model; safe to call again after a failure, which resumes.
    public func downloadOfflineModel(_ model: OfflineModel) async {
        if case .downloading = offlineModels[model] { return }
        guard let installer = offlineInstallers[model] else { return }
        if installer.isDownloaded {
            offlineModels[model] = .downloaded
            if model == .breezeCoreML { await prepareInstalledCoreML() }
            return
        }
        offlineModels[model] = .downloading(0)
        do {
            try await installer.download { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.offlineModels[model] { self?.offlineModels[model] = .downloading(fraction) }
                }
            }
            offlineModels[model] = .downloaded
            if model == .breezeCoreML { await prepareInstalledCoreML() }
        } catch {
            offlineModels[model] = .failed(String(describing: error))
        }
        issues = checkSetup()
    }

    public func prepareInstalledCoreML() async {
        guard !preparingCoreML else { return }
        preparingCoreML = true
        coreMLPreparationError = nil
        defer { preparingCoreML = false }
        do { try await prepareCoreML() }
        catch { coreMLPreparationError = error.localizedDescription }
    }

    public func refreshTranslation() {
        guard let key = downloadKey, let installer = selectedInstaller else {
            translationModels = .notDownloaded
            return
        }
        translationModels = installer.isDownloaded ? .downloaded : downloadStates[key] ?? .notDownloaded
    }

    public func downloadTranslationModels() async {
        guard let key = downloadKey, let installer = selectedInstaller else { return }
        await download(key, installer: installer)
    }

    public func prepareTranscriptModel(engine: CaptionEngine, target: CaptionTarget) async -> Bool {
        guard settings.settings.translationEnabled else { return false }
        if engine == .apple { return true } // Language packs are prepared by the system translation session.
        guard let installer = translationInstaller(engine, target) else { return false }
        await download(DownloadKey(engine: engine, target: engine == .hyMT2 ? nil : target), installer: installer)
        return installer.isDownloaded
    }

    private func download(_ key: DownloadKey, installer: any ModelInstalling) async {
        if let existing = downloadTasks[key] { await existing.value; return }
        guard !installer.isDownloaded else { refreshTranslation(); return }
        let predecessor = lastDownload
        downloadStates[key] = .downloading(0)
        refreshTranslation()
        let task = Task { @MainActor in
            // Firefox targets can share files, so avoid two writers to a partial download.
            await predecessor?.value
            do {
                if !installer.isDownloaded {
                    try await installer.download { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, case .downloading = self.downloadStates[key] else { return }
                            self.downloadStates[key] = .downloading(fraction)
                            if self.downloadKey == key { self.translationModels = .downloading(fraction) }
                        }
                    }
                }
                downloadStates[key] = nil
            } catch {
                downloadStates[key] = .failed(String(describing: error))
            }
            downloadTasks[key] = nil
            if downloadTasks.isEmpty { lastDownload = nil }
            refreshTranslation()
        }
        downloadTasks[key] = task
        lastDownload = task
        await task.value
    }

    public func isConfigured(_ service: ModelService, signedIn: Bool) -> Bool {
        switch service {
        case .mm2t: signedIn
        case .elevenLabs: field(.elevenLabsAPIKey).hasSavedValue
        case .gemini: field(.geminiAPIKey).hasSavedValue
        case .openAICompatible: settings.settings.openAIBaseURL != nil
        case .transcriptionServer: settings.settings.selfHostedURL != nil
        }
    }

    /// Re-checks what processing still needs after the user changed keys or settings.
    public func recheck() {
        issues = checkSetup()
    }

    public static func openSettings(_ pane: SettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }
}
