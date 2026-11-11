import Foundation

/// Maps host-clock time to recording time with paused spans removed. Both tracks place their
/// audio through the same timeline, which is what keeps them aligned across pauses.
public struct RecordingTimeline: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case recording
        case paused
        case stopped
    }

    struct Span: Sendable, Equatable {
        let start: Double
        var end: Double?
    }

    public private(set) var state: State = .recording
    private(set) var spans: [Span]

    /// Times are host-clock seconds.
    public init(startedAt: Double) {
        spans = [Span(start: startedAt)]
    }

    /// Returns false when already paused or stopped.
    @discardableResult
    public mutating func pause(at time: Double) -> Bool {
        guard state == .recording else { return false }
        closeLastSpan(at: time)
        state = .paused
        return true
    }

    /// Returns false unless paused.
    @discardableResult
    public mutating func resume(at time: Double) -> Bool {
        guard state == .paused else { return false }
        spans.append(Span(start: max(time, lastEventTime)))
        state = .recording
        return true
    }

    public mutating func stop(at time: Double) {
        if state == .recording { closeLastSpan(at: time) }
        state = .stopped
    }

    /// Recording-time position of audio captured at `time`, or nil when that moment is outside
    /// every recorded span (before start, during a pause, after stop).
    public func position(at time: Double) -> Double? {
        var before = 0.0
        for span in spans {
            if time < span.start { return nil }
            if let end = span.end, time >= end {
                before += end - span.start
                continue
            }
            return before + (time - span.start)
        }
        return nil
    }

    /// The recorded part of audio captured over `[start, start + duration)`: where it lands, and
    /// how much to drop from its head and keep, so a buffer straddling a pause or resume is cut at
    /// the exact moment rather than shifting the track by up to one buffer.
    public func clip(start: Double, duration: Double) -> (position: Double, skip: Double, keep: Double)? {
        let end = start + duration
        for span in spans {
            let from = max(start, span.start), to = min(end, span.end ?? .infinity)
            if to > from, let position = position(at: from) {
                return (position, from - start, to - from)
            }
        }
        return nil
    }

    /// Recorded seconds up to `time`; a highlight marked at `time` lands here.
    public func elapsed(at time: Double) -> Double {
        spans.reduce(0) { total, span in
            let end = min(span.end ?? time, time)
            return total + max(0, end - span.start)
        }
    }

    private var lastEventTime: Double {
        spans.last.map { $0.end ?? $0.start } ?? 0
    }

    private mutating func closeLastSpan(at time: Double) {
        let last = spans.count - 1
        spans[last].end = max(time, spans[last].start)
    }
}

/// Decides where a captured chunk lands in a track file so the track follows the shared timeline:
/// gaps (device restart, dropped buffers) become silence, and audio running ahead is trimmed.
public struct TrackAligner: Sendable, Equatable {
    public struct Placement: Sendable, Equatable {
        /// Silent frames to write before the chunk.
        public let padding: Int
        /// Leading frames of the chunk to discard.
        public let skip: Int
    }

    public let sampleRate: Double
    /// Drift absorbed without correction, so normal callback jitter never inserts clicks.
    public let tolerance: Int
    public private(set) var writtenFrames = 0

    public init(sampleRate: Double, toleranceSeconds: Double = 0.02) {
        self.sampleRate = sampleRate
        self.tolerance = Int((toleranceSeconds * sampleRate).rounded())
    }

    public mutating func place(frames: Int, at position: Double) -> Placement {
        let expected = Int((position * sampleRate).rounded())
        let drift = expected - writtenFrames
        let placement: Placement
        if drift > tolerance {
            placement = Placement(padding: drift, skip: 0)
        } else if -drift > tolerance {
            placement = Placement(padding: 0, skip: min(frames, -drift))
        } else {
            placement = Placement(padding: 0, skip: 0)
        }
        writtenFrames += placement.padding + frames - placement.skip
        return placement
    }

    /// Silent frames needed so the track reaches `duration`; used at stop so both tracks end together.
    public mutating func padding(toReach duration: Double) -> Int {
        let missing = max(0, Int((duration * sampleRate).rounded()) - writtenFrames)
        writtenFrames += missing
        return missing
    }
}
