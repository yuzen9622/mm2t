import Foundation
import MM2TCore
import MM2TProviders
import Observation

/// First-run setup, one thing per screen, in this order.
public enum OnboardingStep: Int, CaseIterable, Comparable, Sendable {
    case usage
    case permissions
    case models
    case voice
    case services

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How the user wants to use mm2t, chosen on the first screen.
public enum UsageChoice: String, CaseIterable, Sendable {
    /// mm2t's own accounts; shown but not offered yet.
    case signIn
    /// ElevenLabs and Gemini with the user's keys.
    case ownKeys
    /// The user's own transcription server and OpenAI-compatible LLM server.
    case ownServer

    public var isAvailable: Bool { self != .signIn }
}

/// One row of the last screen, in the order it shows them.
public enum ServiceEntry: Hashable, Sendable {
    /// The ElevenLabs key.
    case elevenLabs
    /// The Gemini key.
    case gemini
    /// The self-hosted transcription server's address and its token.
    case transcriptionServer
    /// The OpenAI-compatible server's address, model name and key.
    case llmServer
    /// An on-device model a chosen source needs: downloaded here, or its source turned off.
    case offlineModel(OfflineModel)
    /// No transcription source is on; the row turns the chosen one back on.
    case transcriptionSource
    /// Something only Settings can fix; the row says what and opens Settings.
    case settings(SetupIssue)
}

/// What the footer's primary button does.
public enum OnboardingPrimary: Equatable, Sendable {
    case `continue`
    case start
}

/// The line under the footer buttons saying why the primary is disabled.
public enum OnboardingNote: Equatable, Sendable {
    case needsMicrophone
    case needsVoice
    /// Every model still downloading, together, 0...1.
    case finishingDownloads(Double)
    /// The speaker or translation model failed; its Retry is on the models screen.
    case downloadFailed
    /// The speaker or translation model has not started downloading.
    case modelsNotDownloaded
    /// What setup still needs, which a row on the last screen resolves.
    case issue(SetupIssue)
}

/// Step order, what lets each step continue, and which way the screens travel. Settings and
/// downloads stay in their own models; this only reads them and applies the first screen's choice.
@MainActor @Observable
public final class OnboardingFlow {
    public private(set) var step: OnboardingStep = .usage
    /// Whether the latest step change went forward; back reverses the travel.
    public private(set) var forward = true
    public private(set) var choice: UsageChoice
    /// The user opened setup again after finishing it, from a meeting or the menu bar.
    public private(set) var isOpenedAgain = false

    @ObservationIgnored private let setup: SetupModel
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let enrollment: VoiceEnrollmentModel

    public init(setup: SetupModel, settings: SettingsStore, enrollment: VoiceEnrollmentModel) {
        self.setup = setup
        self.settings = settings
        self.enrollment = enrollment
        choice = Self.choice(in: settings.settings)
        step = firstIncompleteStep
    }

    // MARK: Re-entry

    /// Where setup opens: the first screen whose requirement is not met. Before setup was ever
    /// finished that is the first screen, so the choice is made at least once.
    public var firstIncompleteStep: OnboardingStep {
        guard settings.settings.hasCompletedOnboarding else { return .usage }
        return OnboardingStep.allCases.first { !isComplete($0) } ?? .services
    }

    /// Opens setup again; it starts at its first incomplete screen.
    public func open() {
        isOpenedAgain = true
        reopen()
    }

    /// Leaves setup that was opened again.
    public func close() {
        isOpenedAgain = false
    }

    /// Starts over at the first incomplete screen, for each time the window opens.
    public func reopen() {
        choice = Self.choice(in: settings.settings)
        forward = true
        step = firstIncompleteStep
    }

    /// Whether a screen is done, for re-entry. Stricter than `canContinue` on the models screen,
    /// which lets the user go on while the downloads run.
    public func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .models: modelsReady
        default: canLeave(step)
        }
    }

    // MARK: Gating

    public func canLeave(_ step: OnboardingStep) -> Bool {
        switch step {
        case .usage: choice.isAvailable
        case .permissions: setup.microphone == .granted
        case .models: true
        case .voice: enrollment.hasVoice
        case .services: setup.issues.isEmpty && modelsReady
        }
    }

    public var canContinue: Bool { canLeave(step) }
    public var canGoBack: Bool { step != .usage }
    public var primary: OnboardingPrimary { step == .services ? .start : .continue }

    /// Why the primary is disabled; nil exactly when it is enabled.
    public var note: OnboardingNote? {
        guard !canContinue else { return nil }
        switch step {
        case .usage, .models: return nil  // Never held: a choice is always selected, downloads run on.
        case .permissions: return .needsMicrophone
        case .voice: return .needsVoice
        case .services: break
        }
        if isDownloading { return .finishingDownloads(modelProgress) }
        if case .failed = setup.models { return .downloadFailed }
        if case .failed = setup.translationModels { return .downloadFailed }
        if let issue = setup.issues.first(where: { $0 != .diarizationModelsMissing }) { return .issue(issue) }
        return .modelsNotDownloaded
    }

    // MARK: Travel

    /// Moves to the next screen; false on the last one, where the caller finishes setup instead.
    @discardableResult
    public func advance() -> Bool {
        guard canContinue, let next = OnboardingStep(rawValue: step.rawValue + 1) else { return false }
        forward = true
        step = next
        return true
    }

    public func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        forward = false
        step = previous
    }

    // MARK: First screen

    /// Picks how mm2t is used and writes it into the existing settings at once. Choosing what the
    /// settings already say changes nothing, so a setup reopened later keeps the user's own mix.
    public func select(_ choice: UsageChoice) {
        guard choice.isAvailable, choice != self.choice else { return }
        self.choice = choice
        guard Self.choice(in: settings.settings) != choice else { return }
        var new = settings.settings
        switch choice {
        case .signIn:
            return
        case .ownKeys:
            new.transcriptionOrder = [.cloud]
            new.llmLocation = .cloud
            new.cloudLLM = .gemini
        case .ownServer:
            new.transcriptionOrder = [.selfHosted]
            new.llmLocation = .cloud
            new.cloudLLM = .openAICompatible
        }
        settings.settings = new
        setup.recheck()
    }

    /// The choice the settings describe: a self-hosted server tried first means the user's own server.
    public static func choice(in settings: AppSettings) -> UsageChoice {
        settings.transcriptionOrder.first == .selfHosted ? .ownServer : .ownKeys
    }

    // MARK: Last screen

    /// What the last screen asks for: the rows the settings call for, then a row for every issue
    /// they leave unanswered, so no issue is ever shown without a way to resolve it there.
    public var services: [ServiceEntry] {
        Self.services(settings: settings.settings, issues: setup.issues)
    }

    public static func services(settings: AppSettings, issues: [SetupIssue]) -> [ServiceEntry] {
        var entries: [ServiceEntry] = []
        for source in settings.transcriptionOrder {
            switch source {
            case .cloud: entries.append(.elevenLabs)
            case .selfHosted: entries.append(.transcriptionServer)
            case .local: entries.append(.offlineModel(.transcription))
            }
        }
        switch settings.llmLocation {
        case .cloud: entries.append(settings.cloudLLM == .gemini ? .gemini : .llmServer)
        case .local: entries.append(.offlineModel(.llm))
        }
        for issue in issues {
            if let entry = entry(for: issue), !entries.contains(entry) { entries.append(entry) }
        }
        return entries
    }

    /// The row of the last screen that resolves `issue`; nil for the speaker model, which the
    /// models screen downloads and the footer note reports.
    public static func entry(for issue: SetupIssue) -> ServiceEntry? {
        switch issue {
        case .missingCredential(.elevenLabsAPIKey): .elevenLabs
        case .missingCredential(.geminiAPIKey): .gemini
        case .missingCredential(.selfHostedToken): .transcriptionServer
        case .missingCredential(.openAICompatibleAPIKey): .llmServer
        // Calendar sign-ins are never required for processing; should one be, Settings has it.
        case .missingCredential(.googleCalendarRefreshToken), .missingCredential(.microsoftCalendarRefreshToken): .settings(issue)
        case .missingSelfHostedURL: .transcriptionServer
        case .missingLLMEndpoint: .llmServer
        case .noTranscriptionSource: .transcriptionSource
        case .diarizationModelsMissing: nil
        case .offlineModelMissing(let model): .offlineModel(model)
        }
    }

    /// Turns an on-device source off the way its Settings switch does.
    public func turnOff(_ model: OfflineModel) {
        switch model {
        case .transcription:
            let enabled = Set(settings.settings.transcriptionOrder).subtracting([.local])
            settings.settings.transcriptionOrder = TranscriptionSource.allCases.filter(enabled.contains)
        case .llm:
            settings.settings.llmLocation = .cloud
        }
        setup.recheck()
    }

    /// Turns the chosen way of using mm2t's transcription source back on.
    public func turnOnTranscriptionSource() {
        settings.settings.transcriptionOrder = choice == .ownServer ? [.selfHosted] : [.cloud]
        setup.recheck()
    }

    // MARK: Models

    public var modelsReady: Bool { setup.models == .downloaded && setup.translationModels == .downloaded }

    /// Both downloads in bytes, for "About N MB in total".
    public var modelBytes: Int64 { setup.speakerModelBytes + setup.translationModelBytes }

    /// The on-device models the settings use.
    public var requiredOfflineModels: [OfflineModel] {
        let current = settings.settings
        return (current.transcriptionOrder.contains(.local) ? [.transcription] : [])
            + (current.llmLocation == .local ? [.llm] : [])
    }

    /// Whether any download setup waits on is running.
    public var isDownloading: Bool {
        progressParts.contains { if case .downloading = $0.state { true } else { false } }
    }

    /// Every download setup waits on, weighted by size, 0...1: both models, plus a required
    /// on-device model while it downloads.
    public var modelProgress: Double {
        let parts = progressParts
        let total = parts.reduce(0) { $0 + Double($1.bytes) }
        guard total > 0 else { return modelsReady ? 1 : 0 }
        return parts.reduce(0) { $0 + Self.fraction($1.state) * Double($1.bytes) } / total
    }

    private var progressParts: [(state: ModelDownloadState, bytes: Int64)] {
        [(setup.models, setup.speakerModelBytes), (setup.translationModels, setup.translationModelBytes)]
            + requiredOfflineModels.compactMap { model in
                let state = setup.offlineModels[model] ?? .notDownloaded
                guard case .downloading = state else { return nil }
                return (state, setup.offlineModelBytes(model))
            }
    }

    public static func fraction(_ state: ModelDownloadState) -> Double {
        switch state {
        case .downloaded: 1
        case .downloading(let fraction): fraction
        case .notDownloaded, .failed: 0
        }
    }

    /// Starts whichever download has not begun; a failed one waits for its Retry. Returns when both end.
    public func startDownloads() async {
        let setup = setup
        let speakers = setup.models == .notDownloaded ? Task { await setup.downloadModels() } : nil
        let translation = setup.translationModels == .notDownloaded ? Task { await setup.downloadTranslationModels() } : nil
        await speakers?.value
        await translation?.value
    }
}
