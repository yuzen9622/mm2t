import Foundation
import Testing
@testable import MM2TCore

@Suite struct RoomRecordingTests {
    @Test func aMeetingHeardOnlyOnTheMicHasItsVoicesToldApart() async throws {
        let world = try await World()
        world.cloud.roomOnly.update { $0 = true }
        let meeting = try await world.processed()

        #expect(meeting.status == .completed)
        #expect(meeting.separatedTrack == .me)
        #expect(meeting.speakers.map(\.label) == ["A", "B", "C"])
        #expect(meeting.utterances.map(\.speaker.rawValue) == ["r1", "r2", "r3", "r1"])
        #expect(meeting.speaker(SpeakerID("r1"))?.person == world.aliceID)
        // The mic is the track asked for speaker labels, so the fallback source works too.
        #expect(world.cloud.calls.get.map(\.labelSpeakers) == [true, true])
    }

    @Test func aMeetingWithRemoteSpeechKeepsTheMicAsMe() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        #expect(meeting.separatedTrack == nil)
        #expect(meeting.utterances.last?.speaker == .me)
        #expect(world.cloud.calls.get.map(\.labelSpeakers) == [true, false])
    }

    @Test func theSummaryNamesTheMeetingUnlessTheUserAlreadyDid() async throws {
        let world = try await World()
        world.llm.title.update { $0 = "软件检讨" }
        let meeting = try await world.processed()
        #expect(meeting.metadata.title == "軟件檢討")

        var renamed = try await world.record()
        renamed.metadata.title = "My name"
        renamed.metadata.titleEdited = true
        try await world.library.save(renamed)
        #expect(try await world.pipeline.process(renamed.id).metadata.title == "My name")
    }

    @Test func nothingTheModelWritesStaysInSimplifiedChinese() async throws {
        let world = try await World()
        let meeting = try await world.processed()

        #expect(meeting.outputs.summary?.headline == "討論軟件")
        #expect(meeting.outputs.summary?.terms == ["mm2t", "軟件"])
    }

    @Test func theCleanupSeesKnownNamesAndTheVocabulary() async throws {
        let world = try await World()
        _ = try await world.processed()

        #expect(world.llm.glossaries.get == [["Alice", "Bob", "mm2t"]])
    }

    @Test func hostedServicesWorkAtOnceAndARetryRunsFromTheEarliestFailure() async throws {
        let world = try await World()
        world.runsConcurrently.update { $0 = true }
        world.llm.failNext.update { $0 = ["digestPerPerson"] }
        let failed = try await world.processed()

        guard case .failed(.digestPerPerson, _) = failed.status else {
            Issue.record("expected the digest to fail, got \(failed.status)")
            return
        }
        #expect(failed.outputs.cleaned != nil && failed.outputs.summary != nil, "what finished is kept")
        #expect(world.cloud.calls.get.map(\.labelSpeakers) == [true, true])

        let done = try await world.pipeline.process(failed.id)
        #expect(done.status == .completed)
        #expect(done.outputs.digests != nil)
        #expect(Set(world.llm.calls.get.suffix(2)) == ["digestPerPerson", "summarize"], "only the failed step and those after it run again")
    }

    @Test func inARoomTheSpeakerWhoSoundsLikeTheEnrolledUserIsMe() async throws {
        let world = try await World()
        world.cloud.roomOnly.update { $0 = true }
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([0, 1, 0])])
        let meeting = try await world.processed()

        #expect(meeting.utterances.map(\.speaker.rawValue) == ["r1", "me", "r3", "r1"])
        #expect(meeting.speakers.map(\.id.rawValue) == ["r1", "r3"])
        #expect(meeting.speakers.map(\.label) == ["A", "B"])
        #expect(await world.voiceprints.spokenNames() == ["Alice", "Bob"], "the user's entry is not a name to listen for")
    }

    @Test func onACallTheEnrolledUserIsNeverMatchedToARemoteSpeaker() async throws {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([0, 1, 0])])
        let meeting = try await world.processed()

        #expect(meeting.speakers.count == 3)
        let user = try #require(await world.voiceprints.user()).id
        #expect(meeting.speakers.allSatisfy { $0.person != user })
        #expect(meeting.suggestions.items.allSatisfy { $0.voiceprintPerson != user })
    }

    @Test(arguments: [
        ("今天我要開始用這個工具記錄會議。", "今天我要开始用这个工具记录会议", 1.0),
        ("今天我要開始用這個工具記錄會議。", "今天我要開始用這工具紀錄會議", 0.8),
        ("今天我要開始用這個工具記錄會議。", "天氣很好我們去吃飯", 0.13),
        ("Hello, world!", "hello world", 1.0),
    ])
    func aReadingIsJudgedByHowMuchOfThePassageWasHeard(passage: String, heard: String, atLeast: Double) {
        let coverage = ReadAloud.coverage(of: passage, in: heard)
        #expect(coverage >= atLeast - 0.01 && coverage <= atLeast + 0.15)
    }

    @Test func speechIsCountedByLoudFramesOnly() {
        let loud = [Int16](repeating: 4000, count: 16_000 * 3), quiet = [Int16](repeating: 20, count: 16_000 * 4)
        #expect(abs(ReadAloud.speechSeconds(loud + quiet, sampleRate: 16_000) - 3) < 0.05)
    }
}
