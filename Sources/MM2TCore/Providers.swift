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
    /// Vectors of clusters that spoke too little for a voiceprint worth keeping. Good enough to
    /// tell whether such a cluster is the user; never stored.
    public let briefEmbeddings: [ClusterID: [Embedding]]

    public init(segments: [Segment], overlaps: [TimeRange], embeddings: [ClusterID: [Embedding]],
                briefEmbeddings: [ClusterID: [Embedding]] = [:]) {
        self.segments = segments
        self.overlaps = overlaps
        self.embeddings = embeddings
        self.briefEmbeddings = briefEmbeddings
    }
}

// MARK: Echo

/// How loud each short stretch of the mic track was before and after the speakers' echo of the
/// remote track was taken out of it.
public struct EchoProfile: Hashable, Sendable {
    /// A stretch that lost this much of its energy was the speakers, not someone in the room: 5 dB.
    /// On the user's two test recordings echo-only stretches lost 8 to 24 dB and room speech about 1.
    static let echoRatio: Float = 3.16
    /// Words are short, so the stretch judged reaches this far past each end.
    static let margin: TimeInterval = 0.15

    public let frameDuration: TimeInterval
    /// Mean square per frame.
    public let before: [Float]
    public let after: [Float]

    public init(frameDuration: TimeInterval, before: [Float], after: [Float]) {
        precondition(before.count == after.count, "EchoProfile needs both loudness tracks the same length")
        self.frameDuration = frameDuration
        self.before = before
        self.after = after
    }

    /// Whether what the mic heard over `range` was mostly the remote track played back.
    public func isEcho(_ range: TimeRange) -> Bool {
        guard frameDuration > 0, !before.isEmpty else { return false }
        let first = max(0, Int((range.start - Self.margin) / frameDuration))
        let last = min(before.count - 1, Int((range.end + Self.margin) / frameDuration))
        guard first <= last else { return false }
        let heard = before[first...last].reduce(0, +), left = after[first...last].reduce(0, +)
        return heard > 0 && heard >= Self.echoRatio * left
    }

    /// Whether a voice heard over all of `ranges` was the remote track played back: a person next
    /// to the mic lost 1 to 2 dB of their speech to the removal there, the speakers 8 to 17 dB.
    public func isEcho(_ ranges: [TimeRange]) -> Bool {
        guard frameDuration > 0 else { return false }
        var heard: Float = 0, left: Float = 0
        for range in ranges {
            let first = max(0, Int(range.start / frameDuration)), last = min(before.count, Int((range.end / frameDuration).rounded(.up)))
            guard first < last else { continue }
            heard += before[first..<last].reduce(0, +)
            left += after[first..<last].reduce(0, +)
        }
        return heard > 0 && heard >= Self.echoRatio * left
    }

    /// `other` placed `time` seconds in; the gap before it counts as no echo.
    public func appending(_ other: EchoProfile, at time: TimeInterval) -> EchoProfile {
        let gap = [Float](repeating: 0, count: max(0, Int((time / frameDuration).rounded()) - before.count))
        return EchoProfile(frameDuration: frameDuration,
                           before: before + gap + other.before, after: after + gap + other.after)
    }
}

/// A mic track with the speakers' echo removed. The caller deletes `audio` when done.
public struct CleanedMic: Sendable {
    public let audio: URL
    public let echo: EchoProfile
    public init(audio: URL, echo: EchoProfile) {
        self.audio = audio
        self.echo = echo
    }
}

public protocol MicCleaner: Sendable {
    /// nil when the remote track is silent, so the mic heard no echo of it.
    func clean(mic: URL, remote: URL) throws -> CleanedMic?
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

/// The language of the speech, as a hint to every transcription source.
public enum TranscriptionLanguage: String, Codable, Sendable, CaseIterable {
    /// The model detects it, which suits mixed Mandarin and English.
    case auto
    case chinese
    case english

    /// ISO 639-1; nil leaves detection to the provider.
    public var code: String? {
        switch self {
        case .auto: nil
        case .chinese: "zh"
        case .english: "en"
        }
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    /// The provider could not be reached; the fallback chain moves to the next source.
    case unreachable(String)
    /// Any other failure (bad key, rejected audio); the chain stops here.
    case failed(String)
}

extension TranscriptionError: CustomStringConvertible {
    /// The provider's own words, which is what a failed meeting shows.
    public var description: String {
        switch self {
        case .unreachable(let message), .failed(let message): message
        }
    }
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
    /// The user's vocabulary and known names: the spelling to prefer when speech recognition wrote a sound-alike.
    public var glossary: [String] = []
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
