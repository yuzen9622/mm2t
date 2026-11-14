import Foundation
import MM2TCore
import Testing
@testable import MM2TDiarization

@Suite struct VoiceprintCacheTests {
    private func plan(_ segments: [Diarization.Segment]) -> VoiceprintPlan {
        VoiceprintPlan(segments: segments, duration: 120, minimumSpeech: 8, includingBrief: true)
    }

    @Test func extendingATurnReusesFullPiecesAndReplacesItsTail() throws {
        let first = plan([segment("S1", 0, 10)])
        var cache = VoiceprintCache()
        cache.insert([1, 0], for: first.pieces[0])
        cache.insert([0, 1], for: first.pieces[1])

        let extended = plan([segment("S1", 0, 14)])
        let missing = cache.missing(in: extended)
        #expect(missing.count == 1)
        #expect(missing[0].span == 8.0..<14.0)
        cache.retain(extended)
        cache.insert([1, 0], for: missing[0])
        let vector = try #require(cache.voiceprints(for: extended).kept[ClusterID("S1")]?.first)
        #expect(vector.values == [1, 0], "the superseded tail must not contribute to the centroid")
        #expect(cache.vectors.count == 2)
        #expect(cache.missing(in: extended).isEmpty)
    }

    @Test func newOverlapInvalidatesOnlyAffectedPieces() {
        let first = plan([segment("S1", 0, 20)])
        var cache = VoiceprintCache()
        for piece in first.pieces { cache.insert([1, 0], for: piece) }
        let overlap = plan([segment("S1", 0, 20), segment("S2", 9, 10)])
        let missing = cache.missing(in: overlap)
        #expect(missing.filter { $0.cluster == ClusterID("S1") }.map(\.span) == [10.0..<18.0, 18.0..<20.0])
        #expect(missing.allSatisfy { $0.cluster == ClusterID("S1") }, "overlap alone is not clean enrollment speech")
        cache.retain(overlap)
        #expect(cache.vectors.count == 1)
        #expect(cache.vectors.keys.first?.span == 0.0..<8.0)
    }

    @Test func briefSpeechBecomesAStoredVoiceprintWithoutKeepingShortOnlyPieces() throws {
        let brief = plan([segment("S1", 0, 1.5), segment("S1", 3, 6)])
        var cache = VoiceprintCache()
        for piece in brief.pieces { cache.insert(piece.startSample == 0 ? [0, 1] : [1, 0], for: piece) }
        #expect(cache.voiceprints(for: brief).kept.isEmpty)
        #expect(cache.voiceprints(for: brief).brief.count == 1)

        let enough = plan([segment("S1", 0, 1.5), segment("S1", 3, 6), segment("S1", 8, 13)])
        let missing = cache.missing(in: enough)
        #expect(missing.map(\.span) == [8.0..<13.0])
        cache.retain(enough)
        for piece in missing { cache.insert([1, 0], for: piece) }
        let result = cache.voiceprints(for: enough)
        #expect(result.brief.isEmpty)
        #expect(try #require(result.kept[ClusterID("S1")]?.first).values == [1, 0])
    }

    @Test func centroidStillUsesEquallyWeightedUnitVectors() throws {
        let selected = plan([segment("S1", 0, 10)])
        var cache = VoiceprintCache()
        cache.insert([10, 0], for: selected.pieces[0])
        cache.insert([0, 1], for: selected.pieces[1])
        #expect(try #require(cache.voiceprints(for: selected).kept[ClusterID("S1")]?.first).values == [0.5, 0.5])
    }
}
