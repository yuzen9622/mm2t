import Foundation
import MM2TCore

/// Post-processing on diarizer turns, following what `Evaluation/diarization` scored.
enum SpeakerTurns {
    /// Merges same-cluster turns separated by less than `maxGap`, like pyannote's `support(collar:)`
    /// that `score.py --fill-gaps` uses. AliMeeting's references keep mid-sentence pauses inside a
    /// turn; Nemotron-3 cuts them, and bridging 0.5 s took its DER c0.25 from 10.7% to 6.5%.
    static func bridgingGaps(_ segments: [Diarization.Segment], shorterThan maxGap: TimeInterval) -> [Diarization.Segment] {
        Dictionary(grouping: segments, by: \.cluster)
            .flatMap { cluster, turns in
                merged(turns.map(\.range), within: maxGap).map { Diarization.Segment(cluster: cluster, range: $0) }
            }
            .sorted { ($0.range.start, $0.range.end, $0.cluster.rawValue) < ($1.range.start, $1.range.end, $1.cluster.rawValue) }
    }

    /// Time where two or more clusters speak at once: the union of pairwise intersections between
    /// different clusters, as `score.py`'s `overlap_timeline` derives it from the scored hypothesis.
    static func overlaps(_ segments: [Diarization.Segment]) -> [TimeRange] {
        // Same-cluster turns are merged first so one speaker never overlaps themself.
        let turns: [TimeRange] = Dictionary(grouping: segments, by: \.cluster).values
            .flatMap { merged($0.map(\.range), within: 0) }
        var events: [(time: TimeInterval, delta: Int)] = turns.map { ($0.start, 1) } + turns.map { ($0.end, -1) }
        // An end and a start at the same instant touch; they do not overlap.
        events.sort { $0.time != $1.time ? $0.time < $1.time : $0.delta < $1.delta }
        var regions: [TimeRange] = []
        var active = 0
        var openedAt: TimeInterval?
        for (time, delta) in events {
            active += delta
            if active >= 2, openedAt == nil {
                openedAt = time
            } else if active < 2, let start = openedAt {
                if time > start { regions.append(TimeRange(start: start, end: time)) }
                openedAt = nil
            }
        }
        return merged(regions, within: 0)
    }

    /// Single-speaker stretches of each cluster cut into 2-8 s pieces, dropping remainders under 2 s,
    /// as `embeddings.py clean_pieces` built the spans the voiceprint numbers were measured on.
    static func cleanPieces(_ segments: [Diarization.Segment], within duration: TimeInterval) -> [ClusterID: [TimeRange]] {
        let minPiece = 2.0, maxPiece = 8.0
        let byCluster = Dictionary(grouping: segments, by: \.cluster).mapValues { merged($0.map(\.range), within: 0) }
        return byCluster.reduce(into: [:]) { result, entry in
            let others = merged(byCluster.filter { $0.key != entry.key }.values.flatMap { $0 }, within: 0)
            var pieces: [TimeRange] = []
            for stretch in subtracting(others, from: entry.value) {
                var start = stretch.start
                let end = min(stretch.end, duration)
                while end - start >= minPiece {
                    let stop = min(end, start + maxPiece)
                    pieces.append(TimeRange(start: start, end: stop))
                    start = stop
                }
            }
            result[entry.key] = pieces
        }
    }

    /// Mean of unit-normalized vectors; cosine similarity ignores the result's length.
    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let dimension = vectors.first?.count, dimension > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dimension)
        var used = 0
        for vector in vectors where vector.count == dimension {
            let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            for index in 0..<dimension { sum[index] += Double(vector[index]) / norm }
            used += 1
        }
        guard used > 0 else { return nil }
        return sum.map { Float($0 / Double(used)) }
    }

    /// Sorted union; ranges whose gap is under `gap` join. `gap` 0 joins only overlapping or touching ranges.
    static func merged(_ ranges: [TimeRange], within gap: TimeInterval) -> [TimeRange] {
        var result: [TimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start - last.end < gap || range.start <= last.end {
                result[result.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `ranges` minus `holes`; both sorted and disjoint.
    private static func subtracting(_ holes: [TimeRange], from ranges: [TimeRange]) -> [TimeRange] {
        ranges.flatMap { range -> [TimeRange] in
            var pieces: [TimeRange] = []
            var cursor = range.start
            for hole in holes where hole.end > cursor && hole.start < range.end {
                if hole.start > cursor { pieces.append(TimeRange(start: cursor, end: hole.start)) }
                cursor = max(cursor, hole.end)
            }
            if cursor < range.end { pieces.append(TimeRange(start: cursor, end: range.end)) }
            return pieces
        }
    }
}
