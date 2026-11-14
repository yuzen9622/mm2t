import FluidAudio
import Foundation
import MM2TCore

actor NemotronStreamingSession: StreamingDiarizationSession {
    private final class TrackState {
        let model: Nemotron3Diarizer
        var probabilities: [Float] = []
        var frames = 0
        var samples = 0
        var cache = VoiceprintCache()

        init(models: Nemotron3Models) {
            model = Nemotron3Diarizer(config: .offline, models: models)
        }

        func collect(_ chunks: [Nemotron3ChunkResult]) {
            for chunk in chunks {
                probabilities.append(contentsOf: chunk.probabilities)
                frames += chunk.frameCount
            }
        }

        var turns: [Diarization.Segment] {
            Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames,
                                       numSpeakers: model.config.numSpeakers).map {
                Diarization.Segment(cluster: ClusterID("S\($0.speakerIndex + 1)"),
                                    range: TimeRange(start: Double($0.startSeconds), end: Double($0.endSeconds)))
            }
        }

        var processedSeconds: TimeInterval { min(Double(frames) * 0.01, Double(samples) / 16_000) }
    }

    private let states: [Track: TrackState]
    private let embedder: WeSpeakerEmbedder
    private var finished = false
    private var failure: (any Error)?
    private var snapshotBusy = false
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []

    init(models: sending Nemotron3Models, embedder: WeSpeakerEmbedder) {
        states = Dictionary(uniqueKeysWithValues: Track.allCases.map { ($0, TrackState(models: models)) })
        self.embedder = embedder
    }

    func append(samples: [Float], track: Track) throws {
        if let failure { throw failure }
        guard !finished else { throw StreamingDiarizationError.finished }
        guard !samples.isEmpty, let state = states[track] else { return }
        try Task.checkCancellation()
        do {
            state.model.appendAudio(samples)
            state.samples += samples.count
            state.collect(try state.model.processBufferedAudio())
        } catch {
            failure = error
            throw error
        }
    }

    func processedSeconds() -> [Track: TimeInterval] {
        states.mapValues { settledSeconds($0) }
    }

    private func settledSeconds(_ state: TrackState) -> TimeInterval {
        // A short turn can cross the 0.2 s minimum on the next append, then bridge a
        // preceding 0.5 s pause. Keep that mutable boundary out of the public watermark.
        finished ? state.processedSeconds
            : max(0, state.processedSeconds - NemotronDiarizer.gapBridging - 0.2)
    }

    func snapshot(tracks: [Track: URL], final: Bool) async throws -> StreamingDiarizationSnapshot {
        // Actor reentrancy permits new audio while embeddings run, but snapshots must retain
        // their own frame watermark and may not race to replace each other's span caches.
        if snapshotBusy {
            await withCheckedContinuation { snapshotWaiters.append($0) }
        } else {
            snapshotBusy = true
        }
        defer {
            if snapshotWaiters.isEmpty { snapshotBusy = false }
            else { snapshotWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await makeSnapshot(tracks: tracks, final: final)
    }

    private func makeSnapshot(tracks: [Track: URL], final: Bool) async throws -> StreamingDiarizationSnapshot {
        if let failure { throw failure }
        if final, !finished {
            finished = true
            do {
                for track in Track.allCases {
                    guard let state = states[track] else { continue }
                    state.collect(try state.model.finishStream())
                }
            } catch {
                failure = error
                throw error
            }
        }
        let captured = Track.allCases.map { track in
            let state = states[track]!
            return (track, state.turns, settledSeconds(state), state.cache, state.samples)
        }
        var diarizations: [Track: Diarization] = [:]
        var processed: [Track: TimeInterval] = [:]
        for (track, turns, seconds, cache, samples) in captured {
            try Task.checkCancellation()
            processed[track] = seconds
            let segments = SpeakerTurns.bridgingGaps(turns, shorterThan: NemotronDiarizer.gapBridging)
            var kept: [ClusterID: [Embedding]] = [:]
            var brief: [ClusterID: [Embedding]] = [:]
            if samples > 0 {
                guard let url = tracks[track] else { throw StreamingDiarizationError.missingTrack(track) }
                let audio = try SpanAudioSource(url: url)
                guard audio.sampleCount >= (final ? samples : Int((seconds * 16_000).rounded())) else {
                    throw StreamingDiarizationError.incompleteAudio(track)
                }
                let result = try await embedder.incrementalVoiceprints(audio: audio, segments: turns, cache: cache)
                kept = result.kept
                brief = result.brief
                states[track]?.cache = result.cache
            }
            diarizations[track] = Diarization(segments: segments, overlaps: SpeakerTurns.overlaps(segments),
                                             embeddings: kept, briefEmbeddings: brief)
        }
        return StreamingDiarizationSnapshot(diarizations: diarizations, processedSeconds: processed)
    }
}
