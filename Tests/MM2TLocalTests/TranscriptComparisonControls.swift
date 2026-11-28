import FluidAudio
import Foundation
import MM2TCore
@testable import MM2TLocal
import Testing

@Suite struct TranscriptComparisonControls {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_ASR_CONTROLS"] != nil))
    func validateConversionAgainstRawDecoder() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MM2T_ASR_CONTROLS"]!)
        let models = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MM2T_LOCAL_MODELS"]!)
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: LocalSpeechModel.nemotron.snapshot(in: models).directory.appending(path: "multilingual/1120ms"))
        await manager.setLanguage("zh-CN")
        var milliseconds: [Double] = []
        for clip in ["mandarin", "mixed"] {
            let samples = try AudioConverter().resampleAudioFile(root.appending(path: "\(clip).wav"))
            var offset = 0
            while offset < samples.count {
                let end = min(offset + 160_000, samples.count)
                _ = try await manager.process(samples: Array(samples[offset..<end]))
                offset = end
            }
            let result = try await manager.finishWithTokenTimings()
            let raw = buildWordTimings(from: result.timings).map { TimedWord($0.word, $0.startTime, $0.endTime) }
            try JSONEncoder().encode(raw).write(to: root.appending(path: "raw-words-\(clip).json"))
            let formatted = try JSONDecoder().decode([TimedWord].self, from: Data(contentsOf: root.appending(path: "words-\(clip).json")))
            #expect(formatted.map(\.range) == raw.map(\.range))
            #expect(formatted == TaiwaneseTranscript.convert(raw, language: "zh"))
            let before = Alignment.joined(raw)
            let after = Alignment.joined(formatted)
            try before.write(to: root.appending(path: "raw-transcript-\(clip).txt"), atomically: true, encoding: .utf8)
            #expect(before.replacing(/\p{script=Han}+/, with: "") == after.replacing(/\p{script=Han}+/, with: ""))
            await manager.reset()
            let prior = root.deletingLastPathComponent().appending(path:"asr-comparison/nemotron-\(clip).json")
            let events = try JSONDecoder().decode([SpeechComparisonTests.Caption].self, from: Data(contentsOf: prior))
            for _ in 0..<10 {
                for event in events where !event.text.isEmpty {
                    let start = ProcessInfo.processInfo.systemUptime
                    let converted = TaiwaneseTranscript.convert(event.text, language: "zh")
                    milliseconds.append((ProcessInfo.processInfo.systemUptime - start)*1000)
                    #expect(!converted.isEmpty)
                }
            }
        }
        try JSONEncoder().encode(milliseconds).write(to: root.appending(path: "format-ms.json"))
    }
}
