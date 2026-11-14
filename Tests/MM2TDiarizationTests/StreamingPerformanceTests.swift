import Foundation
import MM2TCore
import Testing
@testable import MM2TDiarization

/// Explicitly opt in with MM2T_STREAMING_MIC_AUDIO, MM2T_STREAMING_REMOTE_AUDIO and
/// MM2T_STREAMING_REPORT. MM2T_STREAMING_COMPARE_BATCH=1 also checks the same raw PCM against
/// batch processing. Models must already exist; this diagnostic never downloads or transcribes.
@Suite(.serialized, .enabled(if: StreamingPerformanceInputs.available,
    "requires explicit local audio/report paths and already-installed diarization models"))
struct StreamingPerformanceTests {
    @Test func acceleratedLocalDualTrackTailDiagnostic() async throws {
        let inputs = try #require(StreamingPerformanceInputs.current)
        let files = FileManager.default
        try files.createDirectory(at: inputs.report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let urls: [Track: URL] = [.me: inputs.mic, .remote: inputs.remote]
        let sources = try urls.mapValues { try SpanAudioSource(url: $0) }
        let counts = sources.mapValues(\.sampleCount)
        let shortest = try #require(counts.values.min())
        let longest = try #require(counts.values.max())
        try #require(shortest > 0, "both 16 kHz mono tracks must contain audio")
        let rate = 16_000
        // Recorder tracks can differ by a few samples. Preserve every sample in both tracks;
        // the longer track's tail includes that difference, and batch uses each original file.
        let prefillFrames = max(0, shortest - 20 * rate)
        var report = StreamingPerformanceReport(audioSeconds: Double(longest) / Double(rate),
            tailAudioSeconds: Double(longest - prefillFrames) / Double(rate),
            trackLengthDifferenceSeconds: Double(longest - shortest) / Double(rate))
        try report.write(to: inputs.report)
        let clock = ContinuousClock()
        let loadStart = clock.now
        let embedder = WeSpeakerEmbedder(models: inputs.models)
        let factory = NemotronDiarizer(models: inputs.models, embedder: embedder)
        let session = try await factory.makeStreamingSession()
        report.modelLoadWallSeconds = seconds(loadStart.duration(to: clock.now))
        let prefillStart = clock.now
        var offset = 0
        var nextSnapshot = 60 * rate
        while offset < prefillFrames {
            try Task.checkCancellation()
            let end = min(offset + 30 * rate, prefillFrames)
            for track in Track.allCases {
                let source = try #require(sources[track])
                try await session.append(samples: read(source, from: offset, count: end - offset), track: track)
            }
            offset = end
            if offset >= nextSnapshot {
                let started = clock.now
                let snapshot = try await session.snapshot(tracks: urls, final: false)
                report.checkpoints.append(.init(inputSeconds: Double(offset) / Double(rate),
                    processedSeconds: snapshot.processedSeconds.mapKeys(\.rawValue),
                    wallSeconds: seconds(started.duration(to: clock.now))))
                report.prefillWallSeconds = seconds(prefillStart.duration(to: clock.now))
                try report.write(to: inputs.report)
                if report.checkpoints.count.isMultiple(of: 5) {
                    print("[local component diagnostic] prefilling \(Int(Double(offset) / Double(rate))) s; wall \(report.prefillWallSeconds ?? 0) s")
                }
                nextSnapshot += 60 * rate
            }
        }
        report.prefillWallSeconds = seconds(prefillStart.duration(to: clock.now))
        report.prefillSinceLastCheckpointSeconds = Double(prefillFrames) / Double(rate)
            - (report.checkpoints.last?.inputSeconds ?? 0)
        report.status = "finalizing_local_tail"
        try report.write(to: inputs.report)

        let tailStart = clock.now
        for track in Track.allCases {
            let source = try #require(sources[track])
            try await session.append(samples: read(source, from: prefillFrames, count: source.sampleCount - prefillFrames), track: track)
        }
        report.tailAppendWallSeconds = seconds(tailStart.duration(to: clock.now))
        let finishStart = clock.now
        let final = try await session.snapshot(tracks: urls, final: true)
        report.tailFinalizeWallSeconds = seconds(finishStart.duration(to: clock.now))
        report.tailWallSeconds = seconds(tailStart.duration(to: clock.now))
        for track in Track.allCases {
            let actual = try #require(final.diarizations[track])
            let count = try #require(counts[track])
            #expect(final.processedSeconds[track] == Double(count) / Double(rate))
            report.tracks[track.rawValue] = .init(diarization: actual, audioSeconds: Double(count) / Double(rate),
                                                tailAudioSeconds: Double(count - prefillFrames) / Double(rate))
        }
        report.status = inputs.compareBatch ? "comparing_batch_locally" : "completed"
        try report.write(to: inputs.report)
        print("[local component diagnostic] two-track last \(report.tailAudioSeconds) s append + finalize: \(report.tailWallSeconds ?? 0) s; excludes STT, LLM, echo removal and application finalization")

        if inputs.compareBatch {
            for track in Track.allCases {
                let started = clock.now
                let expected = try await factory.diarize(track: try #require(urls[track]))
                let wall = seconds(started.duration(to: clock.now))
                let actual = try #require(final.diarizations[track])
                let duration = Double(try #require(counts[track])) / Double(rate)
                report.batchComparison[track.rawValue] = comparison(actual, expected, duration: duration, wall: wall)
                try report.write(to: inputs.report)
                print("[local component diagnostic] batch comparison completed for \(track.rawValue); wall \(wall) s")
            }
        }
        report.status = "completed"
        try report.write(to: inputs.report)
    }

    private func read(_ source: SpanAudioSource, from offset: Int, count: Int) throws -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        try samples.withUnsafeMutableBufferPointer {
            if let base = $0.baseAddress { try source.copySamples(into: base, offset: offset, count: count) }
        }
        return samples
    }

    private func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private func comparison(_ actual: Diarization, _ expected: Diarization, duration: Double,
                            wall: Double) -> StreamingPerformanceReport.Comparison {
        let actualVectors = actual.embeddings.merging(actual.briefEmbeddings, uniquingKeysWith: +)
        let expectedVectors = expected.embeddings.merging(expected.briefEmbeddings, uniquingKeysWith: +)
        var cosines: [Double] = []
        for (cluster, vectors) in expectedVectors {
            for (a, b) in zip(actualVectors[cluster] ?? [], vectors) { cosines.append(a.cosineSimilarity(to: b)) }
        }
        return .init(wallSeconds: wall,
            turnCount: expected.segments.count,
            exactSegments: actual.segments.elementsEqual(expected.segments) { $0.cluster == $1.cluster && $0.range == $1.range },
            frameAgreement: frameAgreement(actual.segments, expected.segments, to: duration),
            exactOverlaps: actual.overlaps == expected.overlaps,
            keptEmbeddingClustersMatch: Set(actual.embeddings.keys) == Set(expected.embeddings.keys),
            briefEmbeddingClustersMatch: Set(actual.briefEmbeddings.keys) == Set(expected.briefEmbeddings.keys),
            embeddingVectorCountsMatch: actualVectors.mapValues(\.count) == expectedVectors.mapValues(\.count),
            comparedEmbeddingVectors: cosines.count, minimumEmbeddingCosine: cosines.min())
    }
}

private struct StreamingPerformanceInputs {
    let mic: URL
    let remote: URL
    let report: URL
    let models: DiarizationModels
    let compareBatch: Bool

    static var current: Self? {
        let environment = ProcessInfo.processInfo.environment
        guard let mic = environment["MM2T_STREAMING_MIC_AUDIO"],
              let remote = environment["MM2T_STREAMING_REMOTE_AUDIO"],
              let report = environment["MM2T_STREAMING_REPORT"],
              !mic.isEmpty, !remote.isEmpty, !report.isEmpty else { return nil }
        let models = environment["MM2T_STREAMING_MODELS"].map { DiarizationModels(directory: URL(fileURLWithPath: $0)) }
            ?? .applicationSupport
        return Self(mic: URL(fileURLWithPath: mic), remote: URL(fileURLWithPath: remote), report: URL(fileURLWithPath: report),
                    models: models, compareBatch: environment["MM2T_STREAMING_COMPARE_BATCH"] == "1")
    }

    static var available: Bool { current?.models.isDownloaded == true }
}

private struct StreamingPerformanceReport: Encodable {
    struct Checkpoint: Encodable {
        let inputSeconds: Double
        let processedSeconds: [String: Double]
        let wallSeconds: Double
    }
    struct TrackSummary: Encodable {
        let audioSeconds: Double
        let tailAudioSeconds: Double
        let turnCount: Int
        let speakerCount: Int
        let overlapCount: Int
        let keptEmbeddingCount: Int
        let briefEmbeddingCount: Int

        init(diarization: Diarization, audioSeconds: Double, tailAudioSeconds: Double) {
            self.audioSeconds = audioSeconds
            self.tailAudioSeconds = tailAudioSeconds
            turnCount = diarization.segments.count
            speakerCount = Set(diarization.segments.map(\.cluster)).count
            overlapCount = diarization.overlaps.count
            keptEmbeddingCount = diarization.embeddings.values.reduce(0) { $0 + $1.count }
            briefEmbeddingCount = diarization.briefEmbeddings.values.reduce(0) { $0 + $1.count }
        }
    }
    struct Comparison: Encodable {
        let wallSeconds: Double
        let turnCount: Int
        let exactSegments: Bool
        let frameAgreement: Double
        let exactOverlaps: Bool
        let keptEmbeddingClustersMatch: Bool
        let briefEmbeddingClustersMatch: Bool
        let embeddingVectorCountsMatch: Bool
        let comparedEmbeddingVectors: Int
        let minimumEmbeddingCosine: Double?
    }

    let scope = "accelerated_local_component_only"
    let notes = [
        "Debug build; prerecorded audio is fed faster than real time in 30-second blocks, with snapshots every 60 seconds.",
        "Tail timing includes dual-track append and final speaker/embedding snapshot: 20 seconds of the shorter track and any additional samples of the longer track.",
        "No echo removal, STT, LLM, network requests, download, credential access or app finalization is performed.",
        "Batch comparison uses the same original raw PCM; agreement is not a ground-truth speaker-accuracy score.",
        "No audio content, transcript, file paths or embedding vectors are stored in this report.",
    ]
    var status = "prefilling_locally"
    let audioSeconds: Double
    let tailAudioSeconds: Double
    let trackLengthDifferenceSeconds: Double
    var modelLoadWallSeconds: Double?
    var prefillWallSeconds: Double?
    var prefillSinceLastCheckpointSeconds: Double?
    var tailAppendWallSeconds: Double?
    var tailFinalizeWallSeconds: Double?
    var tailWallSeconds: Double?
    var checkpoints: [Checkpoint] = []
    var tracks: [String: TrackSummary] = [:]
    var batchComparison: [String: Comparison] = [:]

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
