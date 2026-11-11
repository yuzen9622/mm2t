@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public enum TrackAudioError: Error, Equatable, Sendable {
    case unsupportedFormat(String)
    case conversionFailed(String)
}

/// A recorder track resampled to the 16 kHz mono Float32 both models take, written to a
/// temporary file and memory-mapped, so a two-hour meeting does not sit in RAM.
/// Sample `n` is at `n / 16000` seconds of the source file: no offset, no drift.
struct TrackAudio: AudioSampleSource {
    static let sampleRate = 16_000

    let sampleCount: Int
    private let samples: Data
    let fileURL: URL

    var duration: TimeInterval { Double(sampleCount) / Double(Self.sampleRate) }

    /// Accepts any PCM file AVFoundation reads; multichannel input is downmixed, not reduced to channel 0.
    init(converting url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw TrackAudioError.unsupportedFormat("\(input)")
        }
        converter.downmix = true

        fileURL = FileManager.default.temporaryDirectory.appending(path: "mm2t-track-\(UUID().uuidString).f32")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw TrackAudioError.conversionFailed("cannot create \(fileURL.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let written = try Self.convert(file, with: converter, into: handle)
            // AVAudioConverter can end a sample short of the exact rate ratio; pad so the
            // count, and so the last timestamp, matches the source duration.
            let expected = Int((Double(file.length) * Double(Self.sampleRate) / input.sampleRate).rounded())
            if written < expected {
                try handle.write(contentsOf: Data(count: (expected - written) * MemoryLayout<Float>.size))
            }
            try handle.synchronize()
            let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
            samples = data
            sampleCount = min(data.count / MemoryLayout<Float>.size, max(expected, 0))
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        let start = max(0, offset)
        let available = min(sampleCount - start, count)
        guard available > 0 else { return }
        samples.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            destination.update(from: floats.baseAddress!.advanced(by: start), count: available)
        }
    }

    func samples(from offset: Int, count: Int) -> [Float] {
        let available = max(0, min(sampleCount - offset, count))
        return [Float](unsafeUninitializedCapacity: available) { buffer, initialized in
            try? copySamples(into: buffer.baseAddress!, offset: offset, count: available)
            initialized = available
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func convert(_ file: AVAudioFile, with converter: AVAudioConverter, into handle: FileHandle) throws -> Int {
        let capacity: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(
                    (Double(capacity) * converter.outputFormat.sampleRate / file.processingFormat.sampleRate)
                        .rounded(.up)) + 1024)
        else { throw TrackAudioError.conversionFailed("cannot allocate conversion buffers") }

        var readError: Error?
        var exhausted = false
        var written = 0
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if exhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let remaining = AVAudioFrameCount(clamping: max(0, file.length - file.framePosition))
                do {
                    inputBuffer.frameLength = 0
                    if remaining > 0 { try file.read(into: inputBuffer, frameCount: min(capacity, remaining)) }
                } catch {
                    readError = error
                    inputBuffer.frameLength = 0
                }
                guard inputBuffer.frameLength > 0 else {
                    exhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let readError { throw TrackAudioError.conversionFailed(String(describing: readError)) }
            if let conversionError { throw TrackAudioError.conversionFailed(conversionError.localizedDescription) }
            let frames = Int(outputBuffer.frameLength)
            if frames > 0, let channel = outputBuffer.floatChannelData?[0] {
                try handle.write(contentsOf: Data(bytes: channel, count: frames * MemoryLayout<Float>.size))
                written += frames
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && exhausted) { break }
        }
        return written
    }
}
