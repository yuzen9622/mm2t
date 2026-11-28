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

    /// A 0.5 s gap split a real sentence at 224.69 s after a 0.93 s pause, dropping its quiet tail.
    /// At 1 s the tail shares the loud word's decision, both offline and in the live replay.
    static let runGap: TimeInterval = 1
    /// A 50 ms playback frame is active at −45 dBFS or louder.
    package static let activePlayback: Float = 3.16e-5
    /// Echo hallucinations can trail playback by up to one second (265.8 s after silence at 265.5 s).
    static let playbackLookback: TimeInterval = 1
    /// Check speaker evidence in the 10 seconds on either side of the run start.
    static let speakerContext: TimeInterval = 10
    /// Headphones lost at most 1 dB, while speakers lost 3 to 17 dB. Require a 2× energy ratio.
    static let speakerRatio: Float = 2
    /// Take the loudest 300 ms (six 50 ms frames), or the entire run if shorter.
    static let loudnessFrames = 6
    /// Residual echo measured −39 to −56 dBFS and real speech −14 to −31 dBFS. Split at −36 dBFS.
    static let quietRun: Float = 2.51e-4

    public let frameDuration: TimeInterval
    /// Mean square per frame.
    public let before: [Float]
    public let after: [Float]
    /// Playback mean square at the mic's timing; nil where echo was not profiled.
    public let remote: [Float?]
    package let linearAfter: [Float]


    public init(frameDuration: TimeInterval, before: [Float], after: [Float], remote: [Float]? = nil,
                linearAfter: [Float]? = nil) {
        self.init(frameDuration: frameDuration, before: before, after: after,
                  remoteFrames: remote?.map(Optional.some) ?? .init(repeating: 0, count: before.count),
                  linearAfter: linearAfter ?? after)
    }

    private init(frameDuration: TimeInterval, before: [Float], after: [Float], remoteFrames: [Float?], linearAfter: [Float]) {
        precondition(before.count == after.count && before.count == remoteFrames.count && before.count == linearAfter.count,
                     "EchoProfile needs all loudness tracks the same length")
        self.frameDuration = frameDuration
        self.before = before
        self.after = after
        self.remote = remoteFrames
        self.linearAfter = linearAfter
    }

    /// Whether what the mic heard over `range` was mostly the remote track played back.
    public func isEcho(_ range: TimeRange) -> Bool {
        guard frameDuration > 0, !before.isEmpty else { return false }
        let first = max(0, Int((range.start - Self.margin) / frameDuration))
        let last = min(before.count - 1, Int((range.end + Self.margin) / frameDuration))
        guard first <= last else { return false }
        let heard = before[first...last].reduce(0, +)
        let left = after[first...last].reduce(0, +)
        let linearLeft = linearAfter[first...last].reduce(0, +)
        return Self.isPlayback(heard: heard, left: left, linearLeft: linearLeft)
    }

    private static func isPlayback(heard: Float, left: Float, linearLeft: Float) -> Bool {
        // AEC3's suppressor can attenuate near-end speech in double-talk. Only
        // attribute that loss to playback if the render-aligned subtraction agrees.
        heard > 0 && heard >= echoRatio * max(left, linearLeft)
    }

    /// Whether a voice heard over all of `ranges` was the remote track played back: a person next
    /// to the mic lost 1 to 2 dB of their speech to the removal there, the speakers 8 to 17 dB.
    public func isEcho(_ ranges: [TimeRange]) -> Bool {
        guard frameDuration > 0 else { return false }
        var heard: Float = 0, left: Float = 0, linearLeft: Float = 0
        for range in ranges {
            let first = max(0, Int(range.start / frameDuration)), last = min(before.count, Int((range.end / frameDuration).rounded(.up)))
            guard first < last else { continue }
            heard += before[first..<last].reduce(0, +)
            left += after[first..<last].reduce(0, +)
            linearLeft += linearAfter[first..<last].reduce(0, +)
        }
        return Self.isPlayback(heard: heard, left: left, linearLeft: linearLeft)
    }

    /// Keep mic words that pass both the run loudness gate and the original per-word echo check.
    public func droppingEcho(from words: [TimedWord]) -> [TimedWord] {
        droppingEcho(from: words, word: \.self)
    }

    func droppingEcho<Word>(from entries: [Word], word: KeyPath<Word, TimedWord>) -> [Word] {
        let words = entries.map { $0[keyPath: word] }
        return wordRuns(words).flatMap { run in
            guard !run.isEcho else { return [Word]() }
            return run.indices.compactMap { index in
                let range = words[index].range
                if !isEcho(range) { return entries[index] }
                // A quiet final word may trail clear local speech. Keep it when its
                // evidence window overlaps the preceding retained word's window.
                guard index == run.indices.upperBound - 1, index > run.indices.lowerBound,
                      let peak = run.peak, peak >= Self.quietRun else { return nil }
                let preceding = words[index - 1].range
                guard range.start <= preceding.end + 2 * Self.margin,
                      range.duration <= Self.runGap, !isEcho(preceding) else { return nil }
                return entries[index]
            }
        }
    }

    package struct WordRun {
        package let indices: Range<Int>
        package let range: TimeRange
        package let playbackNearby: Bool
        package let speakerRatio: Float?
        package let peak: Float?

        package var isEcho: Bool {
            playbackNearby && (speakerRatio ?? 0) >= EchoProfile.speakerRatio && (peak ?? .infinity) < EchoProfile.quietRun
        }
    }

    package func wordRuns(_ words: [TimedWord], gap: TimeInterval = EchoProfile.runGap) -> [WordRun] {
        var runs: [WordRun] = []
        var first = 0
        while first < words.count {
            let start = words[first].range.start
            var end = words[first].range.end
            var next = first + 1
            while next < words.count, words[next].range.start <= end + gap {
                end = max(end, words[next].range.end)
                next += 1
            }
            runs.append(measureRun(first..<next, range: TimeRange(start: start, end: end)))
            first = next
        }
        return runs
    }

    private func active(_ frame: Int) -> Bool { (remote[frame] ?? 0) >= Self.activePlayback }

    private func speakerRatio(heard: Double, left: Double) -> Float? {
        left > 0 ? Float(heard / left) : (heard > 0 ? .infinity : nil)
    }

    /// One decision per profile frame, using only the linear fit on remote-active frames.
    package func speakerFrames() -> [Bool] {
        let reach = Int((Self.speakerContext / frameDuration).rounded())
        var heard: Double = 0, left: Double = 0
        var first = 0, last = 0
        return before.indices.map { frame in
            while last < min(before.count, frame + reach) {
                if active(last) { heard += Double(before[last]); left += Double(linearAfter[last]) }
                last += 1
            }
            while first < max(0, frame - reach) {
                if active(first) { heard -= Double(before[first]); left -= Double(linearAfter[first]) }
                first += 1
            }
            return (speakerRatio(heard: heard, left: left) ?? 0) >= Self.speakerRatio
        }
    }

    package func replacingCleanedEnergy(with cleaned: [Float]) -> EchoProfile {
        EchoProfile(frameDuration: frameDuration, before: before, after: cleaned,
                    remoteFrames: remote, linearAfter: linearAfter)
    }

    private func measureRun(_ indices: Range<Int>, range: TimeRange) -> WordRun {
        let nearby = frames(from: range.start - Self.playbackLookback, to: range.end + Self.margin, inclusiveEnd: true)
        var heard: Double = 0, left: Double = 0
        for frame in frames(from: range.start - Self.speakerContext, to: range.start + Self.speakerContext) where active(frame) {
            heard += Double(before[frame])
            left += Double(linearAfter[frame])
        }
        let ratio = speakerRatio(heard: heard, left: left)
        let span = frames(from: range.start, to: range.end, inclusiveEnd: range.start == range.end)
        let width = min(Self.loudnessFrames, span.count)
        var peak: Float?
        if width > 0, remote[span].allSatisfy({ $0 != nil }) {
            var sum = after[span.prefix(width)].reduce(0, +), loudest = sum
            for frame in span.dropFirst(width) {
                sum += after[frame] - after[frame - width]
                loudest = max(loudest, sum)
            }
            peak = loudest / Float(width)
        }
        return WordRun(indices: indices, range: range, playbackNearby: nearby.contains(where: active),
                       speakerRatio: ratio, peak: peak)
    }

    private func frames(from start: TimeInterval, to end: TimeInterval, inclusiveEnd: Bool = false) -> Range<Int> {
        guard frameDuration > 0 else { return 0..<0 }
        func gridPosition(_ time: TimeInterval) -> Double {
            let position = time / frameDuration
            let nearest = position.rounded()
            return abs(nearest - position) < 1e-9 ? nearest : position
        }
        let lower = gridPosition(start).rounded(.down)
        let position = gridPosition(end)
        let upper = inclusiveEnd ? position.rounded(.down) + 1 : position.rounded(.up)
        let first = Int(min(Double(before.count), max(0, lower)))
        let last = Int(min(Double(before.count), max(Double(first), upper)))
        return first..<last
    }

    /// `other` placed `time` seconds in; the gap before it counts as no echo.
    public func appending(_ other: EchoProfile, at time: TimeInterval) -> EchoProfile {
        let count = max(0, Int((time / frameDuration).rounded()) - before.count)
        let gap = [Float](repeating: 0, count: count)
        return EchoProfile(frameDuration: frameDuration, before: before + gap + other.before,
                           after: after + gap + other.after,
                           remoteFrames: remote + .init(repeating: nil, count: count) + other.remote,
                           linearAfter: linearAfter + gap + other.linearAfter)
    }
}

/// A mic track with the speakers' echo removed. The caller deletes `audio` or keeps it as the `PlaybackMic`.
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

/// The echo-free mic track kept beside a meeting's recording, so playback does not clean the whole
/// recording again each time the meeting is opened. An empty file records that the mic heard no
/// echo and plays as recorded.
public enum PlaybackMic {
    public static func url(beside mic: URL) -> URL {
        mic.deletingLastPathComponent().appending(path: "playback-mic.wav")
    }

    /// The track playback should use for `mic`; nil when none has been kept yet.
    public static func kept(beside mic: URL) -> URL? {
        let url = url(beside: mic)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return nil }
        return size > 0 ? url : mic
    }

    /// Moves `cleaned` into place, or records that there was no echo to remove when it is nil.
    public static func keep(_ cleaned: URL?, beside mic: URL) {
        let url = url(beside: mic)
        try? FileManager.default.removeItem(at: url)
        guard let cleaned else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return
        }
        // Staged beside its destination first: a move from another volume is a copy, and playback
        // must never find a track that is only partly there.
        let staged = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.moveItem(at: cleaned, to: staged)
            try FileManager.default.moveItem(at: staged, to: url)
        } catch {
            try? FileManager.default.removeItem(at: cleaned)
            try? FileManager.default.removeItem(at: staged)
        }
    }
}

public protocol Diarizer: Sendable {
    func diarize(track: URL) async throws -> Diarization
    func diarize(track: URL, on channel: VoiceChannel) async throws -> Diarization
}

extension Diarizer {
    public func diarize(track: URL, on channel: VoiceChannel) async throws -> Diarization {
        try await diarize(track: track)
    }
}

/// Voice vectors for speaker turns another source segmented, so voiceprints still match
/// when the local diarizer did not produce the segments.
public protocol SpeakerEmbedder: Sendable {
    /// Length of every vector it makes. Vectors of another length came from an earlier model.
    var dimensions: Int { get }
    func embeddings(track: URL, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]]
    /// `kept` are vectors to store and match by; `brief` are those of clusters with too little clean
    /// speech for that, which only a user's confirmation may store.
    func voiceprints(track: URL, segments: [Diarization.Segment], includingBrief: Bool) async throws
        -> (kept: [ClusterID: [Embedding]], brief: [ClusterID: [Embedding]])
}

extension SpeakerEmbedder {
    public func voiceprints(track: URL, segments: [Diarization.Segment], includingBrief: Bool) async throws
        -> (kept: [ClusterID: [Embedding]], brief: [ClusterID: [Embedding]]) {
        (try await embeddings(track: track, segments: segments), [:])
    }
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
    case mm2t
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
    /// The meeting's tracks are both transcribed; a metered provider closes what it held open for them.
    func finishSession(meeting: String) async
}

extension TranscriptionProvider {
    public func finishSession(meeting: String) async {}
}

/// Which meeting and track a `transcribe` call belongs to, for providers that meter per meeting.
/// Absent for one-off transcriptions such as voiceprint enrollment.
public struct TranscriptionContext: Sendable, Hashable {
    public let meeting: String
    public let track: Track
    public let recordingOffset: Int?
    public init(meeting: String, track: Track, recordingOffset: Int? = nil) {
        self.recordingOffset = recordingOffset
        self.meeting = meeting
        self.track = track
    }

    @TaskLocal public static var current: TranscriptionContext?
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
    public let meetingStartedAt: Date?
    public let timeZoneIdentifier: String

    public init(transcript: LLMTranscript, prioritized: [LLMUtterance], meetingStartedAt: Date? = nil,
                timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.transcript = transcript
        self.prioritized = prioritized
        self.meetingStartedAt = meetingStartedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public protocol LLMProvider: Sendable {
    /// Pins completed background context once for a group of concurrently generated outputs.
    func forGeneration() async -> any LLMProvider
    func generateText(system: String, input: String) async throws -> String
    func streamText(system: String, input: String) -> AsyncThrowingStream<String, Error>
    func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess]
    func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript
    func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest]
    func summarize(_ request: SummaryRequest) async throws -> Summary
    /// One passage of the cleaned transcript rewritten the way `instruction` asks ("make it more polite").
    func rewrite(_ text: String, instruction: String) async throws -> String
    /// Learns only names and terminology the user actually corrected in this passage.
    func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection]
}

public struct RewriteUnsupported: Error, Sendable {
    public init() {}
}

extension LLMProvider {
    public func rewrite(_ text: String, instruction: String) async throws -> String { throw RewriteUnsupported() }
}

public extension LLMProvider {
    func forGeneration() async -> any LLMProvider { self }
    func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection] { [] }
}
