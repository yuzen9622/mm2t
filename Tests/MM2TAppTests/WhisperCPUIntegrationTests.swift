import AVFoundation
import Foundation
import MM2TApp
import MM2TCore
import MM2TDiarization
import MM2TLocal
import Testing

struct WhisperCPUIntegrationTests {
    private static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["MM2T_CPU_MODELS"] != nil && environment["MM2T_CPU_AUDIO"] != nil))
    func installedCPUModelProducesTimedWordsAndSettledMandarinCaptions() async throws {
        let root = URL(filePath: try #require(Self.environment["MM2T_CPU_MODELS"]))
        let audio = URL(filePath: try #require(Self.environment["MM2T_CPU_AUDIO"]))
        let catalog = LiveProviderCatalog(models: DiarizationModels(directory: root), transcriptionModel: .breezeMLX(in: root),
                                          llmModel: .qwen35(in: root), translationModels: .mozilla(in: root),
                                          machine: MachineProfile(isAppleSilicon: false, memoryBytes: 16 << 30))
        #expect(catalog.localTranscription(model: .breeze, language: .chinese) == nil)
        #expect(catalog.localStreamingTranscription(model: .breeze, alongsideBreeze: false) == nil)
        let fileProvider = try #require(catalog.localTranscription(model: .whisperCPU, language: .chinese))
        let words = try await fileProvider.transcribe(audio: audio, hints: [], labelSpeakers: false).words
        let text = Alignment.joined(words)
        let expected = Self.environment["MM2T_CPU_EXPECTED"] ?? "法"
        #expect(text.contains(expected))
        #expect(Set(words.map(\.range.start)).count > 3)
        let file = try AVAudioFile(forReading: audio)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        let rate = Int(file.processingFormat.sampleRate)
        let provider = try #require(catalog.localStreamingTranscription(model: .whisperCPU, alongsideBreeze: false))
        let session = try await provider.open(.init(languageCode: "zh", hints: [], sampleRate: rate))
        try await session.send(samples + Array(repeating: 0, count: rate))
        let textEvents = Task {
            var text = ""
            for try await event in session.events {
                if case .final(let settled) = event { text += settled }
                if text.contains(expected) { break }
            }
            return text
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(60))
            await session.close()
        }
        defer { timeout.cancel() }
        let settled = try await textEvents.value
        await session.close()
        #expect(settled.contains(expected))
        print("CPU file: \(words.count) timed words; CPU final caption: \(settled)")
    }
}
