import FluidAudio
import Foundation
import MM2TCore

/// Voiceprints from FluidAudio's WeSpeaker model (pyannote community-1's embedding, via `embedSpans`).
/// Each speaker gets one vector, the mean over their single-speaker speech, or none when that
/// speech is shorter than `minimumSpeech`.
public actor WeSpeakerEmbedder: SpeakerEmbedder {
    /// A single 2-8 s piece is not enough: 9% of same-speaker scores fell below the 0.70 auto-name
    /// threshold. Means over 8 s or more of pieces kept every same-speaker score at 0.777 or above
    /// while no two different speakers passed 0.633, at any length (480 same-speaker and 11,040
    /// different-speaker trials over 24 Nemotron-3 clusters of the 8 AliMeeting `nearmix_opus`
    /// sessions, first half enrolled, second half matched). Length mostly decides whether someone
    /// is recognized; a short vector did not make a stranger look like a known person.
    public static let defaultMinimumSpeech: TimeInterval = 8

    public let models: DiarizationModels
    public let minimumSpeech: TimeInterval
    private var loaded: OfflineDiarizerModels?

    public init(models: DiarizationModels, minimumSpeech: TimeInterval = WeSpeakerEmbedder.defaultMinimumSpeech) {
        self.models = models
        self.minimumSpeech = minimumSpeech
    }

    public func embeddings(track: URL, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]] {
        let audio = try TrackAudio(converting: track)
        defer { audio.remove() }
        return try await voiceprints(audio: audio, segments: segments)
    }

    func voiceprints(audio: TrackAudio, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]] {
        let pieces = SpeakerTurns.cleanPieces(segments, within: audio.duration)
            .filter { $0.value.reduce(0) { $0 + $1.duration } >= minimumSpeech }
        guard !pieces.isEmpty else { return [:] }

        let owners = pieces.flatMap { cluster, ranges in ranges.map { (cluster, $0) } }
            .sorted { $0.1.start < $1.1.start }
        // A manager per call: it is not Sendable, and its async `embedSpans` leaves this actor.
        let manager = OfflineDiarizerManager()
        manager.initialize(models: try await loadedModels())
        // One `embedSpans` call keeps every Core ML output alive until it returns: about 550 MB
        // extra for a two-hour meeting. Batches with a suspension in between measured about 10 MB.
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: owners.count, by: 32) {
            let batch = owners[start..<min(start + 32, owners.count)]
            vectors += try await manager.embedSpans(audioSource: audio, spans: batch.map { $0.1.start..<$0.1.end })
            await Task.yield()
        }
        return Dictionary(grouping: zip(owners.map(\.0), vectors), by: \.0)
            .compactMapValues { pairs in SpeakerTurns.centroid(pairs.map(\.1)).map { [Embedding($0)] } }
    }

    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let loaded { return loaded }
        let models = try await models.loadWeSpeaker()
        loaded = models
        return models
    }
}
