import Foundation
import Testing
@testable import MM2TCore

/// The voiceprint store learns only from what the user confirms, and remembers how each voice was heard.
@Suite struct VoiceLearningTests {
    /// The room-only Script with the user's cluster (c2) too short to store a voiceprint from.
    static func shortUserTurns() -> Diarization {
        let script = Script.diarization, c2 = ClusterID("c2")
        return Diarization(segments: script.segments, overlaps: script.overlaps,
                           embeddings: script.embeddings.filter { $0.key != c2 }, briefEmbeddings: [c2: script.embeddings[c2]!])
    }

    @Test func inAShortRoomRecordingTheUserIsFoundByTheirBriefVoice() async throws {
        let world = try await World(diarization: Self.shortUserTurns())
        world.cloud.roomOnly.update { $0 = true }
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([0, 1, 0])])
        let meeting = try await world.processed()

        #expect(meeting.utterances.map(\.speaker.rawValue) == ["r1", "me", "r3", "r1"])
        #expect(meeting.speakers.map(\.id.rawValue) == ["r1", "r3"])
    }

    @Test func briefVoicesNameNobodyElse() async throws {
        let script = Script.diarization, c1 = ClusterID("c1")
        let world = try await World(diarization: Diarization(
            segments: script.segments, overlaps: script.overlaps,
            embeddings: script.embeddings.filter { $0.key != c1 }, briefEmbeddings: [c1: script.embeddings[c1]!]))
        world.cloud.roomOnly.update { $0 = true }
        let meeting = try await world.processed()

        #expect(meeting.speaker(SpeakerID("r1"))?.person == nil, "too little speech to name Alice by")
    }

    @Test func vectorsRememberWhetherTheyWereHeardInTheRoomOrOnACall() async throws {
        let world = try await World()
        let call = try await world.processed()
        #expect(call.speakers.flatMap(\.embeddings).allSatisfy { $0.channel == .call })

        _ = try await world.editing.rename(SpeakerID("r2"), in: call.id, to: .existing(world.aliceID))
        #expect(await world.voiceprints.person(world.aliceID)?.channels == [.call])

        world.cloud.roomOnly.update { $0 = true }
        let room = try await world.processed()
        #expect(room.speakers.flatMap(\.embeddings).allSatisfy { $0.channel == .room })
    }

    @Test func aClaimedSpeakerBecomesTheUserAndTeachesTheirVoiceprint() async throws {
        let world = try await World()
        world.cloud.roomOnly.update { $0 = true }
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([0, 1, 0]).heard(on: .room)])
        let meeting = try await world.processed()
        let r3 = try #require(meeting.speaker(SpeakerID("r3")))

        let claimed = try await world.editing.claimAsMe(r3.id, in: meeting.id)

        #expect(claimed.utterances.filter { $0.speaker == .me }.count == 2)
        #expect(!claimed.speakers.contains { $0.id == r3.id })
        #expect(claimed.resolve(r3.id) == .me)
        #expect(claimed.outputs.isStale)
        let user = try #require(await world.voiceprints.user())
        #expect(r3.embeddings.allSatisfy(user.embeddings.contains))
        #expect(try await world.library.meeting(meeting.id).utterances == claimed.utterances)
    }

    @Test func aCallsRemoteSpeakerCannotBeClaimedAsTheUser() async throws {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([0, 1, 0])])
        let meeting = try await world.processed()

        await #expect(throws: SpeakerEditError.notHeardOnMic(SpeakerID("r1"))) {
            try await world.editing.claimAsMe(SpeakerID("r1"), in: meeting.id)
        }
        #expect(await world.voiceprints.user()?.embeddings.count == 1)
    }

    @Test func vectorsStoredBeforeChannelsStillLoad() throws {
        let old = try JSONDecoder().decode([Embedding].self, from: Data("[[1,0,0.5]]".utf8))
        #expect(old == [Embedding([1, 0, 0.5])] && old[0].channel == nil)

        let tagged = [Embedding([0.25, 1], channel: .call), Embedding([1])]
        let data = try JSONEncoder().encode(tagged)
        #expect(try JSONDecoder().decode([Embedding].self, from: data) == tagged)
        #expect(String(decoding: data, as: UTF8.self).contains("[1]"), "untagged vectors keep the old form")
    }
}
