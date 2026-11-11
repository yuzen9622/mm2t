import Foundation
import Testing
@testable import MM2TDiarization

@Suite struct TrackAudioTests {
    struct Format: CustomTestStringConvertible, Sendable {
        let sampleRate: Double
        let channels: Int
        let float: Bool
        var testDescription: String { "\(Int(sampleRate)) Hz x\(channels) \(float ? "float32" : "int16")" }
    }

    /// Writes clicks at `times` and returns the converted track.
    private func convert(
        _ format: Format, duration: TimeInterval, clicks times: [TimeInterval], onlyLastChannel: Bool = false
    ) throws -> TrackAudio {
        let count = Int(duration * format.sampleRate)
        var signal = [Float](repeating: 0, count: count)
        for time in times { signal[Int((time * format.sampleRate).rounded())] = 0.9 }
        let silent = [Float](repeating: 0, count: count)
        let channels = (0..<format.channels).map { onlyLastChannel && $0 < format.channels - 1 ? silent : signal }
        let url = try temporaryDirectory().appending(path: "track.wav")
        try writeAudio(channels, sampleRate: format.sampleRate, to: url,
                       settings: wavSettings(sampleRate: format.sampleRate, channels: format.channels, float: format.float))
        return try TrackAudio(converting: url)
    }

    private func peak(in audio: TrackAudio, near time: TimeInterval) -> (index: Int, value: Float) {
        let center = Int(time * 16_000)
        let window = audio.samples(from: center - 320, count: 641)
        let best = window.indices.max { abs(window[$0]) < abs(window[$1]) }!
        return (center - 320 + best, abs(window[best]))
    }

    @Test(arguments: [
        Format(sampleRate: 48_000, channels: 2, float: true),
        Format(sampleRate: 44_100, channels: 1, float: false),
        Format(sampleRate: 16_000, channels: 1, float: false),
        Format(sampleRate: 24_000, channels: 2, float: false),
    ])
    func conversionKeepsEveryEventAtItsTime(_ format: Format) throws {
        let clicks = [0.5, 3.25, 17.003, 59.9]
        let audio = try convert(format, duration: 60, clicks: clicks)
        defer { audio.remove() }

        #expect(audio.sampleCount == 960_000, "60 s is 960,000 samples at 16 kHz")
        for time in clicks {
            let found = peak(in: audio, near: time)
            #expect(abs(found.index - Int((time * 16_000).rounded())) <= 1,
                    "click at \(time) s landed \(Double(found.index) / 16 - time * 1000) ms off")
            #expect(found.value > 0.2)
        }
    }

    @Test func noDriftAcrossTenMinutesOfCDRateAudio() throws {
        let audio = try convert(Format(sampleRate: 44_100, channels: 1, float: false), duration: 600, clicks: [1, 599.5])
        defer { audio.remove() }

        #expect(audio.sampleCount == 9_600_000)
        #expect(abs(peak(in: audio, near: 599.5).index - 9_592_000) <= 1)
    }

    @Test func stereoIsDownmixedSoSpeechOnOneSideIsKept() throws {
        let audio = try convert(Format(sampleRate: 48_000, channels: 2, float: true), duration: 5, clicks: [2],
                                onlyLastChannel: true)
        defer { audio.remove() }

        #expect(peak(in: audio, near: 2).value > 0.1, "a right-channel-only click survives at half level, not dropped with the channel")
    }

    @Test func removeDeletesTheTemporaryCopy() throws {
        let audio = try convert(Format(sampleRate: 16_000, channels: 1, float: false), duration: 1, clicks: [])
        #expect(FileManager.default.fileExists(atPath: audio.fileURL.path))
        audio.remove()
        #expect(!FileManager.default.fileExists(atPath: audio.fileURL.path))
    }
}
