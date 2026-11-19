import AVFoundation
import Foundation
import MM2TCore
import MM2TLocal
import Testing

/// Opt-in hardware benchmark. Inputs and raw transcripts stay in the supplied directory.
@Suite(.serialized) struct SpeechComparisonTests {
    static let env = ProcessInfo.processInfo.environment

    struct Caption: Codable {
        let seconds: Double
        let final: Bool
        let text: String
    }

    @Test(.enabled(if: env["MM2T_SPEECH_COMPARISON"] != nil))
    func compareOnDevice() async throws {
        let root = URL(filePath: Self.env["MM2T_SPEECH_COMPARISON"]!)
        let breeze = LocalTranscription(model: .breeze(in: URL(filePath: try #require(Self.env["MM2T_LOCAL_MODELS"]))))
        let parakeet = ParakeetTranscription(directory: root.appending(path: "parakeet"))
        for (name, provider) in [("breeze", breeze as any TranscriptionProvider), ("parakeet", parakeet)] {
            for run in 1...3 {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await provider.transcribe(audio: root.appending(path: "english.wav"), hints: [], labelSpeakers: false)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                try save([Caption(seconds: elapsed, final: true, text: Alignment.joined(result.words))],
                         to: root.appending(path: "\(name)-english-\(run).json"))
                #expect(!result.words.isEmpty)
            }
        }

        let nemotron = NemotronTranscription(directory: root.appending(path: "nemotron"), language: "zh")
        for clip in ["mandarin", "mixed"] {
            let file = try AVAudioFile(forReading: root.appending(path: "\(clip).wav"))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            for (name, provider) in [("breeze", WindowedStreamingTranscription(breeze) as any StreamingTranscriptionProvider), ("nemotron", nemotron)] {
                let events = try await replay(samples, provider: provider, language: "zh")
                try save(events, to: root.appending(path: "\(name)-\(clip).json"))
                #expect(events.contains { $0.final && $0.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } })
            }
        }
    }

    @Test(.enabled(if: env["MM2T_INSTALLED_SPEECH_MODELS"] != nil))
    func transcribesFromInstalledSnapshots() async throws {
        let models = URL(filePath: Self.env["MM2T_INSTALLED_SPEECH_MODELS"]!)
        let audio = URL(filePath: try #require(Self.env["MM2T_COMPARISON_AUDIO"]))
        for choice in [LocalSpeechModel.parakeet, .nemotron] {
            let snapshot = choice.snapshot(in: models)
            #expect(snapshot.isDownloaded)
            let provider: any TranscriptionProvider
            let clip: String
            if choice == .parakeet {
                provider = ParakeetTranscription(directory: snapshot.directory)
                clip = "english.wav"
            } else {
                provider = NemotronTranscription(directory: snapshot.directory, language: "zh")
                clip = "mixed.wav"
            }
            let result = try await provider.transcribe(audio: audio.appending(path: clip), hints: [], labelSpeakers: false)
            let text = Alignment.joined(result.words)
            #expect(!text.isEmpty && !text.contains("<unk>"))
            #expect(result.words.allSatisfy { $0.range.end >= $0.range.start })
            #expect(zip(result.words, result.words.dropFirst()).allSatisfy { $0.range.start <= $1.range.start })
            try text.write(to: audio.appending(path: "installed-\(choice.rawValue).txt"), atomically: true, encoding: .utf8)
        }
    }

    @Test(.enabled(if: env["MM2T_LIVE_COMPARISON"] != nil))
    func compareLiveCaptionsAndTaiwaneseTranscripts() async throws {
        let root = URL(filePath: Self.env["MM2T_LIVE_COMPARISON"]!)
        let models = URL(filePath: try #require(Self.env["MM2T_LOCAL_MODELS"]))
        let breeze = LocalTranscription(model: .breeze(in: models))
        let parakeet = ParakeetTranscription(directory: LocalSpeechModel.parakeet.snapshot(in: models).directory)
        let nemoDirectory = LocalSpeechModel.nemotron.snapshot(in: models).directory

        for clip in ["mandarin", "mixed", "english"] {
            let url = root.appending(path: "\(clip).wav")
            let language = clip == "english" ? "en" : "zh"
            let nemotron = NemotronTranscription(directory: nemoDirectory, language: language)
            let file = try AVAudioFile(forReading: url)
            #expect(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let providers: [(String, any StreamingTranscriptionProvider)] = [
                ("nemotron", nemotron), ("parakeet", WindowedStreamingTranscription(parakeet)), ("breeze", WindowedStreamingTranscription(breeze))]
            for (name, provider) in providers {
                let events = try await replay(samples, provider: provider, language: language)
                try save(events, to: root.appending(path: "\(name)-\(clip).json"))
                if clip == "english" || name != "parakeet" {
                    #expect(events.contains { $0.final && !$0.text.isEmpty })
                }
            }
            if clip != "english" {
                let result = try await nemotron.transcribe(audio: url, hints: [], labelSpeakers: false)
                try JSONEncoder().encode(result.words).write(to: root.appending(path: "words-\(clip).json"))
                try Alignment.joined(result.words).write(to: root.appending(path: "transcript-\(clip).txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    /// Gives the windowed decoder extra time after the last audio packet to settle outstanding work.
    @Test(.enabled(if: env["MM2T_BREEZE_DRAIN_COMPARISON"] != nil))
    func measuresBreezeThroughFinalCaption() async throws {
        let root = URL(filePath: Self.env["MM2T_BREEZE_DRAIN_COMPARISON"]!)
        let models = URL(filePath: try #require(Self.env["MM2T_LOCAL_MODELS"]))
        let breeze = LocalTranscription(model: .breeze(in: models))
        // A complete first decode distinguishes steady-state performance from first use.
        _ = try await breeze.transcribe(audio: root.appending(path: "english.wav"), hints: [], labelSpeakers: false)
        for clip in ["mandarin", "mixed", "english"] {
            let file = try AVAudioFile(forReading: root.appending(path: "\(clip).wav"))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let events = try await replay(samples, provider: WindowedStreamingTranscription(breeze),
                                          language: clip == "english" ? "en" : "zh", drain: .seconds(15))
            try save(events, to: root.appending(path: "breeze-drained-\(clip).json"))
            #expect(events.contains { $0.final && !$0.text.isEmpty })
        }
    }

    private func replay(_ samples: [Float], provider: any StreamingTranscriptionProvider, language: String, drain: Duration = .seconds(3)) async throws -> [Caption] {
        let session = try await provider.open(.init(languageCode: language, hints: [], sampleRate: 16_000))
        let clock = ContinuousClock()
        let origin = clock.now
        let start = ProcessInfo.processInfo.systemUptime
        let collector = Task {
            var events = [Caption]()
            for try await event in session.events {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                switch event {
                case .partial(let text): events.append(Caption(seconds: elapsed, final: false, text: text))
                case .final(let text): events.append(Caption(seconds: elapsed, final: true, text: text))
                }
            }
            return events
        }
        let padded = samples + Array(repeating: Float.zero, count: 32_000)
        for offset in stride(from: 0, to: padded.count, by: 1600) {
            let end = min(offset + 1600, padded.count)
            try await clock.sleep(until: origin.advanced(by: .seconds(Double(end) / 16_000)))
            try await session.send(Array(padded[offset..<end]))
        }
        try await Task.sleep(for: drain)
        await session.close()
        return try await collector.value
    }

    private func save(_ events: [Caption], to url: URL) throws {
        try JSONEncoder().encode(events).write(to: url, options: .atomic)
    }
}
