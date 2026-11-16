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
}

/// What the footer's primary button does.
public enum OnboardingPrimary: Equatable, Sendable {
    case `continue`
    case start
}

/// A line under the footer buttons on the last screen while the models are not ready.
public enum OnboardingNote: Equatable, Sendable {
    /// Both downloads together, 0...1.
    case finishingDownloads(Double)
    case downloadFailed
}

/// Step order, what lets each step continue, and which way the screens travel. Settings and
/// downloads stay in their own models; this only reads them and applies the first screen's choice.
@MainActor @Observable
public final class OnboardingFlow {
    public private(set) var step: OnboardingStep = .usage
    /// Whether the latest step change went forward; back reverses the travel.
    public private(set) var forward = true
    public private(set) var choice: UsageChoice

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

    /// Shown under the buttons on the last screen when only the models hold it up.
    public var note: OnboardingNote? {
        guard step == .services, !modelsReady else { return nil }
        if case .failed = setup.models { return .downloadFailed }
        if case .failed = setup.translationModels { return .downloadFailed }
        return .finishingDownloads(modelProgress)
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

    /// What the last screen asks for, following the settings the choice wrote.
    public var services: [ServiceEntry] {
        let current = settings.settings
        var entries: [ServiceEntry] = []
        for source in current.transcriptionOrder {
            switch source {
            case .cloud: entries.append(.elevenLabs)
            case .selfHosted: entries.append(.transcriptionServer)
            case .local: break
            }
        }
        if current.llmLocation == .cloud {
            entries.append(current.cloudLLM == .gemini ? .gemini : .llmServer)
        }
        return entries
    }

    /// Setup issues the last screen's own fields do not already answer, and that are not the
    /// model downloads, which the footer reports.
    public var otherIssues: [SetupIssue] {
        let shown = Set(services)
        return setup.issues.filter { issue in
            switch issue {
            case .missingCredential(.elevenLabsAPIKey): !shown.contains(.elevenLabs)
            case .missingCredential(.geminiAPIKey): !shown.contains(.gemini)
            case .missingCredential(.selfHostedToken): !shown.contains(.transcriptionServer)
            case .missingCredential(.openAICompatibleAPIKey): !shown.contains(.llmServer)
            case .missingCredential: true
            case .missingSelfHostedURL: !shown.contains(.transcriptionServer)
            case .missingLLMEndpoint: !shown.contains(.llmServer)
            case .diarizationModelsMissing: false
            case .noTranscriptionSource, .offlineModelMissing: true
            }
        }
    }

    // MARK: Models

    public var modelsReady: Bool { setup.models == .downloaded && setup.translationModels == .downloaded }

    /// Both downloads in bytes, for "About N MB in total".
    public var modelBytes: Int64 { setup.speakerModelBytes + setup.translationModelBytes }

    /// Both downloads together, weighted by size, 0...1.
    public var modelProgress: Double {
        let total = Double(modelBytes)
        guard total > 0 else { return modelsReady ? 1 : 0 }
        return (Self.fraction(setup.models) * Double(setup.speakerModelBytes)
            + Self.fraction(setup.translationModels) * Double(setup.translationModelBytes)) / total
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
