import Foundation
import MM2TCore
import MM2TProviders
import Observation

/// Where the four LLM tasks run. `.local` needs the on-device model downloaded first.
public enum LLMLocation: String, Codable, Sendable, CaseIterable {
    case cloud
    case local
}

/// Which hosted service runs the LLM tasks when `llmLocation` is `.cloud`.
public enum CloudLLM: String, Codable, Sendable, CaseIterable {
    case gemini
    /// The user's own OpenAI-compatible server (vLLM, Ollama, LM Studio, llama.cpp).
    case openAICompatible
}

/// Live captions translated on this Mac into one language, or not at all. Stored as the
/// language's id (`traditionalChinese`, `english` and the rest of `CaptionTarget.all`) or `off`;
/// an id this build does not know reads as off.
public struct CaptionTranslation: Codable, Hashable, Sendable {
    public let target: CaptionTarget?

    public init(_ target: CaptionTarget?) { self.target = target }

    public static let off = CaptionTranslation(nil)

    /// Off first, then every language in menu order.
    public static var allCases: [CaptionTranslation] { [.off] + CaptionTarget.all.map(CaptionTranslation.init) }

    public init(from decoder: Decoder) throws {
        target = (try? decoder.singleValueContainer().decode(String.self)).flatMap(CaptionTarget.with)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(target?.id ?? "off")
    }
}

/// Everything the user configures except secrets, which live only in the Keychain.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Speakers are always told apart on this Mac. Settings saved by an older build may still hold a
    /// `diarizationOrder` that preferred the transcription service's speaker labels; it is ignored.
    public static let diarizationOrder: [DiarizationSource] = [.local]

    /// Tried in order; each one listed must be configured. The chain falls through only when a
    /// source is unreachable, as `TranscriptionChain` defines.
    public var transcriptionOrder: [TranscriptionSource] = [.cloud]
    public var selfHostedURL: URL?
    /// Every term, in the order added. Sent to speech recognition as hints and to the cleanup as a glossary.
    public private(set) var vocabulary: [String] = []
    /// The subset of `vocabulary` learned from the user's transcript corrections.
    public private(set) var learnedVocabulary: [String] = []
    /// Learned terms the user deleted, so they are not learned again.
    public private(set) var dismissedVocabulary: [String] = []
    public var llmLocation: LLMLocation = .cloud
    public var cloudLLM: CloudLLM = .gemini
    /// API root of the OpenAI-compatible server, e.g. `http://host:8000/v1`.
    public var openAIBaseURL: URL?
    public var openAIModel = ""
    public var transcriptionLanguage: TranscriptionLanguage = .auto
    public var hasCompletedOnboarding = false
    /// Story 21: mm2t's windows stay out of screen shares, recordings and screenshots unless the
    /// user turns this off.
    public var hidesFromScreenCapture = true
    /// Live captions while recording, streamed to ElevenLabs; usable only with an ElevenLabs key.
    /// Display only: the saved transcript still comes from the recording.
    public var liveCaptions = false
    /// Translates live captions on this Mac with the downloaded models; never saved.
    public var captionTranslation: CaptionTranslation = .off
    /// Where the user dragged the caption bar, by screen (its display number as text): the bar's
    /// offset from its default place, in points.
    public var captionBarOffsets: [String: CaptionBarOffset] = [:]

    /// The global shortcut that starts a recording and stops it again.
    public var recordShortcut: Hotkey = .commandFn

    // MARK: Recording prompts
    /// Which apps and websites bring up the recording prompt, beyond and instead of the built-in
    /// lists in `DetectionPolicy`. Learned from the prompt's answers and edited in Settings.
    public var detectionRules = DetectionRules()

    public init() {}

    /// Missing keys take their defaults, so a settings blob written by an older build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        transcriptionOrder = try c.decodeIfPresent([TranscriptionSource].self, forKey: .transcriptionOrder) ?? defaults.transcriptionOrder
        selfHostedURL = try c.decodeIfPresent(URL.self, forKey: .selfHostedURL)
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? defaults.vocabulary
        learnedVocabulary = try c.decodeIfPresent([String].self, forKey: .learnedVocabulary) ?? []
        dismissedVocabulary = try c.decodeIfPresent([String].self, forKey: .dismissedVocabulary) ?? []
        llmLocation = try c.decodeIfPresent(LLMLocation.self, forKey: .llmLocation) ?? defaults.llmLocation
        cloudLLM = try c.decodeIfPresent(CloudLLM.self, forKey: .cloudLLM) ?? defaults.cloudLLM
        openAIBaseURL = try c.decodeIfPresent(URL.self, forKey: .openAIBaseURL)
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        transcriptionLanguage = try c.decodeIfPresent(TranscriptionLanguage.self, forKey: .transcriptionLanguage) ?? defaults.transcriptionLanguage
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        hidesFromScreenCapture = try c.decodeIfPresent(Bool.self, forKey: .hidesFromScreenCapture) ?? defaults.hidesFromScreenCapture
        liveCaptions = try c.decodeIfPresent(Bool.self, forKey: .liveCaptions) ?? defaults.liveCaptions
        captionTranslation = try c.decodeIfPresent(CaptionTranslation.self, forKey: .captionTranslation) ?? defaults.captionTranslation
        captionBarOffsets = try c.decodeIfPresent([String: CaptionBarOffset].self, forKey: .captionBarOffsets) ?? [:]
        recordShortcut = try c.decodeIfPresent(Hotkey.self, forKey: .recordShortcut) ?? defaults.recordShortcut
        detectionRules = try c.decodeIfPresent(DetectionRules.self, forKey: .detectionRules) ?? defaults.detectionRules
    }

    private enum CodingKeys: String, CodingKey {
        case transcriptionOrder, selfHostedURL, vocabulary, learnedVocabulary, dismissedVocabulary
        case llmLocation, hasCompletedOnboarding, hidesFromScreenCapture
        case cloudLLM, openAIBaseURL, openAIModel, transcriptionLanguage
        case recordShortcut
        case detectionRules
        case liveCaptions, captionBarOffsets, captionTranslation
    }

    /// These settings with the ones that only change what is shown while recording set aside, so
    /// turning captions on mid-meeting does not count as a change to how the meeting is processed.
    public var forProcessing: AppSettings {
        var settings = self
        settings.liveCaptions = false
        settings.captionTranslation = .off
        settings.captionBarOffsets = [:]
        return settings
    }

    /// Parses what the user typed; nil for anything that is not an http(s) URL with a host.
    public static func selfHostedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    /// Same parsing for the OpenAI-compatible server's API root.
    public static func openAIBaseURL(from text: String) -> URL? {
        selfHostedURL(from: text).map(OpenAICompatibleLLM.apiRoot)
    }

    public enum TermSource: Sendable { case manual, learned }

    public func source(of term: String) -> TermSource {
        learnedVocabulary.contains(term) ? .learned : .manual
    }

    /// Adds one term per line or comma. A term the user types is theirs from then on, even if it
    /// was learned or dismissed before; a learned term is skipped when known or dismissed.
    public mutating func addVocabulary(_ text: String, source: TermSource) {
        for term in text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" }).map({ $0.trimmingCharacters(in: .whitespaces) })
        where !term.isEmpty {
            let existing = vocabulary.first { Self.same($0, term) }
            switch source {
            case .manual:
                dismissedVocabulary.removeAll { Self.same($0, term) }
                if let existing { learnedVocabulary.removeAll { $0 == existing } } else { vocabulary.append(term) }
            case .learned:
                guard existing == nil, !dismissedVocabulary.contains(where: { Self.same($0, term) }) else { continue }
                vocabulary.append(term)
                learnedVocabulary.append(term)
            }
        }
    }

    public mutating func removeVocabulary(_ terms: [String]) {
        for term in terms { removeVocabulary(term) }
    }

    public mutating func removeVocabulary(_ term: String) {
        guard vocabulary.contains(term) else { return }
        vocabulary.removeAll { $0 == term }
        if learnedVocabulary.contains(term) {
            learnedVocabulary.removeAll { $0 == term }
            dismissedVocabulary.append(term)
        }
    }

    /// Replaces `term` in place with the user's spelling, which is theirs from then on. A learned
    /// spelling they corrected is dismissed so it is not learned again. Refuses an empty text and
    /// one that is already another term. Returns whether the term changed.
    @discardableResult
    public mutating func renameVocabulary(_ term: String, to text: String) -> Bool {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = vocabulary.firstIndex(of: term), !new.isEmpty, new != term,
              !vocabulary.contains(where: { $0 != term && Self.same($0, new) }) else { return false }
        vocabulary[index] = new
        if learnedVocabulary.contains(term) {
            learnedVocabulary.removeAll { $0 == term }
            if !Self.same(term, new) { dismissedVocabulary.append(term) }
        }
        dismissedVocabulary.removeAll { Self.same($0, new) }
        return true
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }
}

/// How far the caption bar was dragged from its default place on one screen, in points.
public struct CaptionBarOffset: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The language of the app's own UI. Stored the standard way, as `AppleLanguages` in the app's
/// own defaults domain, which macOS reads at launch; a change applies after a restart.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"

    public static let key = "AppleLanguages"

    /// What the app's own domain says; `.system` when it sets nothing and the Mac's order applies.
    /// `domain` is the defaults' persistent domain name: the bundle identifier for `.standard`.
    public static func current(in defaults: UserDefaults, domain: String) -> AppLanguage {
        guard let first = (defaults.persistentDomain(forName: domain)?[key] as? [String])?.first else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    public func save(in defaults: UserDefaults) {
        if self == .system { defaults.removeObject(forKey: Self.key) } else { defaults.set([rawValue], forKey: Self.key) }
    }
}

/// `AppSettings` persisted as one JSON value in UserDefaults; every change is saved immediately.
@MainActor @Observable
public final class SettingsStore {
    public static let key = "settings.v1"

    public var settings: AppSettings {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
