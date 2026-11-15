@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Seeks directly to requested spans in a growing, flushed PCM track. Opening a reader for each
/// span keeps AVAudioFile state out of cross-actor calls and never reads the whole recording.
struct SpanAudioSource: AudioSampleSource {
    let url: URL
    let sampleCount: Int

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
            throw TrackAudioError.unsupportedFormat("streaming voiceprints require 16 kHz mono PCM")
        }
        self.url = url
        sampleCount = Int(file.length)
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        let start = max(0, offset)
        let available = min(count, sampleCount - start)
        guard available > 0 else { return }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = AVAudioFramePosition(start)
        let capacity = min(available, 16_384)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(capacity)) else {
            throw TrackAudioError.conversionFailed("cannot allocate voiceprint span")
        }
        var copied = 0
        while copied < available {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(capacity, available - copied)))
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
                throw TrackAudioError.conversionFailed("incomplete voiceprint span")
            }
            let read = Int(buffer.frameLength)
            destination.advanced(by: copied).update(from: channel, count: read)
            copied += read
        }
    }
}
