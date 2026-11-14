import Foundation
import MM2TCore

struct VoiceprintPlan {
    struct Piece: Hashable, Sendable {
        let cluster: ClusterID
        let startSample: Int
        let endSample: Int

        var span: Range<TimeInterval> {
            Double(startSample) / 16_000 ..< Double(endSample) / 16_000
        }
    }

    let pieces: [Piece]
    let enough: Set<ClusterID>

    init(segments: [Diarization.Segment], duration: TimeInterval,
         minimumSpeech: TimeInterval, includingBrief: Bool) {
        let stored = SpeakerTurns.cleanPieces(segments, within: duration).filter { !$0.value.isEmpty }
        let enough = Set(stored.filter { $0.value.reduce(0) { $0 + $1.duration } >= minimumSpeech }.keys)
        self.enough = enough
        var selected = stored.filter { enough.contains($0.key) }
        if includingBrief {
            let short = SpeakerTurns.cleanPieces(segments, within: duration,
                                                 minPiece: WeSpeakerEmbedder.briefMinimumPiece)
            selected.merge(short.filter { !enough.contains($0.key) && !$0.value.isEmpty }) { kept, _ in kept }
        }
        pieces = selected.flatMap { cluster, ranges in
            ranges.map {
                Piece(cluster: cluster, startSample: Int(($0.start * 16_000).rounded()),
                      endSample: Int(($0.end * 16_000).rounded()))
            }
        }.sorted {
            ($0.startSample, $0.endSample, $0.cluster.rawValue) < ($1.startSample, $1.endSample, $1.cluster.rawValue)
        }
    }
}

struct VoiceprintCache: Sendable {
    private(set) var vectors: [VoiceprintPlan.Piece: [Float]] = [:]

    func missing(in plan: VoiceprintPlan) -> [VoiceprintPlan.Piece] {
        plan.pieces.filter { vectors[$0] == nil }
    }

    mutating func insert(_ vector: [Float], for piece: VoiceprintPlan.Piece) {
        vectors[piece] = vector
    }

    mutating func retain(_ plan: VoiceprintPlan) {
        let required = Set(plan.pieces)
        vectors = vectors.filter { required.contains($0.key) }
    }

    func voiceprints(for plan: VoiceprintPlan)
        -> (kept: [ClusterID: [Embedding]], brief: [ClusterID: [Embedding]]) {
        let grouped = Dictionary(grouping: plan.pieces, by: \.cluster)
        let all = grouped.compactMapValues { pieces in
            SpeakerTurns.centroid(pieces.compactMap { vectors[$0] }).map { [Embedding($0)] }
        }
        return (all.filter { plan.enough.contains($0.key) }, all.filter { !plan.enough.contains($0.key) })
    }
}
