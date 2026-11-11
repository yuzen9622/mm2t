import Foundation

/// Input level of one track over a short window, for the UI meters.
public struct AudioLevel: Sendable, Equatable {
    public let rms: Float
    public let peak: Float

    public static let silent = AudioLevel(rms: 0, peak: 0)

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public init(samples: UnsafeBufferPointer<Float>) {
        var accumulator = Accumulator()
        accumulator.add(samples)
        self = accumulator.level
    }

    public var rmsDBFS: Float { Self.dBFS(rms) }
    public var peakDBFS: Float { Self.dBFS(peak) }

    /// 0 at `floor` dBFS or below, 1 at full scale; what a meter bar should fill.
    public func meter(floor: Float = -60) -> Float {
        min(1, max(0, (rmsDBFS - floor) / -floor))
    }

    static func dBFS(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(-160, 20 * log10(amplitude)) : -160
    }

    /// Combines several chunks into one window's level.
    public struct Accumulator: Sendable {
        private var sumOfSquares: Double = 0
        private var count = 0
        private var peak: Float = 0

        public init() {}

        public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
            for sample in samples {
                sumOfSquares += Double(sample * sample)
                peak = max(peak, abs(sample))
            }
            count += samples.count
        }

        public var level: AudioLevel {
            count == 0 ? .silent : AudioLevel(rms: Float((sumOfSquares / Double(count)).squareRoot()), peak: peak)
        }
    }
}

public struct TrackLevels: Sendable, Equatable {
    public let me: AudioLevel
    public let remote: AudioLevel
}
