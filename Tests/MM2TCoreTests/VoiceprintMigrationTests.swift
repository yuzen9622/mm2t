import Foundation
import Testing
@testable import MM2TCore

/// A later voiceprint model: each scripted voice comes back one value longer, so no vector of the
/// earlier model compares with it.
private struct NextModelEmbedder: SpeakerEmbedder {
    let dimensions = 4
    let calls = Box(0)
    let fails = Box(false)
    let scripted = ScriptedEmbedder()

    static func next(_ embedding: Embedding) -> Embedding { Embedding(embedding.values + [0.5]) }

    func embeddings(track: URL, segments: [Diarization.Segment]) async throws -> [ClusterID: [Embedding]] {
        calls.update { $0 += 1 }
        if fails.get { throw LocalModelError() }
        return try await scripted.embeddings(track: track, segments: segments).mapValues { $0.map(Self.next) }
    }
}

@Suite struct VoiceprintMigrationTests {
    @Test func aNamedVoiceIsRebuiltFromItsMeetingAndWhatNoMeetingHoldsIsDropped() async throws {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([0, 1, 0]).heard(on: .room)])
        let meeting = try await world.processed()
        let r2 = SpeakerID("r2")
        let old = try #require(meeting.speaker(r2)).embeddings
        _ = try await world.editing.rename(r2, in: meeting.id, to: .newPerson(name: "Carol"))

        let embedder = NextModelEmbedder()
        let migration = VoiceprintMigration(library: world.library, voiceprints: world.voiceprints, embedder: embedder)
        #expect(try await migration.isNeeded())
        let outcome = try await migration.run()

        let migrated = try await world.library.meeting(meeting.id)
        let expected = old.map { NextModelEmbedder.next($0).heard(on: .call) }
        #expect(migrated.speaker(r2)?.embeddings == expected)
        #expect(migrated.speakers.flatMap(\.embeddings).allSatisfy { $0.values.count == 4 && $0.channel == .call })
        #expect(await world.voiceprints.person(named: "Carol")?.embeddings == expected, "learned voice follows its meeting")
        #expect(await world.voiceprints.person(world.aliceID)?.embeddings == [], "no meeting taught Alice's vector")
        let user = try #require(await world.voiceprints.user())
        #expect(user.embeddings.count == 1 && user.embeddings.allSatisfy { $0.values.count == 4 && $0.channel == .room },
                "the user's voice comes back from what the mic heard on the call")
        #expect(outcome == .init(meetings: 1, unreadable: 0, dropped: 3, userCalls: 1))

        #expect(try await migration.isNeeded() == false)
        let calls = embedder.calls.get
        #expect(try await migration.run() == .init())
        #expect(embedder.calls.get == calls, "a finished migration reads no audio again")
    }

    @Test func withNoCallToRebuildFromTheUserEnrollsAgain() async throws {
        let world = try await World()
        world.cloud.roomOnly.update { $0 = true }
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding([0, 1, 0]).heard(on: .room)])
        _ = try await world.processed()

        let outcome = try await VoiceprintMigration(
            library: world.library, voiceprints: world.voiceprints, embedder: NextModelEmbedder()).run()

        #expect(outcome.userCalls == 0)
        #expect(await world.voiceprints.user()?.embeddings == [], "a room recording's \"me\" came from the old voiceprint, not the user")
    }

    @Test func theUsersCallVoiceLeavesOutMomentsTheCallWasTalking() {
        let clean = VoiceprintMigration.subtracting(
            [TimeRange(start: 2, end: 3), TimeRange(start: 9, end: 20)],
            from: [TimeRange(start: 0, end: 5), TimeRange(start: 8, end: 10)])
        #expect(clean == [TimeRange(start: 0, end: 2), TimeRange(start: 3, end: 5), TimeRange(start: 8, end: 9)])
    }

    @Test func progressCountsEveryMeetingToRebuild() async throws {
        let world = try await World()
        _ = try await world.processed()
        _ = try await world.processed()
        let seen = Box<[[Int]]>([])

        _ = try await VoiceprintMigration(
            library: world.library, voiceprints: world.voiceprints, embedder: NextModelEmbedder()
        ).run { done, total in seen.update { $0.append([done, total]) } }

        #expect(seen.get == [[0, 2], [1, 2], [2, 2]])
    }

    @Test func aSpeakerMergedWithSomeoneTheMicHeardKeepsTheirCallVoice() async throws {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding(SharedRoomCallTests.me)])
        world.diarizer.micOnCall.update { $0 = SharedRoomCallTests.mic(other: [Embedding(bob)]) }
        let meeting = try await world.processed()
        let r2 = SpeakerID("r2")
        let call = try #require(meeting.speaker(r2)).embeddings
        _ = try await world.editing.merge(SpeakerID("r4"), into: r2, in: meeting.id)

        _ = try await VoiceprintMigration(
            library: world.library, voiceprints: world.voiceprints, embedder: NextModelEmbedder()).run()

        let migrated = try #require(try await world.library.meeting(meeting.id).speaker(r2))
        #expect(migrated.embeddings.filter { $0.channel == .call } == call.map { NextModelEmbedder.next($0).heard(on: .call) })
        #expect(migrated.embeddings.contains { $0.channel == .room })
    }

    @Test func aMeetingWhoseRecordingIsGoneLosesItsOldVectorsInsteadOfRetryingEachLaunch() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        _ = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .newPerson(name: "Carol"))
        try FileManager.default.removeItem(at: await world.library.audioURL(meeting, track: .remote))
        let migration = VoiceprintMigration(library: world.library, voiceprints: world.voiceprints, embedder: NextModelEmbedder())

        #expect(try await migration.run().unreadable == 1)
        #expect(try await world.library.meeting(meeting.id).speakers.allSatisfy { $0.embeddings.isEmpty })
        #expect(await world.voiceprints.person(named: "Carol")?.embeddings == [])
        #expect(try await migration.isNeeded() == false)
    }

    @Test func aModelFailureStopsTheRunWithNothingLostSoTheNextLaunchRetries() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        let renamed = try await world.editing.rename(SpeakerID("r2"), in: meeting.id, to: .newPerson(name: "Carol"))
        let learned = await world.voiceprints.person(named: "Carol")?.embeddings
        let embedder = NextModelEmbedder()
        embedder.fails.update { $0 = true }
        let migration = VoiceprintMigration(library: world.library, voiceprints: world.voiceprints, embedder: embedder)

        await #expect(throws: (any Error).self) { try await migration.run() }
        #expect(try await world.library.meeting(meeting.id).speakers == renamed.speakers)
        #expect(await world.voiceprints.person(named: "Carol")?.embeddings == learned)
        #expect(try await migration.isNeeded())
    }
}
