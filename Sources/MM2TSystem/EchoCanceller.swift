import Accelerate
import Foundation
import MM2TCore

/// Takes out of the mic track what the speakers played of the remote track. Without headphones the
/// mic hears the call a second time, and speech recognition writes all of it down as the user's words.
///
/// Per frequency bin, the room's response is the least-squares fit of mic to remote over the
/// surrounding `context` seconds, and the fitted echo is subtracted. On a recording that was only
/// echo this removed 16 dB; a single fixed filter for the whole minute removed 9 dB.
public enum EchoCanceller {
    /// Seconds on each side of a frame that the room's response is fitted over. Shorter follows a
    /// moving laptop faster but starts fitting, and removing, the people in the room.
    static let context: TimeInterval = 5
    /// The latest the speakers' sound is expected back at the mic.
    static let maxDelay: TimeInterval = 0.5
    /// Seconds the echo profile measures loudness in.
    static let profileFrame: TimeInterval = 0.05

    public struct Result: Sendable {
        public let samples: [Int16]
        public let echo: EchoProfile
    }

    /// nil when the remote track is silent over this span, so there is nothing to remove.
    public static func clean(mic: [Int16], remote: [Int16], sampleRate: Int) -> Result? {
        let count = min(mic.count, remote.count)
        // About half a second per frame: 8192 samples at 16 kHz.
        let frame = 1 << Int(log2(Double(sampleRate) * 0.512).rounded())
        guard count >= frame, !QuietCut.isSilent(Array(remote[..<count])) else { return nil }

        let y = floats(mic, count), x = floats(remote, count)
        // The fit only spans one frame, so the remote track is first moved to where its echo starts.
        let lead = max(0, delay(of: y, behind: x, limit: Int(maxDelay * Double(sampleRate))) - frame / 128)
        let hop = frame / 2, padded = count + 2 * frame
        var xp = [Float](repeating: 0, count: padded), yp = [Float](repeating: 0, count: padded)
        yp.replaceSubrange(frame..<frame + count, with: y)
        xp.replaceSubrange(frame + lead..<frame + count, with: x[..<(count - lead)])

        let frames = (padded - frame) / hop + 1, bins = frame / 2 + 1
        let transform = Transform(frame)
        var xr = [Float](repeating: 0, count: frames * bins), xi = xr, yr = xr, yi = xr
        for index in 0..<frames {
            transform.forward(xp, at: index * hop, real: &xr, imaginary: &xi, row: index * bins)
            transform.forward(yp, at: index * hop, real: &yr, imaginary: &yi, row: index * bins)
        }

        let reach = Int(context * Double(sampleRate) / Double(hop))
        var crossR = [Double](repeating: 0, count: bins), crossI = crossR, power = crossR
        func accumulate(_ index: Int, _ sign: Double) {
            let row = index * bins
            for bin in 0..<bins {
                let a = Double(xr[row + bin]), b = Double(xi[row + bin])
                let c = Double(yr[row + bin]), d = Double(yi[row + bin])
                crossR[bin] += sign * (c * a + d * b)
                crossI[bin] += sign * (d * a - c * b)
                power[bin] += sign * (a * a + b * b)
            }
        }
        for index in 0..<min(reach, frames) { accumulate(index, 1) }

        var out = [Float](repeating: 0, count: padded)
        var er = [Float](repeating: 0, count: bins), ei = er
        for index in 0..<frames {
            if index + reach < frames { accumulate(index + reach, 1) }
            if index - reach - 1 >= 0 { accumulate(index - reach - 1, -1) }
            let row = index * bins
            for bin in 0..<bins {
                let scale = 1 / (max(power[bin], 0) + 1e-9)
                let hr = Float(crossR[bin] * scale), hi = Float(crossI[bin] * scale)
                let a = xr[row + bin], b = xi[row + bin]
                er[bin] = yr[row + bin] - (hr * a - hi * b)
                ei[bin] = yi[row + bin] - (hr * b + hi * a)
            }
            transform.inverse(real: er, imaginary: ei, addingTo: &out, at: index * hop)
        }

        let cleaned = Array(out[frame..<frame + count])
        var samples = [Int16](repeating: 0, count: mic.count)
        for index in 0..<count {
            samples[index] = Int16(max(-32768, min(32767, (cleaned[index] * 32768).rounded())))
        }
        if mic.count > count { samples.replaceSubrange(count..., with: mic[count...]) }
        let step = max(1, Int(profileFrame * Double(sampleRate)))
        return Result(samples: samples, echo: EchoProfile(
            frameDuration: Double(step) / Double(sampleRate),
            before: loudness(y, step: step), after: loudness(cleaned, step: step)))
    }

    private static func floats(_ samples: [Int16], _ count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        vDSP.convertElements(of: samples[..<count], to: &result)
        return vDSP.divide(result, 32768)
    }

    /// Mean square of each `step` samples; a last partial stretch counts as one more.
    private static func loudness(_ samples: [Float], step: Int) -> [Float] {
        stride(from: 0, to: samples.count, by: step).map { start in
            samples[start..<min(start + step, samples.count)].withUnsafeBufferPointer { vDSP.meanSquare($0) }
        }
    }

    /// How many samples `mic` trails `remote` by: the lag, up to `limit`, where the two correlate
    /// most over the loudest four seconds or so of the remote track.
    private static func delay(of mic: [Float], behind remote: [Float], limit: Int) -> Int {
        let span = min(remote.count, 1 << 16)
        var start = 0, loudest: Float = -1
        for candidate in stride(from: 0, through: remote.count - span, by: max(1, span / 2)) {
            let energy = remote[candidate..<candidate + span].withUnsafeBufferPointer { vDSP.sumOfSquares($0) }
            if energy > loudest { (start, loudest) = (candidate, energy) }
        }
        let lags = min(limit, mic.count - start - 1)
        guard lags > 0 else { return 0 }
        let length = min(span, mic.count - start - lags)
        guard length > 0 else { return 0 }
        var correlation = [Float](repeating: 0, count: lags)
        // vDSP_conv with a positive stride correlates: result[n] = sum(signal[n + p] * filter[p]).
        mic.withUnsafeBufferPointer { signal in
            remote.withUnsafeBufferPointer { filter in
                vDSP_conv(signal.baseAddress! + start, 1, filter.baseAddress! + start, 1,
                          &correlation, 1, vDSP_Length(lags), vDSP_Length(length))
            }
        }
        return Int(vDSP.indexOfMaximum(vDSP.absolute(correlation)).0)
    }
}

/// Windowed transforms of one frame length. The square-root Hann window is applied going in and
/// coming out, so frames half a frame apart add back up to the signal.
private final class Transform {
    private let frame: Int
    private let window: [Float]
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private var inR: [Float], inI: [Float], outR: [Float], outI: [Float]

    init(_ frame: Int) {
        self.frame = frame
        window = (0..<frame).map { Float((0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frame))).squareRoot()) }
        forwardSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frame), .FORWARD)!
        inverseSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frame), .INVERSE)!
        inR = [Float](repeating: 0, count: frame)
        inI = inR
        outR = inR
        outI = inR
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    /// Writes the lower half of the spectrum, which is all a real signal has, at `row`.
    func forward(_ signal: [Float], at offset: Int, real: inout [Float], imaginary: inout [Float], row: Int) {
        vDSP.multiply(signal[offset..<offset + frame], window, result: &inR)
        vDSP.fill(&inI, with: 0)
        vDSP_DFT_Execute(forwardSetup, inR, inI, &outR, &outI)
        let bins = frame / 2 + 1
        real.replaceSubrange(row..<row + bins, with: outR[..<bins])
        imaginary.replaceSubrange(row..<row + bins, with: outI[..<bins])
    }

    func inverse(real: [Float], imaginary: [Float], addingTo out: inout [Float], at offset: Int) {
        let bins = frame / 2 + 1
        for bin in 0..<bins {
            inR[bin] = real[bin]
            inI[bin] = imaginary[bin]
        }
        for bin in 1..<bins - 1 {
            inR[frame - bin] = real[bin]
            inI[frame - bin] = -imaginary[bin]
        }
        vDSP_DFT_Execute(inverseSetup, inR, inI, &outR, &outI)
        let scale = 1 / Float(frame)
        for index in 0..<frame { out[offset + index] += outR[index] * window[index] * scale }
    }
}

/// Cleans a finished recording's mic track, a few minutes at a time so an hour of audio is never
/// held as floats at once.
public struct EchoRemover: MicCleaner {
    static let chunkSeconds = 180

    public init() {}

    public func clean(mic: URL, remote: URL) throws -> CleanedMic? {
        let total = try WAVFormat.frameCount(mic), shared = min(total, try WAVFormat.frameCount(remote))
        guard total > 0 else { return nil }
        let rate = try WAVFormat.read(mic, frames: 0..<1).sampleRate
        let chunk = Self.chunkSeconds * rate
        var samples: [Int16] = []
        samples.reserveCapacity(total)
        var profile = EchoProfile(frameDuration: EchoCanceller.profileFrame, before: [], after: [])
        var removedAny = false
        for start in stride(from: 0, to: total, by: chunk) {
            let range = start..<min(start + chunk, total)
            let heard = try WAVFormat.read(mic, frames: range).samples
            let played = range.lowerBound < shared
                ? try WAVFormat.read(remote, frames: range.lowerBound..<min(range.upperBound, shared)).samples : []
            if let cleaned = EchoCanceller.clean(mic: heard, remote: played, sampleRate: rate) {
                samples += cleaned.samples
                profile = profile.appending(cleaned.echo, at: Double(start) / Double(rate))
                removedAny = true
            } else {
                samples += heard
            }
        }
        guard removedAny else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "mm2t-mic-\(UUID().uuidString).wav")
        try WAVFormat.write(WAVAudio(sampleRate: rate, samples: samples), to: url)
        return CleanedMic(audio: url, echo: profile)
    }
}
