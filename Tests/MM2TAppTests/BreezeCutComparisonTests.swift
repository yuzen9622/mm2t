import Foundation
import MM2TCore
@testable import MM2TLocal
import WhisperKit
import MM2TSystem
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_BREEZE_CUT_DIR"] != nil))
func compareBreezeCuts() async throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(filePath: try #require(env["MM2T_BREEZE_CUT_DIR"]))
    let models = URL(filePath: try #require(env["MM2T_LOCAL_MODELS"]))
    let provider = LocalTranscription(model: .breeze(in: models))
    let clock = ContinuousClock()
    let cold = clock.now
    try await provider.prepare()
    let ready = clock.now
    try await provider.prepare()
    print("PREPARE cold=\(cold.duration(to: ready)) warm=\(ready.duration(to: clock.now))")
    if let tracks = env["MM2T_BREEZE_TRACKS_DIR"] {
        let input = URL(filePath: tracks)
        for span in [28.85..<52.0, 3595.0..<3600.0] {
            let range = Int((span.lowerBound * 16_000).rounded())..<Int((span.upperBound * 16_000).rounded())
            let mine = try WAVFormat.read(input.appending(path: "mic-full.wav"), frames: range).samples
            let remote = try WAVFormat.read(input.appending(path: "remote-full.wav"), frames: range).samples
            let cleaned = EchoCanceller.clean(mic: mine, remote: remote, sampleRate: 16_000)?.samples ?? mine
            let pcm = [cleaned, remote].map { $0.map { Float($0) / 32768 } }
            for parallel in [false, true, true, false] {
                let start = clock.now
                let results: [[TimedWord]]
                if parallel {
                    results = try await provider.transcribeTracks(pcm, hints: [])
                } else {
                    var output: [[TimedWord]] = []
                    for samples in pcm { output += try await provider.transcribeTracks([samples], hints: []) }
                    results = output
                }
                print("TRACKS start=\(span.lowerBound) parallel=\(parallel) elapsed=\(start.duration(to: clock.now)) counts=\(results.map(\.count))")
            }
        }
    }
    if env["MM2T_BREEZE_TRACKS_ONLY"] == "1" { return }
    let fixedThirty = env["MM2T_BREEZE_FIXED_30"] == "1"
    let windows = fixedThirty ? [30] : (env["MM2T_BREEZE_WHOLE_CLIP_ONLY"] == "1" ? [60] : [10, 4])
    for clip in ["mandarin", "mixed"] {
        let audio = try WAVFormat.read(root.appending(path: "\(clip).wav"))
        for seconds in windows {
            let cutStarted = clock.now
            var start = 0, words: [TimedWord] = []
            while start < audio.samples.count {
                let window = seconds * audio.sampleRate
                var end = min(start + window, audio.samples.count)
                if !fixedThirty && end < audio.samples.count {
                    let low = end - window / 2
                    let samples = Array(audio.samples[low..<end])
                    let offset = QuietCut.index(mic: Array(repeating: 0, count: samples.count), remote: samples, window: audio.sampleRate * 3 / 10)
                    let grid = audio.sampleRate / 20
                    end = ((low + offset + grid / 2) / grid) * grid
                }
                let samples = Array(audio.samples[start..<end])
                if fixedThirty && QuietCut.isSilent(samples) { start = end; continue }
                let pcm = samples.map { Float($0) / 32768 }
                let output = try await provider.transcribeTracks([pcm], hints: [])
                words += try #require(output.first)
                start = end
            }
            print("CUT clip=\(clip) window=\(seconds) elapsed=\(cutStarted.duration(to: clock.now))")
            try TraditionalChinese.convert(Alignment.joined(words)).write(to: root.appending(path: "\(clip)-\(seconds).txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// Measures whether decoder retries alone account for the delay on the voiced final five seconds.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_BREEZE_TAIL_PROBE"] != nil))
func compareBreezeTailRetries() async throws {
    let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["MM2T_BREEZE_TAIL_PROBE"]))
    let folder = LocalTranscriptionModel.breeze(in: root.appending(path: "Models")).snapshot.directory
    let whisper = try await WhisperKit(WhisperKitConfig(
        modelFolder: folder.path, tokenizerFolder: folder,
        computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndNeuralEngine),
        verbose: false, prewarm: false, load: true, download: false))
    let frames = (3595 * 16_000)..<(3600 * 16_000)
    let mine = try WAVFormat.read(root.appending(path: "mic-full.wav"), frames: frames).samples
    let remote = try WAVFormat.read(root.appending(path: "remote-full.wav"), frames: frames).samples
    let clean = EchoCanceller.clean(mic: mine, remote: remote, sampleRate: 16_000)?.samples ?? mine
    let pcm = [clean, remote].filter { !QuietCut.isSilent($0) }.map { $0.map { Float($0) / 32768 } }
    for retries in [3, 0, 0, 3] {
        var options = DecodingOptions(task: .transcribe, language: nil, temperatureFallbackCount: retries,
            usePrefillPrompt: true, detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        options.concurrentWorkerCount = pcm.count
        let start = ContinuousClock.now
        let results = await whisper.transcribeWithResults(audioArrays: pcm, decodeOptions: options)
        let words = try results.map { WhisperEngine.words(try $0.get().flatMap(\.segments)) }
        print("TAIL retries=\(retries) elapsed=\(start.duration(to: .now)) counts=\(words.map(\.count)) text=\(words.map(Alignment.joined))")
    }
}
