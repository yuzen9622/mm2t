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
        return try await voiceprints(audio: audio, segments: segments, includingBrief: false).kept
    }

    /// Shortest piece a brief vector is built from. Nemotron cuts a turn at every pause, so
    /// conversation is mostly 1-2 s turns: a user who never spoke 2 s at a stretch left no vector
    /// at all. Means of 1-2.5 s pieces measured for `MatchThresholds.weSpeaker.user`; 0.7 s pieces
    /// of the user's own voice scored 0.23-0.38, so shorter is left out.
    public static let briefMinimumPiece: TimeInterval = 1

    /// `kept` are the voiceprints; `brief` are the vectors of speakers with at least one clean piece
    /// but under `minimumSpeech` of 2-8 s pieces, too unsteady to store or to name anyone by. Brief
    /// vectors also take pieces from `briefMinimumPiece`, enough to tell the user apart.
    func voiceprints(audio: TrackAudio, segments: [Diarization.Segment], includingBrief: Bool) async throws
        -> (kept: [ClusterID: [Embedding]], brief: [ClusterID: [Embedding]]) {
        let result = try await incrementalVoiceprints(audio: audio, segments: segments,
                                                     includingBrief: includingBrief, cache: VoiceprintCache())
        return (result.kept, result.brief)
    }

    func incrementalVoiceprints(audio: any AudioSampleSource, segments: [Diarization.Segment],
                                includingBrief: Bool = true, cache: VoiceprintCache) async throws
        -> (kept: [ClusterID: [Embedding]], brief: [ClusterID: [Embedding]], cache: VoiceprintCache) {
        let plan = VoiceprintPlan(segments: segments, duration: Double(audio.sampleCount) / 16_000,
                                  minimumSpeech: minimumSpeech, includingBrief: includingBrief)
        var cache = cache
        cache.retain(plan)
        let missing = cache.missing(in: plan)
        guard !missing.isEmpty else {
            let result = cache.voiceprints(for: plan)
            return (result.kept, result.brief, cache)
        }
        // A manager per call: it is not Sendable, and its async `embedSpans` leaves this actor.
        let manager = OfflineDiarizerManager()
        manager.initialize(models: try await loadedModels())
        // One `embedSpans` call keeps every Core ML output alive until it returns: about 550 MB
        // extra for a two-hour meeting. Batches with a suspension in between measured about 10 MB.
        for start in stride(from: 0, to: missing.count, by: 32) {
            try Task.checkCancellation()
            let batch = missing[start..<min(start + 32, missing.count)]
            let vectors = try await manager.embedSpans(audioSource: audio, spans: batch.map(\.span))
            for (piece, vector) in zip(batch, vectors) { cache.insert(vector, for: piece) }
            await Task.yield()
        }
        let result = cache.voiceprints(for: plan)
        return (result.kept, result.brief, cache)
    }

    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let loaded { return loaded }
        let models = try await models.loadWeSpeaker()
        loaded = models
        return models
    }
}
