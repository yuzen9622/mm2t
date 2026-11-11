import Foundation

extension SpeakerID: CodingKeyRepresentable {
    public var codingKey: CodingKey { StringKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }
}

private struct StringKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

/// The persisted record of one meeting: recording, speakers, transcript, LLM outputs and processing state.
public struct Meeting: Codable, Hashable, Sendable, Identifiable {
    public let id: MeetingID
    public var metadata: MeetingMetadata
    public let audio: RecordingAudio
    public let highlights: [Highlight]

    /// Remote-track speakers only; the mic speaker is always `SpeakerID.me` and has no record.
    public internal(set) var speakers: [RemoteSpeaker] = []
    /// Speakers removed by a merge, mapped to the speaker they were merged into.
    public internal(set) var mergedSpeakers: [SpeakerID: SpeakerID] = [:]
    public internal(set) var remoteSegments: [SpeakerSegment] = []
    public internal(set) var attribution: SpeakerAttribution?
    public internal(set) var transcription: Transcription?
    public internal(set) var utterances: [Utterance] = []
    public internal(set) var suggestions = NameSuggestions()
    public internal(set) var outputs = LLMOutputs()
    public internal(set) var status: ProcessingStatus = .pending(next: .transcribe)

    init(id: MeetingID, metadata: MeetingMetadata, audio: RecordingAudio, highlights: [Highlight]) {
        self.id = id
        self.metadata = metadata
        self.audio = audio
        self.highlights = highlights.sorted { $0.time < $1.time }
    }

    public func speaker(_ id: SpeakerID) -> RemoteSpeaker? {
        speakers.first { $0.id == resolve(id) }
    }

    /// Follows merges so references kept in stale LLM outputs still land on a live speaker.
    public func resolve(_ id: SpeakerID) -> SpeakerID {
        var current = id
        while let next = mergedSpeakers[current] { current = next }
        return current
    }

    public func utterance(_ id: UtteranceID) -> Utterance? {
        utterances.first { $0.id == id }
    }

    /// Where the UI jumps to (and plays from) for an LLM output item.
    public func timeRange(of sources: [UtteranceID]) -> TimeRange? {
        let ranges = sources.compactMap { utterance($0)?.range }
        guard let start = ranges.map(\.start).min(), let end = ranges.map(\.end).max() else { return nil }
        return TimeRange(start: start, end: end)
    }

    public func isHighlighted(_ utterance: Utterance) -> Bool {
        highlights.contains { utterance.range.intersects($0.window) }
    }
}

public struct MeetingMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var platform: MeetingPlatform?

    public init(title: String, startedAt: Date, duration: TimeInterval, platform: MeetingPlatform? = nil) {
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.platform = platform
    }
}

/// File names inside the meeting's directory in the library.
public struct RecordingAudio: Codable, Hashable, Sendable {
    public let micFile: String
    public let remoteFile: String
}

/// A moment the user starred during recording.
public struct Highlight: Codable, Hashable, Sendable {
    public let time: TimeInterval
    public init(time: TimeInterval) { self.time = time }

    /// The user presses the star after hearing something, so the mark covers the speech just before it.
    static let lookback: TimeInterval = 20
    var window: TimeRange { TimeRange(start: max(0, time - Self.lookback), end: time + 1) }
}

public struct RemoteSpeaker: Codable, Hashable, Sendable, Identifiable {
    public let id: SpeakerID
    /// "A", "B", "C" in order of first appearance; shown while the speaker has no person.
    public let label: String
    public internal(set) var person: PersonID?
    public internal(set) var embeddings: [Embedding]
}

/// How remote speech was split into speakers and what that split can tell the UI.
public enum SpeakerAttribution: Codable, Hashable, Sendable {
    /// The local diarizer split the speakers and detected overlaps. A speaker with too little clean
    /// speech to embed gets no voiceprint, so it is neither matched nor written back on edits.
    case local(overlaps: [TimeRange])
    /// The STT's speaker labels split the speakers; nil `voiceprintsUnavailable` means the embedder ran.
    case transcription(voiceprintsUnavailable: Unavailable?)
    /// All remote speech sits under one unnamed speaker.
    case unseparated(Unavailable)

    public enum Unavailable: Codable, Hashable, Sendable {
        /// Nothing could run: no local model is configured, or the STT returned no speaker labels.
        case noSource
        /// The local model threw; `reason` is its error. Re-running separation may succeed.
        case failed(reason: String)
    }

    public var source: DiarizationSource? {
        switch self {
        case .local: .local
        case .transcription: .transcription
        case .unseparated: nil
        }
    }

    /// nil when the source cannot detect overlapping speech, which is not the same as none detected.
    public var overlaps: [TimeRange]? {
        if case .local(let overlaps) = self { return overlaps }
        return nil
    }

    /// false when no local model embedded the speakers: nothing is matched against or written to voiceprints.
    public var hasVoiceprints: Bool {
        switch self {
        case .local, .transcription(voiceprintsUnavailable: nil): true
        case .transcription, .unseparated: false
        }
    }
}

public struct SpeakerSegment: Codable, Hashable, Sendable {
    public let speaker: SpeakerID
    public let range: TimeRange
}

public struct Transcription: Codable, Hashable, Sendable {
    public let me: TrackTranscript
    public let remote: TrackTranscript
}

public struct TrackTranscript: Codable, Hashable, Sendable {
    /// The provider that actually produced the words after fallback.
    public let source: TranscriptionSource
    public let content: TranscribedWords

    public var words: [TimedWord] { content.words }
}

public struct Utterance: Codable, Hashable, Sendable, Identifiable {
    public let id: UtteranceID
    public internal(set) var speaker: SpeakerID
    public let range: TimeRange
    /// Another remote speaker talked at the same time, so attribution may be wrong. Always false
    /// when `Meeting.attribution` has no overlaps.
    public let isOverlapping: Bool
    public let text: String
    public let words: [TimedWord]

    public var track: Track { speaker == .me ? .me : .remote }
}

public struct NameSuggestion: Codable, Hashable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        /// Voiceprint similarity between the suggest and auto-name thresholds.
        case voiceprint(PersonID, similarity: Double)
        /// Inferred by the LLM from the conversation; `reason` may contain speaker mentions.
        case inferred(name: String, reason: String)
    }

    public let speaker: SpeakerID
    public let source: Source
}

public struct NameSuggestions: Codable, Hashable, Sendable {
    public internal(set) var items: [NameSuggestion] = []
    public internal(set) var isStale = false
}

/// Everything the LLM wrote. Speakers appear only as `SpeakerID`s or `SpeakerMention` tokens.
public struct LLMOutputs: Codable, Hashable, Sendable {
    public internal(set) var cleaned: CleanedTranscript?
    public internal(set) var digests: [PersonDigest]?
    public internal(set) var summary: Summary?
    /// Set by a merge; the user decides whether to regenerate.
    public internal(set) var isStale = false
}

public struct SourcedText: Codable, Hashable, Sendable {
    public let text: String
    public let sources: [UtteranceID]
    public init(text: String, sources: [UtteranceID]) {
        self.text = text
        self.sources = sources
    }
}

public struct CleanedTranscript: Codable, Hashable, Sendable {
    public struct Paragraph: Codable, Hashable, Sendable {
        public let speaker: SpeakerID
        public let text: String
        public let sources: [UtteranceID]
        public init(speaker: SpeakerID, text: String, sources: [UtteranceID]) {
            self.speaker = speaker
            self.text = text
            self.sources = sources
        }
    }

    public let paragraphs: [Paragraph]
    public init(paragraphs: [Paragraph]) { self.paragraphs = paragraphs }
}

public struct PersonDigest: Codable, Hashable, Sendable {
    public let speaker: SpeakerID
    public let points: [SourcedText]
    public init(speaker: SpeakerID, points: [SourcedText]) {
        self.speaker = speaker
        self.points = points
    }
}

public struct Summary: Codable, Hashable, Sendable {
    public struct ActionItem: Codable, Hashable, Sendable {
        public let text: String
        public let owner: SpeakerID?
        public let sources: [UtteranceID]
        public init(text: String, owner: SpeakerID?, sources: [UtteranceID]) {
            self.text = text
            self.owner = owner
            self.sources = sources
        }
    }

    /// One or two sentences for the meeting list; nil when the provider gave none.
    public let headline: String?
    public let decisions: [SourcedText]
    public let discussionPoints: [SourcedText]
    public let actionItems: [ActionItem]
    public init(headline: String? = nil, decisions: [SourcedText], discussionPoints: [SourcedText], actionItems: [ActionItem]) {
        self.headline = headline
        self.decisions = decisions
        self.discussionPoints = discussionPoints
        self.actionItems = actionItems
    }
}

/// How LLM free text refers to a speaker, e.g. `{{speaker:r2}}`; replaced with a name at render time.
public enum SpeakerMention {
    public static func token(_ id: SpeakerID) -> String { "{{speaker:\(id.rawValue)}}" }

    static func substitute(in text: String, name: (SpeakerID) -> String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{speaker:"), let close = rest[open.upperBound...].range(of: "}}") {
            result += rest[..<open.lowerBound]
            result += name(SpeakerID(String(rest[open.upperBound..<close.lowerBound])))
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}

public enum ProcessingStep: String, Codable, Sendable, CaseIterable, Comparable {
    case transcribe
    case diarize
    case matchVoiceprints
    case align
    case inferNames
    case cleanTranscript
    case digestPerPerson
    case summarize

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    var next: ProcessingStep? {
        let all = Self.allCases
        let i = all.firstIndex(of: self)! + 1
        return i < all.count ? all[i] : nil
    }
}

/// Steps before `next` (or before the failed step) are complete and their results are in the meeting.
public enum ProcessingStatus: Codable, Hashable, Sendable {
    case pending(next: ProcessingStep)
    case failed(step: ProcessingStep, reason: String)
    case completed

    public var resumeStep: ProcessingStep? {
        switch self {
        case .pending(let step), .failed(let step, _): step
        case .completed: nil
        }
    }

    public func isComplete(_ step: ProcessingStep) -> Bool {
        guard let resume = resumeStep else { return true }
        return step < resume
    }
}
