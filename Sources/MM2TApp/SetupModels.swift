import AppKit
import Foundation
import MM2TCore
import MM2TLocal
import MM2TProviders
import MM2TSystem
import Observation

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
            state = text.isEmpty ? .empty : .saved
        } catch {
            state = .storageFailed(String(describing: error))
        }
    }

    /// Saving an empty field deletes the stored key.
    public func save() {
        do {
            try store.save(Secret(text), for: credential)
            text = Secret(text).revealed
            state = text.isEmpty ? .empty : .saved
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
        case .googleCalendarRefreshToken, .microsoftCalendarRefreshToken:
            return  // Written by calendar sign-in, never typed into a key field.
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
    /// The on-device speech model and LLM behind the two offline switches.
    public private(set) var offlineModels: [OfflineModel: ModelDownloadState] = [:]
    /// Whether this Mac is suited to each offline option, for the hint next to its switch.
    public let suitability: OfflineSuitability
    public private(set) var issues: [SetupIssue] = []
    public let fields: [CredentialField]

    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let installer: any ModelInstalling
    @ObservationIgnored private let offlineInstallers: [OfflineModel: any ModelInstalling]
    @ObservationIgnored private let runningBrowsers: @MainActor () -> [String]
    @ObservationIgnored private let checkSetup: @MainActor () -> [SetupIssue]

    public init(
        permissions: any PermissionsProviding,
        installer: any ModelInstalling,
        offlineInstallers: [OfflineModel: any ModelInstalling],
        suitability: OfflineSuitability,
        credentials: any CredentialStoring,
        validator: any KeyValidating,
        settings: SettingsStore,
        runningBrowsers: @escaping @MainActor () -> [String],
        checkSetup: @escaping @MainActor () -> [SetupIssue]
    ) {
        self.permissions = permissions
        self.installer = installer
        self.offlineInstallers = offlineInstallers
        self.suitability = suitability
        self.runningBrowsers = runningBrowsers
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
        for model in OfflineModel.allCases {
            if case .downloading = offlineModels[model] { continue }
            offlineModels[model] = offlineInstallers[model]?.isDownloaded == true ? .downloaded : .notDownloaded
        }
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

    /// Same as `downloadModels`, for one offline model; safe to call again after a failure, which resumes.
    public func downloadOfflineModel(_ model: OfflineModel) async {
        if case .downloading = offlineModels[model] { return }
        guard let installer = offlineInstallers[model] else { return }
        offlineModels[model] = .downloading(0)
        do {
            try await installer.download { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.offlineModels[model] { self?.offlineModels[model] = .downloading(fraction) }
                }
            }
            offlineModels[model] = .downloaded
        } catch {
            offlineModels[model] = .failed(String(describing: error))
        }
        issues = checkSetup()
    }

    /// Re-checks what processing still needs after the user changed keys or settings.
    public func recheck() {
        issues = checkSetup()
    }

    public static func openSettings(_ pane: SettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }
}
