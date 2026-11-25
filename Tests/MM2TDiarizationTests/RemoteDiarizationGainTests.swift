import FluidAudio
import Testing
@testable import MM2TDiarization

struct RemoteDiarizationGainTests {
    private struct Samples: AudioSampleSource {
        var values: [Float]
        var sampleCount: Int { values.count }

        func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) {
            values.withUnsafeBufferPointer {
                destination.update(from: $0.baseAddress!.advanced(by: offset), count: count)
            }
        }
    }

    @Test func uniformlyQuietSpeechIsRaisedWithoutClipping() throws {
        let audio = Samples(values: .init(repeating: 0.01, count: 3200) + [0.099])
        let gain = try RemoteDiarizationGain.measure(in: audio)
        #expect(gain > 9.9)
        #expect(0.099 * gain <= 0.9991)
    }

    @Test func aNormalPeakOrSilenceLeavesTheScaleUnchanged() throws {
        let quiet = [Float](repeating: 0.005, count: 3200)
        #expect(try RemoteDiarizationGain.measure(in: Samples(values: quiet + [0.65])) == 1)
        #expect(try RemoteDiarizationGain.measure(in: Samples(values: .init(repeating: 0, count: 3200))) == 1)
    }
}
