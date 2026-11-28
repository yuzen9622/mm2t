import MM2TCore
import CMm2tAEC3

/// One ordered render/capture stream. The owner serializes calls; neither the handle nor its
/// adaptive state crosses an actor boundary.
package final class AEC3 {
    package static let sampleRate = 16_000
    private static let frame = 160
    private static let fade = 80
    private static let fallbackRatio: Float = 1.23 // 0.9 dB, with margin for PCM rounding.
    private let state: OpaquePointer
    private var speakerCoupled = false
    private var mixed = 0

    package init?() {
        guard let state = mm2t_aec3_create() else { return nil }
        self.state = state
    }

    deinit { mm2t_aec3_destroy(state) }

    package var estimatedDelayMilliseconds: Int? {
        let delay = mm2t_aec3_delay_ms(state)
        return delay >= 0 ? Int(delay) : nil
    }

    package func clean(mic: [Int16], remote: [Int16]) -> EchoCanceller.Result {
        let frame = Self.frame
        let grid = Int(EchoCanceller.profileFrame * Double(Self.sampleRate))
        let render = Array(remote.prefix(mic.count)) + [Int16](repeating: 0, count: max(0, mic.count - remote.count))
        let fit = EchoCanceller.clean(mic: mic, remote: render, sampleRate: Self.sampleRate)
        let linear = fit?.echo ?? EchoCanceller.unchangedProfile(mic: mic, sampleRate: Self.sampleRate)
        let speakers = linear.speakerFrames()
        // Once the render was heard through speakers, double-talk in a later piece cannot
        // turn that same stream into headphones. A short in-sample fit alone can overfit.
        if (fit?.renderCorrelation ?? 0) >= EchoCanceller.minimumRenderCorrelation && speakers.contains(true) {
            speakerCoupled = true
        }
        // Feed both tracks even when bypassed. The classifier controls what we emit, not the
        // internal adaptation, so switching to speaker output doesn't start from a cold filter.
        var samples = mic
        var captureTail = [Int16](repeating: 0, count: frame), renderTail = captureTail, output = captureTail
        let endOfRender = min(remote.count, mic.count)
        let fadeEnd = endOfRender < mic.count ? endOfRender : Int.max
        mic.withUnsafeBufferPointer { capture in
            render.withUnsafeBufferPointer { render in
                for start in stride(from: 0, to: mic.count, by: frame) {
                    let count = min(frame, mic.count - start)
                    let status: Int32
                    if count == frame {
                        status = mm2t_aec3_process(state, render.baseAddress! + start, capture.baseAddress! + start, &output)
                    } else {
                        captureTail.replaceSubrange(0..<count, with: capture[start..<start + count])
                        renderTail.replaceSubrange(0..<count, with: render[start..<start + count])
                        status = mm2t_aec3_process(state, renderTail, captureTail, &output)
                    }
                    let hasEvidence = speakerCoupled && speakers[start / grid]
                    let enabled = status == 0 && hasEvidence
                    for offset in 0..<count {
                        let index = start + offset
                        let target = enabled && index < endOfRender ? Self.fade : 0
                        mixed += target == mixed ? 0 : (target > mixed ? 1 : -1)
                        // Fade to dry just before the render ends, leaving a short or missing tail bit-identical.
                        let weight = status == 0 ? min(mixed, max(0, fadeEnd - index - 1)) : 0
                        let base = speakerCoupled && index < endOfRender ? fit?.samples[index] ?? capture[index] : capture[index]
                        let wet = Int(output[offset]) * weight
                        let dry = Int(base) * (Self.fade - weight)
                        samples[index] = Int16((wet + dry) / Self.fade)
                    }
                }
            }
        }
        var energy = EchoCanceller.unchangedProfile(mic: samples, sampleRate: Self.sampleRate).after
        if speakerCoupled, let fit {
            // Even a locked AEC can underperform the aligned fit, including during warm-up
            // and when the context gate is diluted by double-talk. Compare the emitted PCM.
            var fellBack = false
            for frame in energy.indices where (linear.remote[frame] ?? 0) >= EchoProfile.activePlayback
                && energy[frame] > linear.after[frame] * Self.fallbackRatio {
                let start = frame * grid
                let end = min(start + grid, endOfRender)
                guard start < end else { continue }
                samples.replaceSubrange(start..<end, with: fit.samples[start..<end])
                fellBack = true
            }
            if fellBack {
                energy = EchoCanceller.unchangedProfile(mic: samples, sampleRate: Self.sampleRate).after
            }
        }
        return EchoCanceller.Result(samples: samples, echo: linear.replacingCleanedEnergy(with: energy))
    }
}
