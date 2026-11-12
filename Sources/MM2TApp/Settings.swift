import Foundation
import MM2TCore
import Observation

/// Where the four LLM tasks run. `.local` needs the on-device model downloaded first.
public enum LLMLocation: String, Codable, Sendable, CaseIterable {
    case cloud
    case local
}

/// Everything the user configures except secrets, which live only in the Keychain.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Tried in order; each one listed must be configured. The chain falls through only when a
    /// source is unreachable, as `TranscriptionChain` defines.
    public var transcriptionOrder: [TranscriptionSource] = [.cloud]
    public var selfHostedURL: URL?
    /// Every term, in the order added. Sent to speech recognition as hints and to the cleanup as a glossary.
    public private(set) var vocabulary: [String] = []
    /// The subset of `vocabulary` that mm2t added itself, from a meeting or from a correction.
    public private(set) var learnedVocabulary: [String] = []
    /// Learned terms the user deleted, so they are not learned again.
    public private(set) var dismissedVocabulary: [String] = []
    public var diarizationOrder: [DiarizationSource] = [.local, .transcription]
    public var llmLocation: LLMLocation = .cloud
    public var hasCompletedOnboarding = false

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
        diarizationOrder = try c.decodeIfPresent([DiarizationSource].self, forKey: .diarizationOrder) ?? defaults.diarizationOrder
        llmLocation = try c.decodeIfPresent(LLMLocation.self, forKey: .llmLocation) ?? defaults.llmLocation
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case transcriptionOrder, selfHostedURL, vocabulary, learnedVocabulary, dismissedVocabulary
        case diarizationOrder, llmLocation, hasCompletedOnboarding
    }

    /// Parses what the user typed; nil for anything that is not an http(s) URL with a host.
    public static func selfHostedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
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
