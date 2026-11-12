import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

/// "Records" by writing a prepared clip when recording starts.
final class FakeVoiceRecorder: VoiceSampleRecording, @unchecked Sendable {
    let clip = Box<[Int16]>([])
    func start(to url: URL) throws { try WAVFormat.write(WAVAudio(sampleRate: 16_000, samples: clip.get), to: url) }
    var level: Double { 0.5 }
    func stop() {}
}

@MainActor @Suite struct VoiceEnrollmentTests {
    static let passage = "今天我要開始用這個工具記錄會議"
    static let speech = [Int16](repeating: 5000, count: 16_000 * 8)

    func model(_ world: World, clip: [Int16], heard: String?, embeddings: [Embedding]? = [Embedding([0, 1, 0])]) -> VoiceEnrollmentModel {
        let recorder = FakeVoiceRecorder()
        recorder.clip.set(clip)
        return VoiceEnrollmentModel(
            voiceprints: world.app.voiceprints, recorder: recorder, permissions: world.permissions,
            scratch: world.root.appending(path: "enrollment.wav"),
            transcribe: { _ in heard }, embed: { _, _ in embeddings })
    }

    func read(_ model: VoiceEnrollmentModel) async {
        await model.start()
        await model.finish(passage: Self.passage, name: "我")
    }

    @Test func aLooseReadingOfThePassageBecomesTheUsersVoiceprint() async throws {
        let world = try World()
        let model = model(world, clip: Self.speech, heard: "今天我要開始用這工具紀錄會議")
        await read(model)

        #expect(model.state == .enrolled && model.hasVoice)
        let user = try #require(await world.app.voiceprints.user())
        #expect(user.name == "我" && user.embeddings == [Embedding([0, 1, 0], channel: .room)])
        #expect(!FileManager.default.fileExists(atPath: world.root.appending(path: "enrollment.wav").path), "the reading itself is not kept")
    }

    @Test func otherWordsOrTooLittleSpeechAreTurnedAway() async throws {
        let world = try World()
        let wrong = model(world, clip: Self.speech, heard: "天氣很好我們去吃飯")
        await read(wrong)
        #expect(wrong.state == .rejected(.differentWords))

        let short = model(world, clip: [Int16](repeating: 5000, count: 16_000 * 2), heard: nil)
        await read(short)
        #expect(short.state == .rejected(.tooShort))
        #expect(await world.app.voiceprints.user() == nil)
    }

    @Test func withoutSpeechRecognitionTheWordsAreNotChecked() async throws {
        let world = try World()
        let model = model(world, clip: Self.speech, heard: nil)
        await read(model)
        #expect(model.state == .enrolled)
    }

    @Test func theSpeakerModelMustBeDownloadedFirst() async throws {
        let world = try World()
        let model = model(world, clip: Self.speech, heard: nil, embeddings: nil)
        await read(model)
        #expect(model.state == .rejected(.modelMissing))
    }

    @Test func theAppIsLockedUntilSetupIsDoneAndTheUserHasAVoice() async throws {
        let world = try World()
        #expect(world.app.needsOnboarding)
        world.app.completeOnboarding()
        #expect(world.app.needsOnboarding, "finishing setup is not enough without a voice")
        try await world.app.voiceprints.enrollUser(name: "我", embeddings: [Embedding([0, 1, 0])])
        await world.app.enrollment.refresh()
        #expect(!world.app.needsOnboarding)
    }
}
