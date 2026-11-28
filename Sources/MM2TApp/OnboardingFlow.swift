import Foundation
import Observation

public enum OnboardingStep: Int, CaseIterable, Comparable, Sendable {
    case usage, services, permissions, models, voice

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum OnboardingChoice: String, CaseIterable, Sendable {
    case plan, ownKeys, ownServer

    public var transcription: TranscriptionService {
        switch self {
        case .plan: .mm2t
        case .ownKeys: .elevenLabs
        case .ownServer: .server
        }
    }

    public var summary: SummaryService {
        switch self {
        case .plan: .mm2t
        case .ownKeys: .gemini
        case .ownServer: .openAICompatible
        }
    }
}

public enum OnboardingPrimary: Equatable, Sendable {
    case `continue`, start
}

public enum OnboardingNote: Equatable, Sendable {
    case needsMicrophone, needsVoice
    case finishingDownloads(Double)
    case downloadFailed, modelsNotDownloaded
    case issue(SetupIssue)
}

@MainActor @Observable
public final class OnboardingFlow {
    public private(set) var step: OnboardingStep = .usage
    public private(set) var forward = true
    public private(set) var choice: OnboardingChoice = .ownKeys
    public private(set) var isOpenedAgain = false

    @ObservationIgnored private let setup: SetupModel
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let enrollment: VoiceEnrollmentModel
    @ObservationIgnored private let account: CollabAccount?

    public init(setup: SetupModel, settings: SettingsStore, enrollment: VoiceEnrollmentModel, account: CollabAccount? = nil) {
        self.setup = setup
        self.settings = settings
        self.enrollment = enrollment
        self.account = account
        step = firstIncompleteStep
    }

    private var repairsExistingSetup: Bool { settings.settings.hasCompletedOnboarding }
    private var transcription: TranscriptionService { repairsExistingSetup ? settings.settings.transcriptionService : choice.transcription }
    private var summary: SummaryService { repairsExistingSetup ? settings.settings.summaryService : choice.summary }

    public var services: [ModelService] {
        let speech = transcription.connection
        let text = summary.connection
        return speech == text ? [speech] : [speech, text]
    }

    public var firstIncompleteStep: OnboardingStep {
        guard repairsExistingSetup else { return .usage }
        return OnboardingStep.allCases.first { !isComplete($0) } ?? .voice
    }

    public func open() {
        isOpenedAgain = true
        reopen()
    }

    public func close() { isOpenedAgain = false }

    public func reopen() {
        choice = .ownKeys
        forward = true
        step = firstIncompleteStep
    }

    public func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .models: modelsReady
        default: canLeave(step)
        }
    }

    public func canLeave(_ step: OnboardingStep) -> Bool {
        switch step {
        case .usage, .models: true
        case .services:
            services.allSatisfy { setup.isConfigured($0, signedIn: account?.user != nil) }
                && (summary != .openAICompatible || !settings.settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .permissions: setup.microphone == .granted
        case .voice: enrollment.hasVoice && modelsReady && canLeave(.services)
        }
    }

    public var canContinue: Bool { canLeave(step) }
    public var canGoBack: Bool { step > (repairsExistingSetup ? .services : .usage) }
    public var primary: OnboardingPrimary { step == .voice ? .start : .continue }

    public var note: OnboardingNote? {
        guard !canContinue else { return nil }
        switch step {
        case .usage, .services, .models: return nil
        case .permissions: return .needsMicrophone
        case .voice:
            if isDownloading { return .finishingDownloads(modelProgress) }
            if case .failed = setup.models { return .downloadFailed }
            if requiresTranslationDownload, case .failed = setup.translationModels { return .downloadFailed }
            if let issue = setup.issues.first(where: { $0.service != nil }) { return .issue(issue) }
            return modelsReady ? .needsVoice : .modelsNotDownloaded
        }
    }

    @discardableResult
    public func advance() -> Bool {
        guard canContinue, let next = OnboardingStep(rawValue: step.rawValue + 1) else { return false }
        if step == .services, !repairsExistingSetup {
            var updated = settings.settings
            updated.transcriptionService = choice.transcription
            updated.initializeCaptionSources(for: choice.transcription)
            updated.summaryService = choice.summary
            settings.settings = updated
            setup.recheck()
        }
        forward = true
        step = next
        return true
    }

    public func back() {
        guard canGoBack, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        forward = false
        step = previous
    }

    public func select(_ choice: OnboardingChoice) { self.choice = choice }

    public var modelsReady: Bool {
        setup.models == .downloaded && (!requiresTranslationDownload || setup.translationModels == .downloaded)
    }

    /// Both downloads in bytes, for "About N MB in total"; translation counts only the chosen
    /// language's models, and nothing while translation is off.
    public var modelBytes: Int64 { setup.speakerModelBytes + (requiresTranslationDownload ? setup.translationModelBytes : 0) }

    /// Whether any download setup waits on is running.
    public var isDownloading: Bool {
        progressParts.contains { if case .downloading = $0.state { true } else { false } }
    }

    /// Every required download, weighted by size, from 0 to 1.
    public var modelProgress: Double {
        let parts = progressParts
        let total = parts.reduce(0) { $0 + Double($1.bytes) }
        guard total > 0 else { return modelsReady ? 1 : 0 }
        return parts.reduce(0) { $0 + Self.fraction($1.state) * Double($1.bytes) } / total
    }

    private var progressParts: [(state: ModelDownloadState, bytes: Int64)] {
        [(setup.models, setup.speakerModelBytes)]
            + (!requiresTranslationDownload ? [] : [(setup.translationModels, setup.translationModelBytes)])

    }

    public static func fraction(_ state: ModelDownloadState) -> Double {
        switch state {
        case .downloaded: 1
        case .downloading(let fraction): fraction
        case .notDownloaded, .failed: 0
        }
    }

    /// Starts whichever download has not begun; a failed one waits for its Retry. Returns when both end.
    private var requiresTranslationDownload: Bool {
        settings.settings.captionEngine == .firefox && setup.translationTarget != nil
    }

    public func startDownloads() async {
        let setup = setup
        let speakers = setup.models == .notDownloaded ? Task { await setup.downloadModels() } : nil
        let translation = requiresTranslationDownload && setup.translationModels == .notDownloaded
            ? Task { await setup.downloadTranslationModels() } : nil
        await speakers?.value
        await translation?.value
    }
}
