import Accelerate
import FluidAudio
import Foundation
import MM2TCore

/// On-device speaker separation with FluidAudio's Nemotron-3-Diarization `offline` preset
/// (up to 8 speakers, 10 ms frames), the engine `Evaluation/diarization` chose.
///
/// The track streams through the model in 30 s blocks from a memory-mapped 16 kHz copy. For a
/// two-hour meeting that measured about 110 MB above the loaded models at peak, where passing the
/// whole file to `processComplete` measured 1.3 GB, at the same speed.
public actor NemotronDiarizer: MM2TCore.Diarizer, StreamingDiarizerFactory {
    /// Same-speaker pauses shorter than this join one turn; see `SpeakerTurns.bridgingGaps`.
    public static let gapBridging: TimeInterval = 0.5

    public let models: DiarizationModels
    public let embedder: VoiceprintEmbedder
    private var diarizer: Nemotron3Diarizer?

    public init(models: DiarizationModels, embedder: VoiceprintEmbedder) {
        self.models = models
        self.embedder = embedder
    }

    public func makeStreamingSession() async throws -> any StreamingDiarizationSession {
        // Each meeting gets its own model input/output backings. The session serializes both
        // tracks against those backings while keeping independent speaker histories.
        let loaded = try await models.loadNemotron()
        return NemotronStreamingSession(models: loaded, embedder: embedder)
    }

    /// Throws `DiarizationModelError.missing` when the models were never downloaded, so the
    /// pipeline falls back to STT speaker labels or an unseparated transcript.
    public func diarize(track: URL) async throws -> Diarization {
        try await diarize(track: track, on: .room)
    }

    public func diarize(track: URL, on channel: VoiceChannel) async throws -> Diarization {
        let model = try await loadedDiarizer()
        let audio = try TrackAudio(converting: track)
        defer { audio.remove() }

        let gain = channel == .call ? try RemoteDiarizationGain.measure(in: audio) : 1
        let turns = try Self.turns(of: audio, with: model, gain: gain)
        let segments = SpeakerTurns.bridgingGaps(turns, shorterThan: Self.gapBridging)
        // Voiceprints come from the unbridged turns, the spans the evaluation measured them on.
        let voiceprints = try await embedder.voiceprints(audio: audio, segments: turns, includingBrief: true)
        return Diarization(segments: segments, overlaps: SpeakerTurns.overlaps(segments),
                           embeddings: voiceprints.kept, briefEmbeddings: voiceprints.brief)
    }

    /// Raw model turns before post-processing, clusters named `S1`, `S2`, ... in arrival order.
    static func turns(of audio: any AudioSampleSource, with model: Nemotron3Diarizer,
                      gain: Float = 1) throws -> [Diarization.Segment] {
        let block = 30 * TrackAudio.sampleRate
        var probabilities: [Float] = []
        var frames = 0
        model.reset()
        for offset in stride(from: 0, to: audio.sampleCount, by: block) {
            try Task.checkCancellation()
            let count = min(block, audio.sampleCount - offset)
            let samples = try [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                let base = buffer.baseAddress!
                try audio.copySamples(into: base, offset: offset, count: count)
                if gain != 1 {
                    var scale = gain
                    vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(count))
                }
                initialized = count
            }
            model.appendAudio(samples)
            for chunk in try model.processBufferedAudio() {
                probabilities += chunk.probabilities
                frames += chunk.frameCount
            }
        }
        for chunk in try model.finishStream() {
            probabilities += chunk.probabilities
            frames += chunk.frameCount
        }
        return Nemotron3Diarizer.segments(
            probabilities: probabilities, frameCount: frames, numSpeakers: model.config.numSpeakers
        ).map {
            Diarization.Segment(
                cluster: ClusterID("S\($0.speakerIndex + 1)"),
                range: TimeRange(start: Double($0.startSeconds), end: Double($0.endSeconds)))
        }
    }

    private func loadedDiarizer() async throws -> Nemotron3Diarizer {
        if let diarizer { return diarizer }
        let loaded = Nemotron3Diarizer(config: .offline, models: try await models.loadNemotron())
        diarizer = loaded
        return loaded
    }
}
