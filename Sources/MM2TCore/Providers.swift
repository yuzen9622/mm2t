import Foundation

// MARK: Diarization

/// Diarizer-local cluster name; the pipeline maps clusters to stable `SpeakerID`s.
public struct ClusterID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct Diarization: Sendable {
    public struct Segment: Sendable {
        public let cluster: ClusterID
        public let range: TimeRange
        public init(cluster: ClusterID, range: TimeRange) {
            self.cluster = cluster
            self.range = range
        }
    }

    public let segments: [Segment]
    public let overlaps: [TimeRange]
    /// One or more vectors per cluster.
    public let embeddings: [ClusterID: [Embedding]]

    public init(segments: [Segment], overlaps: [TimeRange], embeddings: [ClusterID: [Embedding]]) {
        self.segments = segments
        self.overlaps = overlaps
        self.embeddings = embeddings
    }
}

public protocol Diarizer: Sendable {
    func diarize(track: URL) async throws -> Diarization
}

/// Voice vectors for speaker turns another source segmented, so voiceprints still match
/// when the local diarizer did not produce the segments.
public protocol SpeakerEmbedder: Sendable {
    func embeddings(track: URL, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]]
}

/// Where the remote track's who-spoke-when comes from.
public enum DiarizationSource: String, Codable, Sendable, CaseIterable {
    /// The on-device `Diarizer`.
    case local
    /// Per-word speaker labels from the remote track's transcription provider.
    case transcription
}

// MARK: Transcription

public enum TranscriptionSource: String, Codable, Sendable, CaseIterable {
    case selfHosted
    case cloud
    case local
}

public enum TranscriptionError: Error, Equatable, Sendable {
    /// The provider could not be reached; the fallback chain moves to the next source.
    case unreachable(String)
    /// Any other failure (bad key, rejected audio); the chain stops here.
    case failed(String)
}

/// A word with the provider's speaker label, e.g. Scribe's `speaker_0`. Labels are local to one file.
public struct LabeledWord: Hashable, Codable, Sendable {
    public let word: TimedWord
    public let speaker: ClusterID
    public init(_ word: TimedWord, speaker: ClusterID) {
        self.word = word
        self.speaker = speaker
    }
}

/// Labels cover every word of a track or none; an adapter whose provider labeled only some
/// words must choose one case rather than pass a partial labeling through.
public enum TranscribedWords: Hashable, Codable, Sendable {
    case unlabeled([TimedWord])
    case labeled([LabeledWord])

    public var words: [TimedWord] {
        switch self {
        case .unlabeled(let words): words
        case .labeled(let labeled): labeled.map(\.word)
        }
    }

    public var labeledWords: [LabeledWord]? {
        if case .labeled(let labeled) = self { labeled } else { nil }
    }
}

public protocol TranscriptionProvider: Sendable {
    /// Throws `TranscriptionError.unreachable` on connection failure so the chain can fall through.
    /// `labelSpeakers` is true only for the remote track; a provider that cannot diarize ignores it.
    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords
}

// MARK: LLM

/// One utterance as the LLM sees it. The LLM must refer to speakers by `speaker` id only.
public struct LLMUtterance: Hashable, Sendable {
    public let id: UtteranceID
    public let speaker: SpeakerID
    public let range: TimeRange
    public let text: String
    public let isHighlighted: Bool
}

public struct LLMTranscript: Hashable, Sendable {
    public let utterances: [LLMUtterance]
}

public struct NameInferenceRequest: Hashable, Sendable {
    public let transcript: LLMTranscript
    /// Speakers the LLM should try to name.
    public let unnamedSpeakers: [SpeakerID]
    /// Names already known in this meeting, so the LLM does not reuse them.
    public let knownNames: [SpeakerID: String]
}

public struct NameGuess: Hashable, Sendable {
    public let speaker: SpeakerID
    public let name: String
    public let reason: String
    public init(speaker: SpeakerID, name: String, reason: String) {
        self.speaker = speaker
        self.name = name
        self.reason = reason
    }
}

public struct SummaryRequest: Hashable, Sendable {
    public let transcript: LLMTranscript
    /// Highlighted utterances, listed first so the summary covers them.
    public let prioritized: [LLMUtterance]
}

public protocol LLMProvider: Sendable {
    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess]
    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript
    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest]
    func summarize(_ request: SummaryRequest) async throws -> Summary
}
