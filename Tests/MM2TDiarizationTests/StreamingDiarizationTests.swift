import Foundation
import MM2TCore
import Testing
@testable import MM2TDiarization

@Suite struct StreamingDiarizationContractTests {
    private struct SnapshotOnlySession: StreamingDiarizationSession {
        func append(samples: [Float], track: Track) async throws {}
        func snapshot(tracks: [Track: URL], final: Bool) async throws -> StreamingDiarizationSnapshot {
            StreamingDiarizationSnapshot(diarizations: [:], processedSeconds: [.remote: 12])
        }
    }

    @Test func snapshotOnlyImplementationsKeepTheirExistingProgressContract() async throws {
        let session: any StreamingDiarizationSession = SnapshotOnlySession()
        #expect(await session.processedSeconds().isEmpty)
        #expect(try await session.snapshot(tracks: [:], final: false).processedSeconds == [.remote: 12])
    }
}

@Suite struct SpanAudioSourceTests {
    @Test func readsOnlyTheRequestedSamplesWithoutChangingTheirTimeline() throws {
        let samples = (0..<160_000).map { Float($0 % 127) / 127 }
        let url = try temporaryDirectory().appending(path: "span.wav")
        try writeAudio([samples], sampleRate: 16_000, to: url,
                       settings: wavSettings(sampleRate: 16_000, channels: 1, float: true))
        let source = try SpanAudioSource(url: url)
        #expect(source.sampleCount == samples.count)
        var read = [Float](repeating: 0, count: 83_040)
        try read.withUnsafeMutableBufferPointer { try source.copySamples(into: $0.baseAddress!, offset: 16_123, count: $0.count) }
        #expect(read == Array(samples[16_123..<99_163]))
    }

    @Test func rejectsAudioAtAnotherRateInsteadOfSilentlyShiftingSpans() throws {
        let url = try temporaryDirectory().appending(path: "wrong-rate.wav")
        try writeAudio([[Float](repeating: 0, count: 48_000)], sampleRate: 48_000, to: url,
                       settings: wavSettings(sampleRate: 48_000, channels: 1, float: true))
        #expect(throws: TrackAudioError.self) { try SpanAudioSource(url: url) }
    }
}

@Suite(.serialized, .enabled(if: EvaluationData.available, "needs Evaluation/diarization data and models"))
struct StreamingDiarizationRealAudioTests {
    @Test func interleavedTracksAndIncrementalVoiceprintsMatchWholeTrackProcessing() async throws {
        let data = EvaluationData()
        let source = try TrackAudio(converting: data.track)
        defer { source.remove() }
        let directory = try temporaryDirectory()
        let count = 95 * 16_000 + 137
        let samples: [Track: [Float]] = [
            .remote: source.samples(from: 0, count: count),
            .me: source.samples(from: 40 * 16_000, count: count),
        ]
        var urls: [Track: URL] = [:]
        for track in Track.allCases {
            let url = directory.appending(path: "\(track.rawValue).wav")
            try writeAudio([samples[track]!], sampleRate: 16_000, to: url,
                           settings: wavSettings(sampleRate: 16_000, channels: 1, float: true))
            urls[track] = url
        }
        let embedder = WeSpeakerEmbedder(models: data.models)
        let factory = NemotronDiarizer(models: data.models, embedder: embedder)
        let session = try await factory.makeStreamingSession()
        #expect(await session.processedSeconds() == [.me: 0, .remote: 0])
        let block = 7 * 16_000 + 47
        var snapshots = 0
        var previousWatermarks: [Track: TimeInterval] = [.me: 0, .remote: 0]
        for start in stride(from: 0, to: count, by: block) {
            for track in Track.allCases {
                try await session.append(samples: Array(samples[track]![start..<min(start + block, count)]), track: track)
            }
            let watermarks = await session.processedSeconds()
            let secondsFed = Double(min(start + block, count)) / 16_000
            for track in Track.allCases {
                let watermark = try #require(watermarks[track])
                #expect(watermark >= previousWatermarks[track]! && watermark <= secondsFed)
                if secondsFed > 31 {
                    #expect(watermark > 0, "append progress must be observable before the first snapshot")
                }
            }
            #expect(await session.processedSeconds() == watermarks, "polling does not advance or finish the stream")
            previousWatermarks = watermarks
            if start > (snapshots + 1) * 32 * 16_000 {
                let snapshot = try await session.snapshot(tracks: urls, final: false)
                #expect(snapshot.processedSeconds == watermarks)
                for track in Track.allCases {
                    let watermark = try #require(snapshot.processedSeconds[track])
                    #expect(watermark > 0 && watermark <= Double(min(start + block, count)) / 16_000)
                }
                snapshots += 1
            }
        }
        let clock = ContinuousClock()
        let finishing = clock.now
        let final = try await session.snapshot(tracks: urls, final: true)
        #expect(await session.processedSeconds() == final.processedSeconds)
        print("[streaming real] finish two 95 s tracks + incremental embeddings: \(clock.now - finishing)")
        for track in Track.allCases {
            let expected = try await factory.diarize(track: urls[track]!)
            let actual = try #require(final.diarizations[track])
            #expect(frameAgreement(actual.segments, expected.segments, to: Double(count) / 16_000) > 0.9999)
            #expect(actual.overlaps == expected.overlaps)
            #expect(Set(actual.embeddings.keys) == Set(expected.embeddings.keys))
            #expect(Set(actual.briefEmbeddings.keys) == Set(expected.briefEmbeddings.keys))
            for (cluster, vectors) in expected.embeddings.merging(expected.briefEmbeddings, uniquingKeysWith: { a, _ in a }) {
                let actualVector = try #require((actual.embeddings[cluster] ?? actual.briefEmbeddings[cluster])?.first)
                #expect(actualVector.cosineSimilarity(to: vectors[0]) > 0.99999)
            }
            #expect(final.processedSeconds[track] == Double(count) / 16_000)
        }
        let completedTracks = urls
        async let repeatA = session.snapshot(tracks: completedTracks, final: true)
        async let repeatB = session.snapshot(tracks: completedTracks, final: true)
        for repeated in try await [repeatA, repeatB] {
            #expect(repeated.processedSeconds == final.processedSeconds)
            #expect(repeated.diarizations[.remote]?.segments.count == final.diarizations[.remote]?.segments.count)
        }
        await #expect(throws: StreamingDiarizationError.finished) {
            try await session.append(samples: [0], track: .remote)
        }
        let nextMeeting = try await factory.makeStreamingSession()
        #expect(await nextMeeting.processedSeconds() == [.me: 0, .remote: 0])
        let empty = try await nextMeeting.snapshot(tracks: [:], final: true)
        #expect(await nextMeeting.processedSeconds() == [.me: 0, .remote: 0])
        #expect(empty.processedSeconds.values.allSatisfy { $0 == 0 })
        #expect(empty.diarizations.values.allSatisfy { $0.segments.isEmpty && $0.embeddings.isEmpty })
    }
}
