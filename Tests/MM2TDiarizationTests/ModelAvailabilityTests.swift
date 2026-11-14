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

    @Test func pipelineDefaultsKeepSuggestionsSeparateFromAutomaticNames() {
        #expect(MatchThresholds.weSpeaker == MatchThresholds(autoName: 0.70, suggest: 0.60, user: 0.60))
    }

    @Test func defaultMatchingSuggestsWithoutLearningAndStillAutoNames() async throws {
        let store = try VoiceprintStore(fileURL: temporaryDirectory().appending(path: "voiceprints.json"))
        let enrolled = Embedding([1, 0])
        let person = try await store.addPerson(name: "Known speaker", embeddings: [enrolled])
        for score: Float in [0.59, 0.60, 0.65, 0.6953087, 0.699, 0.70, 0.701, 0.80] {
            let candidate = Embedding([score, (1 - score * score).squareRoot()])
            let similarity = candidate.cosineSimilarity(to: enrolled)
            let result = await store.match([candidate], thresholds: .weSpeaker)
            if similarity >= 0.70 {
                #expect(result == .autoName(person, similarity: similarity))
            } else if similarity >= 0.60 {
                #expect(result == .suggest(person, similarity: similarity))
            } else {
                #expect(result == .none)
            }
        }
        #expect(await store.match([], thresholds: .weSpeaker) == .none)
        #expect(await store.person(person)?.embeddings == [enrolled])
    }
}
