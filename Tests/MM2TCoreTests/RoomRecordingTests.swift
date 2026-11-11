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
}
