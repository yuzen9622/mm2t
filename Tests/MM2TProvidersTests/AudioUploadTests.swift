import AVFoundation
import Foundation
import Testing
@testable import MM2TProviders

@Suite struct AudioUploadTests {
    /// A 440 Hz tone, so the encoder has real signal to compress rather than silence.
    func toneWAV(seconds: Double, sampleRate: Int = 16000) -> Data {
        var data = silentWAV(seconds: seconds, sampleRate: sampleRate)
        let samples = Int(seconds * Double(sampleRate))
        for i in 0..<samples {
            let value = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate)))
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange((44 + i * 2)..<(46 + i * 2), with: $0) }
        }
        return data
    }

    @Test func wavIsSentAsAACOfTheSameLength() throws {
        let wav = testScratch.appending(path: "upload-\(UUID().uuidString)/remote.wav")
        try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = toneWAV(seconds: 10)
        try original.write(to: wav)

        let upload = try AudioFile.upload(wav, for: .selfHosted)

        #expect(upload.filename == "remote.m4a")
        #expect(upload.mimeType == "audio/mp4")
        #expect(upload.data.count * 4 < original.count)
        let decoded = wav.deletingLastPathComponent().appending(path: "decoded.m4a")
        try upload.data.write(to: decoded)
        let file = try AVAudioFile(forReading: decoded)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(abs(Double(file.length) / 16000 - 10) < 0.2)
    }

    @Test func otherFormatsAreSentUnchanged() throws {
        let m4a = try audioFile("mic.m4a")
        let upload = try AudioFile.upload(m4a, for: .selfHosted)
        #expect(upload.filename == "mic.m4a")
        #expect(upload.data == (try Data(contentsOf: m4a)))
    }
}
