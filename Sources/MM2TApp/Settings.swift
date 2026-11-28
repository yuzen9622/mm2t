import Foundation
import MM2TCore
import MM2TProviders
import MM2TLocal
import Observation

public enum TranscriptionService: String, Codable, Sendable, CaseIterable {
    case mm2t, elevenLabs, server
}

public enum SummaryService: String, Codable, Sendable, CaseIterable {
    case mm2t, gemini, openAICompatible
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

public struct ServerConnectionDraft {
    public enum Kind: Sendable { case summaries, transcription }

    private let kind: Kind
    public var address: String {
        didSet { if Origin(oldValue) != Origin(address) { key = "" } }
    }
    public var key: String

    public init(kind: Kind, savedURL: URL? = nil, savedKey: String = "") {
        self.kind = kind
        address = savedURL?.absoluteString ?? ""
        key = Origin(address) == nil ? "" : savedKey
    }

    public var endpoint: URL? {
        switch kind {
        case .summaries: AppSettings.openAIBaseURL(from: address)
        case .transcription: AppSettings.selfHostedURL(from: address)
        }
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ address: String) {
            guard let url = AppSettings.selfHostedURL(from: address),
                  let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
            self.scheme = scheme
            self.host = host
            port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }
}

public enum RecordingMode: String, Codable, Sendable, CaseIterable {
    case online, inPerson
}

/// Everything the user configures except secrets, which live only in the Keychain.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Speakers are always told apart on this Mac. Settings saved by an older build may still hold a
    /// `diarizationOrder` that preferred the transcription service's speaker labels; it is ignored.
    public static let diarizationOrder: [DiarizationSource] = [.local]

    public var transcriptionService: TranscriptionService = .mm2t
    public var summaryService: SummaryService = .mm2t
    public var selfHostedURL: URL?
    /// Every term, in the order added. Sent to speech recognition as hints and to the cleanup as a glossary.
    public private(set) var vocabulary: [String] = []
    /// The subset of `vocabulary` learned from the user's transcript corrections.
    public private(set) var learnedVocabulary: [String] = []
    /// Learned terms the user deleted, so they are not learned again.
    public private(set) var dismissedVocabulary: [String] = []
    /// API root of the OpenAI-compatible server, e.g. `http://host:8000/v1`.
    public var openAIBaseURL: URL?
    public var openAIModel = ""
    private struct SpeechModels: Codable, Equatable, Sendable {
        var captions: LocalSpeechModel?
        var transcript: LocalSpeechModel?
    }
    private var speechModels = SpeechModels()
    var captionSources: [TranscriptionSource] {
        let remote: TranscriptionSource = switch transcriptionService {
        case .mm2t: .mm2t
        case .elevenLabs: .cloud
        case .server: .selfHosted
        }
        return captionSourceOrder.reduce(into: []) { sources, stored in
            let source = stored == .local ? .local : remote
            if !sources.contains(source) { sources.append(source) }
        }
    }
    private var captionSourceOrder: [TranscriptionSource] = [.mm2t, .local]

    mutating func initializeCaptionSources(for service: TranscriptionService) {
        switch service {
        case .elevenLabs: captionSourceOrder = [.local, .cloud]
        case .server: captionSourceOrder = [.local, .selfHosted]
        case .mm2t: captionSourceOrder = [.mm2t, .local]
        }
    }

    public var localCaptionModel: LocalSpeechModel? {
        get { speechModels.captions }
        set { speechModels.captions = newValue }
    }
    public var localSpeechModel: LocalSpeechModel? {
        get { speechModels.transcript }
        set { speechModels.transcript = newValue }
    }
    fileprivate mutating func preferLocalCaptions() {
        captionSourceOrder.removeAll { $0 == .local }
        captionSourceOrder.insert(.local, at: 0)
    }

    public var effectiveCaptionModel: LocalSpeechModel? { localCaptionModel ?? localSpeechModel }
    public var transcriptionLanguage: TranscriptionLanguage = .auto
    public var hasCompletedOnboarding = false
    /// Story 21: mm2t's windows stay out of screen shares, recordings and screenshots unless the
    /// user turns this off.
    public var hidesFromScreenCapture = true
    /// Display only: the saved transcript still comes from the recording.
    public var liveCaptions = false
    public var recordingMode: RecordingMode = .online
    /// Translates live captions on this Mac with the downloaded models; never saved.
    public var translationEnabled = false
    public var captionEngine: CaptionEngine = .initial
    public var captionTranslation: CaptionTranslation = .off
    /// Where the user dragged the caption bar, by screen (its display number as text): the bar's
    /// offset from its default place, in points.
    public var captionBarOffsets: [String: CaptionBarOffset] = [:]

    /// The global shortcut that starts a recording and stops it again.
    public var recordShortcut: Hotkey = .commandFn
    /// The global shortcut that starts hearing a spoken command for the shared meeting, and sends it.
    public var voiceCommandShortcut: Hotkey = .optionFn

    // MARK: Recording prompts
    /// Which apps and websites bring up the recording prompt, beyond and instead of the built-in
    /// lists in `DetectionPolicy`. Learned from the prompt's answers and edited in Settings.
    public var detectionRules = DetectionRules()

    public init() {}

    /// Missing keys take their defaults, so a settings blob written by an older build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let oldOrder = try legacy.decodeIfPresent([TranscriptionSource].self, forKey: .transcriptionOrder)
        selfHostedURL = try c.decodeIfPresent(URL.self, forKey: .selfHostedURL)
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? defaults.vocabulary
        learnedVocabulary = try c.decodeIfPresent([String].self, forKey: .learnedVocabulary) ?? []
        dismissedVocabulary = try c.decodeIfPresent([String].self, forKey: .dismissedVocabulary) ?? []
        openAIBaseURL = try c.decodeIfPresent(URL.self, forKey: .openAIBaseURL)
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        if let service = try c.decodeIfPresent(TranscriptionService.self, forKey: .transcriptionService) {
            transcriptionService = service
        } else {
            switch oldOrder?.first {
            case .selfHosted: transcriptionService = .server
            case .local: transcriptionService = selfHostedURL == nil ? .elevenLabs : .server
            case .mm2t: transcriptionService = .mm2t
            case .cloud, nil: transcriptionService = .elevenLabs
            }
        }
        if let service = try c.decodeIfPresent(SummaryService.self, forKey: .summaryService) {
            summaryService = service
        } else if try legacy.decodeIfPresent(String.self, forKey: .llmLocation) == "local" {
            summaryService = openAIBaseURL == nil ? .gemini : .openAICompatible
        } else {
            summaryService = try legacy.decodeIfPresent(SummaryService.self, forKey: .cloudLLM) ?? .gemini
        }
        if let choices = try c.decodeIfPresent(SpeechModels.self, forKey: .speechModels) {
            speechModels = choices
        } else {
            let chose = try legacy.decodeIfPresent(Bool.self, forKey: .hasChosenSpeechModel)
            if chose != false {
                let transcript = try legacy.decodeIfPresent(LocalSpeechModel.self, forKey: .localSpeechModel)
                let caption = try legacy.decodeIfPresent(LocalSpeechModel.self, forKey: .localCaptionModel)
                let oldLocal = transcript == nil && caption == nil && chose == nil && oldOrder?.contains(.local) == true
                localSpeechModel = transcript ?? (oldLocal ? .breezeCoreML : nil)
                localCaptionModel = caption
                // With the shared flag, choosing one model also exposed the other field's MLX default.
                if chose == true, effectiveCaptionModel != localSpeechModel, decoder.userInfo[Self.installedMLX] as? Bool == false {
                    if localCaptionModel == .breeze { localCaptionModel = nil }
                    if localSpeechModel == .breeze { localSpeechModel = nil }
                }
            }
        }
        transcriptionLanguage = try c.decodeIfPresent(TranscriptionLanguage.self, forKey: .transcriptionLanguage) ?? defaults.transcriptionLanguage
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        hidesFromScreenCapture = try c.decodeIfPresent(Bool.self, forKey: .hidesFromScreenCapture) ?? defaults.hidesFromScreenCapture
        recordingMode = try c.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .online
        liveCaptions = try c.decodeIfPresent(Bool.self, forKey: .liveCaptions) ?? defaults.liveCaptions
        if let order = try c.decodeIfPresent([TranscriptionSource].self, forKey: .captionSourceOrder) ?? oldOrder {
            captionSourceOrder = order
        } else {
            initializeCaptionSources(for: transcriptionService)
        }
        captionEngine = (try? c.decode(CaptionEngine.self, forKey: .captionEngine)) ?? .firefox
        captionTranslation = try c.decodeIfPresent(CaptionTranslation.self, forKey: .captionTranslation) ?? defaults.captionTranslation
        translationEnabled = try c.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? (captionTranslation != .off)
        captionBarOffsets = try c.decodeIfPresent([String: CaptionBarOffset].self, forKey: .captionBarOffsets) ?? [:]
        recordShortcut = try c.decodeIfPresent(Hotkey.self, forKey: .recordShortcut) ?? defaults.recordShortcut
        voiceCommandShortcut = try c.decodeIfPresent(Hotkey.self, forKey: .voiceCommandShortcut) ?? defaults.voiceCommandShortcut
        detectionRules = try c.decodeIfPresent(DetectionRules.self, forKey: .detectionRules) ?? defaults.detectionRules
    }

    fileprivate static let installedMLX = CodingUserInfoKey(rawValue: "mm2t.installedMLX")!
    private enum LegacyKeys: CodingKey {
        case transcriptionOrder, llmLocation, cloudLLM
        case hasChosenSpeechModel, localSpeechModel, localCaptionModel
    }

    private enum CodingKeys: String, CodingKey {
        case transcriptionService, selfHostedURL, vocabulary, learnedVocabulary, dismissedVocabulary
        case summaryService, hasCompletedOnboarding, hidesFromScreenCapture
        case openAIBaseURL, openAIModel, transcriptionLanguage, speechModels, recordShortcut, voiceCommandShortcut
        case detectionRules
        case recordingMode
        case liveCaptions, captionSourceOrder, captionBarOffsets, captionEngine, captionTranslation, translationEnabled
    }

    /// These settings with the ones that only change what is shown while recording set aside, so
    /// turning captions on mid-meeting does not count as a change to how the meeting is processed.
    public var forProcessing: AppSettings {
        var settings = self
        settings.liveCaptions = false
        settings.recordingMode = .online
        settings.speechModels = SpeechModels()
        settings.captionSourceOrder = []
        settings.translationEnabled = false
        settings.captionEngine = .initial
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
        didSet {
            for field in Self.modelFields where oldValue[keyPath: field] != settings[keyPath: field] {
                nativeSelections.removeValue(forKey: field)
            }
            save()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private static let modelFields = [\AppSettings.localCaptionModel, \AppSettings.localSpeechModel]
    @ObservationIgnored private var nativeSelections: [WritableKeyPath<AppSettings, LocalSpeechModel?>: LocalSpeechModel] = [:]
    public let machine: MachineProfile

    public init(defaults: UserDefaults = .standard, machine: MachineProfile = .current, installedMLX: Bool? = nil) {
        self.defaults = defaults
        self.machine = machine
        let decoder = JSONDecoder()
        if machine.isAppleSilicon { decoder.userInfo[AppSettings.installedMLX] = installedMLX }
        let stored = defaults.data(forKey: Self.key).flatMap { try? decoder.decode(AppSettings.self, from: $0) }
        var compatible = stored ?? AppSettings()
        if stored == nil, defaults.object(forKey: Self.key) != nil {
            compatible.transcriptionService = .elevenLabs
            compatible.summaryService = .gemini
        }
        if #unavailable(macOS 26), compatible.captionEngine == .apple {
            compatible.captionEngine = .firefox
            if let target = compatible.captionTranslation.target, !CaptionTarget.all.contains(target) {
                compatible.captionTranslation = .off
            }
        }
        for field in Self.modelFields {
            guard let choice = compatible[keyPath: field], !choice.isSupported(on: machine) else { continue }
            if machine.isTranslated { nativeSelections[field] = compatible[keyPath: field] }
            compatible[keyPath: field] = .whisperCPU
        }
        settings = compatible
    }

    func chooseSpeechModel(_ choice: LocalSpeechModel, for field: WritableKeyPath<AppSettings, LocalSpeechModel?>) {
        nativeSelections.removeValue(forKey: field)
        // Selecting the transcript model again restores the default link between the pickers.
        let transcript = nativeSelections[\.localSpeechModel] ?? settings.localSpeechModel
        var updated = settings
        if field == \.localCaptionModel { updated.preferLocalCaptions() }
        updated[keyPath: field] = field == \.localCaptionModel && choice == transcript ? nil : choice
        settings = updated
    }

    private func save() {
        var stored = settings
        for (field, choice) in nativeSelections { stored[keyPath: field] = choice }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(stored), defaults.data(forKey: Self.key) != data {
            defaults.set(data, forKey: Self.key)
        }
    }
}
