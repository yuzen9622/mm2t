import Foundation
import MM2TCore
import Testing
@testable import MM2TDiarization

@Suite struct ModelAvailabilityTests {
    private func emptyStore() throws -> DiarizationModels {
        DiarizationModels(directory: try temporaryDirectory())
    }

    private func silentTrack(seconds: Double) throws -> URL {
        let url = try temporaryDirectory().appending(path: "remote.wav")
        try writeAudio([[Float](repeating: 0, count: Int(seconds * 16_000))], sampleRate: 16_000, to: url,
                       settings: wavSettings(sampleRate: 16_000, channels: 1, float: false))
        return url
    }

    @Test func anEmptyDirectoryHasNoModels() throws {
        #expect(try emptyStore().isDownloaded == false)
    }

    @Test func applicationSupportIsTheAppDefault() {
        #expect(DiarizationModels.applicationSupport.directory.path.hasSuffix("Application Support/mm2t/Models"))
    }

    @Test func diarizingWithoutModelsFailsWithATypedErrorAndNeverDownloads() async throws {
        let store = try emptyStore()
        let diarizer = NemotronDiarizer(models: store, embedder: WeSpeakerEmbedder(models: store))

        await #expect(throws: DiarizationModelError.missing(directory: store.directory)) {
            try await diarizer.diarize(track: try silentTrack(seconds: 1))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    @Test func speakersWithTooLittleCleanSpeechGetNoVoiceprintRatherThanANoisyOne() async throws {
        let store = try emptyStore()
        let embedder = WeSpeakerEmbedder(models: store)
        let track = try silentTrack(seconds: 60)

        // 7 s and 6 s of clean 2-8 s pieces: below the rule, so the model is not even needed.
        let short = try await embedder.embeddings(track: track, segments: [
            segment("speaker_0", 0, 7), segment("speaker_1", 7, 13), segment("speaker_1", 40, 41.5),
        ])
        #expect(short.isEmpty)

        // One 8 s piece clears it, so the embedder now has to load the model, and says it is missing.
        await #expect(throws: DiarizationModelError.missing(directory: store.directory)) {
            try await embedder.embeddings(track: track, segments: [segment("speaker_0", 0, 9)])
        }
    }

    @Test func pipelineDefaultsAreTheEvaluationThresholds() {
        #expect(MatchThresholds.weSpeaker == MatchThresholds(autoName: 0.70, suggest: 0.70, user: 0.60))
    }
}
