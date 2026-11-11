import Foundation
import Testing
@testable import MM2TCore

@Suite struct MeetingLibraryTests {
    @Test func listsNewestFirstAndSearchesTitleTextAndNames() async throws {
        let world = try await World()
        let old = try await world.pipeline.process(world.record(title: "Kickoff", startedAt: Date(timeIntervalSince1970: 1)).id)
        let new = try await world.record(title: "Retro", startedAt: Date(timeIntervalSince1970: 2))

        #expect(try await world.library.list().map(\.id) == [new.id, old.id])
        let names = await world.voiceprints.names()
        #expect(try await world.library.search("retro", names: names).map(\.id) == [new.id])
        #expect(try await world.library.search("同意", names: names).map(\.id) == [old.id])
        #expect(try await world.library.search("alice", names: names).map(\.id) == [old.id])
        #expect(try await world.library.search("nothing like this", names: names).isEmpty)
    }

    @Test func deleteRemovesTheDocumentAndBothAudioTracks() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        let audio = await Track.allCases.asyncMap { await world.library.audioURL(meeting, track: $0) }
        #expect(audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        try await world.library.delete(meeting.id)

        #expect(audio.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try await world.library.list().isEmpty)
        await #expect(throws: LibraryError.unknownMeeting(meeting.id)) {
            try await world.library.meeting(meeting.id)
        }
    }

    @Test func aProcessedMeetingRoundTripsThroughDisk() async throws {
        let world = try await World()
        let meeting = try await world.processed()
        #expect(try await world.library.meeting(meeting.id) == meeting)
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}
