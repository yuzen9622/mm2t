import Accelerate
import FluidAudio
import Foundation

/// A fixed gain for uniformly quiet calls. Never raises one speaker relative to another.
enum RemoteDiarizationGain {
    // AliMeeting Eval: the −20 dB tracks peaked at 0.084–0.098; all single-speaker
    // attenuations peaked at 0.695–0.957. The latter should retain their original gain.
    private static let quietPeak: Float = 0.1
    private static let targetRMS: Float = 0.10
    private static let minimumVoicedRMS: Float = 0.0005
    private static let maximumGain: Float = 16
    private static let headroom: Float = 0.999
    private static let frameLength = 320  // 20 ms at 16 kHz.

    static func measure(in audio: any AudioSampleSource) throws -> Float {
        let block = TrackAudio.sampleRate * 30
        var peak: Float = 0
        var voiced: [Float] = []
        var buffer = [Float](repeating: 0, count: min(block, audio.sampleCount))
        for offset in stride(from: 0, to: audio.sampleCount, by: block) {
            try Task.checkCancellation()
            let count = min(block, audio.sampleCount - offset)
            let blockPeak = try buffer.withUnsafeMutableBufferPointer { samples -> Float in
                let base = samples.baseAddress!
                try audio.copySamples(into: base, offset: offset, count: count)
                var high: Float = 0
                vDSP_maxmgv(base, 1, &high, vDSP_Length(count))
                guard high.isFinite, high <= quietPeak else { return .infinity }
                for first in stride(from: 0, to: count, by: frameLength) {
                    let length = min(frameLength, count - first)
                    var power: Float = 0
                    vDSP_svesq(base.advanced(by: first), 1, &power, vDSP_Length(length))
                    let rms = sqrt(power / Float(length))
                    if rms >= minimumVoicedRMS { voiced.append(rms) }
                }
                return high
            }
            guard blockPeak <= quietPeak else { return 1 }
            peak = max(peak, blockPeak)
        }
        guard !voiced.isEmpty, peak > 0 else { return 1 }
        voiced.sort()
        let reference = voiced[9 * (voiced.count - 1) / 10]
        return min(maximumGain, max(1, targetRMS / reference), max(1, headroom / peak))
    }
}
