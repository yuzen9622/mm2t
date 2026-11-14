import Foundation

/// A fresh session owns the speaker history of one recording, separately for each track.
public protocol StreamingDiarizerFactory: Sendable {
    func makeStreamingSession() async throws -> any StreamingDiarizationSession
}

public protocol StreamingDiarizationSession: Sendable {
    /// Consecutive, timeline-aligned mono samples at 16 kHz, including capture-gap silence.
    func append(samples: [Float], track: Track) async throws

    /// Reads the current settled watermarks without inference, embeddings or flushing input.
    /// An empty result means this implementation reports progress only through snapshots.
    func processedSeconds() async -> [Track: TimeInterval]

    /// Files contain the same samples as `append`, flushed as 16 kHz mono PCM. Only newly
    /// needed voiceprint spans are read. `final` flushes model lookahead once and ends input.
    func snapshot(tracks: [Track: URL], final: Bool) async throws -> StreamingDiarizationSnapshot
}

public extension StreamingDiarizationSession {
    func processedSeconds() async -> [Track: TimeInterval] { [:] }
}

public struct StreamingDiarizationSnapshot: Sendable {
    public let diarizations: [Track: Diarization]
    /// Only words ending at or before this watermark have complete diarization input and
    /// settled turn/gap post-processing. A final snapshot covers the complete input.
    public let processedSeconds: [Track: TimeInterval]

    public init(diarizations: [Track: Diarization], processedSeconds: [Track: TimeInterval]) {
        self.diarizations = diarizations
        self.processedSeconds = processedSeconds
    }
}

public enum StreamingDiarizationError: Error, Equatable, Sendable {
    case finished
    case missingTrack(Track)
    case incompleteAudio(Track)
}
