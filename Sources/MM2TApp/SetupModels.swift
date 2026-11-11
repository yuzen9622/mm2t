import AppKit
import Foundation
import MM2TCore
import MM2TProviders
import MM2TSystem
import Observation

public enum KeyState: Equatable, Sendable {
    case empty
    case saved
    case validating
    case checked(KeyCheck)
    /// The self-hosted token is checked against the server, so the URL must be set first.
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

    public init(credential: Credential, store: any CredentialStoring, validator: any KeyValidating,
                selfHostedURL: @escaping @MainActor () -> URL?) {
        self.credential = credential
        self.store = store
        self.validator = validator
        self.selfHostedURL = selfHostedURL
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
    public private(set) var accessibility: PermissionState = .unknown
    /// Automation per running browser; macOS can only answer for a running app.
    public private(set) var automation: [String: PermissionState] = [:]
    public private(set) var models: ModelDownloadState = .notDownloaded
    public private(set) var issues: [SetupIssue] = []
    public let fields: [CredentialField]

    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let installer: any ModelInstalling
    @ObservationIgnored private let runningBrowsers: @MainActor () -> [String]
    @ObservationIgnored private let checkSetup: @MainActor () -> [SetupIssue]

    public init(
        permissions: any PermissionsProviding,
        installer: any ModelInstalling,
        credentials: any CredentialStoring,
        validator: any KeyValidating,
        settings: SettingsStore,
        runningBrowsers: @escaping @MainActor () -> [String],
        checkSetup: @escaping @MainActor () -> [SetupIssue]
    ) {
        self.permissions = permissions
        self.installer = installer
        self.runningBrowsers = runningBrowsers
        self.checkSetup = checkSetup
        fields = [Credential.elevenLabsAPIKey, .geminiAPIKey, .selfHostedToken].map {
            CredentialField(credential: $0, store: credentials, validator: validator,
                            selfHostedURL: { settings.settings.selfHostedURL })
        }
        refresh()
    }

    public func field(_ credential: Credential) -> CredentialField {
        fields.first { $0.credential == credential }!
    }

    /// Re-reads every state without prompting; call when the app becomes active again, since
    /// the user grants permissions in System Settings.
    public func refresh() {
        microphone = permissions.microphone
        accessibility = permissions.accessibility
        automation = Dictionary(uniqueKeysWithValues: runningBrowsers().map { ($0, permissions.automation(of: $0)) })
        if case .downloading = models {} else { models = installer.isDownloaded ? .downloaded : .notDownloaded }
        issues = checkSetup()
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

    /// Re-checks what processing still needs after the user changed keys or settings.
    public func recheck() {
        issues = checkSetup()
    }

    public static func openSettings(_ pane: SettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }
}
