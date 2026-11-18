import Foundation

/// Sums the two tracks into one mono stream as they are written, for live captions. The mix
/// advances as far as every track has written, but never more than `lag` frames behind the track
/// that is furthest along, so a stalled track, or a mic track that is only padded with silence once
/// a second, cannot hold captions back. Samples a late track writes for frames already mixed are dropped.
struct LiveMix {
    /// Frames before this file position have been handed out.
    private(set) var cursor: Int
    let lag: Int
    private var tracks: [Track]

    private struct Track {
        /// The file position this track has written up to.
        var written: Int
        /// The latest samples, ending at `written`, not yet mixed.
        var samples: [Float] = []
        var bufferStart: Int { written - samples.count }
    }

    /// `positions` are how far each track's file already reaches when mixing starts.
    init(positions: [Int], lag: Int) {
        cursor = positions.max() ?? 0
        self.lag = lag
        tracks = positions.map { Track(written: $0) }
    }

    /// Track `index` wrote `samples` to its file starting at frame `start`.
    mutating func add(_ samples: [Float], track index: Int, at start: Int) {
        var track = tracks[index]
        let end = start + samples.count
        guard end > track.written else { return }
        if start > track.written { track.samples += repeatElement(0, count: start - track.written) }
        track.samples += samples.suffix(end - max(start, track.written))
        track.written = end
        tracks[index] = track
    }

    /// The mixed audio that is ready, clipped to -1...1; empty when nothing is.
    mutating func take() -> [Float] {
        let ends = tracks.map(\.written)
        guard let lowest = ends.min(), let highest = ends.max() else { return [] }
        let end = max(lowest, highest - lag)
        guard end > cursor else { return [] }
        var mixed = [Float](repeating: 0, count: end - cursor)
        for index in tracks.indices {
            let track = tracks[index]
            let start = track.bufferStart
            let from = max(cursor, start)
            let to = min(end, track.written)
            if from < to {
                for frame in from ..< to { mixed[frame - cursor] += track.samples[frame - start] }
            }
            tracks[index].samples.removeFirst(min(track.samples.count, max(0, end - start)))
        }
        cursor = end
        for index in mixed.indices { mixed[index] = max(-1, min(1, mixed[index])) }
        return mixed
    }
}
