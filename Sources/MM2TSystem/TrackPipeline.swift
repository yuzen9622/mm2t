import AVFoundation
import MM2TCore

/// Everything between one capture ring and its file: levels, pause filtering, resampling to the
/// file rate, and timeline alignment. Owned and driven by `AudioRecorder` on its executor.
final class TrackPipeline {
    let track: Track
    let ring = CaptureRing()
    let writer: WAVWriter
    private(set) var aligner: TrackAligner
    private let resampler: Resampler
    private var levels = AudioLevel.Accumulator()

    init(track: Track, url: URL, sampleRate: Int) throws {
        self.track = track
        writer = try WAVWriter(url: url, sampleRate: sampleRate)
        aligner = TrackAligner(sampleRate: Double(sampleRate))
        resampler = Resampler(outputRate: Double(sampleRate))
    }

    func drain(_ timeline: RecordingTimeline) {
        ring.drain { chunk, samples in
            levels.add(samples)
            let captured = HostTime.seconds(chunk.hostTime) + Double(chunk.frameOffset) / chunk.sampleRate
            guard let (position, skip, keep) = timeline.clip(start: captured, duration: Double(chunk.frames) / chunk.sampleRate)
            else { return }
            let first = min(chunk.frames, Int((skip * chunk.sampleRate).rounded()))
            let count = min(chunk.frames - first, Int((keep * chunk.sampleRate).rounded()))
            let recorded = UnsafeBufferPointer(rebasing: samples[first ..< first + count])
            resampler.process(recorded, inputRate: chunk.sampleRate) { output, buffered in
                // The converter holds some audio back; what comes out ends that far before the input did.
                let end = position + Double(count) / chunk.sampleRate - buffered
                let placement = aligner.place(frames: output.count, at: end - Double(output.count) / resampler.outputRate)
                if placement.padding > 0 { writer.appendSilence(frames: placement.padding) }
                writer.append(UnsafeBufferPointer(rebasing: output[placement.skip...]))
            }
        }
    }

    /// The level since the previous call.
    func takeLevel() -> AudioLevel {
        defer { levels = AudioLevel.Accumulator() }
        return levels.level
    }

    /// Fills a capture gap with silence as it happens, so after a crash both tracks still cover
    /// the same span even when one device had stopped delivering.
    func padSilence(upTo position: TimeInterval) {
        guard position > 0 else { return }
        writer.appendSilence(frames: aligner.padding(toReach: position))
    }

    func finish(duration: TimeInterval) throws {
        writer.appendSilence(frames: aligner.padding(toReach: duration))
        try writer.close()
    }
}

/// Converts mono Float32 at whatever rate the device runs to the fixed file rate. A device change
/// can change the input rate mid-recording; the converter is rebuilt when it does.
final class Resampler {
    let outputRate: Double
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var secondsIn = 0.0
    private var secondsOut = 0.0

    init(outputRate: Double) {
        self.outputRate = outputRate
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false)!
    }

    /// `body` gets the converted audio and how many seconds of input are still inside the converter.
    func process(_ samples: UnsafeBufferPointer<Float>, inputRate: Double,
                 _ body: (UnsafeBufferPointer<Float>, _ buffered: Double) -> Void) {
        guard !samples.isEmpty else { return }
        if inputRate == outputRate {
            body(samples, 0)
            return
        }
        if converter?.inputFormat.sampleRate != inputRate {
            let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            secondsIn = 0
            secondsOut = 0
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * outputRate / inputRate) + 64)
        else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        input.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        let feed = InputFeed(input)
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        guard error == nil else { return }
        secondsIn += Double(samples.count) / inputRate
        secondsOut += Double(output.frameLength) / outputRate
        guard output.frameLength > 0 else { return }
        body(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)), secondsIn - secondsOut)
    }

    /// Supplies the chunk once, then reports no data so the converter returns what it has.
    private final class InputFeed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
