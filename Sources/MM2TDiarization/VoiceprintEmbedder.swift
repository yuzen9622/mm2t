import FluidAudio
import Foundation
import MM2TCore

/// Voiceprints from 3D-Speaker's CAM++ (Mandarin, 200k speakers) through FluidAudio's
/// `CampPlusEmbedder`. Each speaker gets one vector, the mean over their single-speaker speech, or
/// none when that speech is shorter than `minimumSpeech`.
///
/// It replaced WeSpeaker on 2026-11-17: on far-field AliMeeting pieces its equal error rate against
/// others in the same meeting was 1.52% where WeSpeaker's was 4.95% (Evaluation/diarization/RESULTS.md).
public actor VoiceprintEmbedder: SpeakerEmbedder {
    /// Length of every vector it makes. Stored vectors of another length came from WeSpeaker and
    /// are what `VoiceprintMigration` replaces.
    public static let dimensions = CampPlusEmbedder.embeddingDim
    public nonisolated var dimensions: Int { Self.dimensions }

    /// A single 2-8 s piece is too unsteady to name anyone by; means over 8 s or more are what
    /// `MatchThresholds.campPlus` was measured on.
    public static let defaultMinimumSpeech: TimeInterval = 8

    public let models: DiarizationModels
    public let minimumSpeech: TimeInterval
    private var loaded: CampPlusEmbedder?

    public init(models: DiarizationModels, minimumSpeech: TimeInterval = VoiceprintEmbedder.defaultMinimumSpeech) {
        self.models = models
        self.minimumSpeech = minimumSpeech
    }

    public func embeddings(track: URL, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]] {
        try await voiceprints(track: track, segments: segments, includingBrief: false).kept
    }

    /// `kept` and `brief` for every cluster of `segments` on a recorded track.
    public func voiceprints(track: URL, segments: [Diarization.Segment], includingBrief: Bool) async throws
        -> (kept: [ClusterID: [Embedding]], brief: [ClusterID: [Embedding]]) {
        let audio = try TrackAudio(converting: track)
        defer { audio.remove() }
        return try await voiceprints(audio: audio, segments: segments, includingBrief: includingBrief)
    }

    /// Shortest piece a brief vector is built from. Nemotron cuts a turn at every pause, so
    /// conversation is mostly 1-2 s turns: a user who never spoke 2 s at a stretch left no vector
    /// at all, and shorter pieces of the user's own voice scored too low to tell them apart.
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
        if !missing.isEmpty {
            let campPlus = try await loadedModel()
            for (index, piece) in missing.enumerated() {
                try Task.checkCancellation()
                let count = piece.endSample - piece.startSample
                var samples = [Float](repeating: 0, count: count)
                try samples.withUnsafeMutableBufferPointer {
                    try audio.copySamples(into: $0.baseAddress!, offset: piece.startSample, count: count)
                }
                cache.insert(try await campPlus.embed(audio: samples), for: piece)
                if index % 32 == 31 { await Task.yield() }
            }
        }
        let result = cache.voiceprints(for: plan)
        return (result.kept, result.brief, cache)
    }

    private func loadedModel() async throws -> CampPlusEmbedder {
        if let loaded { return loaded }
        let model = CampPlusEmbedder(models: try models.loadCampPlus())
        loaded = model
        return model
    }
}
