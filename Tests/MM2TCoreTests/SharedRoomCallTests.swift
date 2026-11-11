import Foundation
import Testing
@testable import MM2TCore

/// A call taken where the mic hears more than the user: colleagues beside them, and the call
/// itself out of the speakers.
@Suite struct SharedRoomCallTests {
    static let me: [Float] = [0, 1, 0]

    /// The user says "Thanks", then someone else on the same mic says "all".
    static func mic(other: [Embedding], brief: [Embedding] = []) -> Diarization {
        let user = ClusterID("m1"), neighbour = ClusterID("m2")
        return Diarization(
            segments: [.init(cluster: user, range: TimeRange(start: 50, end: 50.5)),
                       .init(cluster: neighbour, range: TimeRange(start: 50.5, end: 51))],
            overlaps: [],
            embeddings: other.isEmpty ? [user: [Embedding(me)]] : [user: [Embedding(me)], neighbour: other],
            briefEmbeddings: brief.isEmpty ? [:] : [neighbour: brief])
    }

    func world(mic: Diarization) async throws -> World {
        let world = try await World()
        try await world.voiceprints.enrollUser(name: "Me", embeddings: [Embedding(Self.me)])
        world.diarizer.micOnCall.update { $0 = mic }
        return world
    }

    @Test func someoneBesideTheUserIsASpeakerOfTheirOwnAndNamedByVoiceprint() async throws {
        let world = try await world(mic: Self.mic(other: [Embedding(bob)]))
        let meeting = try await world.processed()

        #expect(meeting.utterances.suffix(2).map(\.speaker.rawValue) == ["me", "r4"])
        #expect(meeting.utterances.suffix(2).map(\.text) == ["Thanks", "all"])
        #expect(meeting.speakers.map(\.label) == ["A", "B", "C", "D"])
        #expect(meeting.speaker(SpeakerID("r4"))?.person == world.bobID)
        #expect(meeting.separatedTrack == nil)
    }

    @Test func aBriefVoiceIsToldFromTheUserButLeavesNoVoiceprint() async throws {
        let world = try await world(mic: Self.mic(other: [], brief: [Embedding(bob)]))
        let meeting = try await world.processed()

        #expect(meeting.utterances.last?.speaker == SpeakerID("r4"))
        let neighbour = try #require(meeting.speaker(SpeakerID("r4")))
        #expect(neighbour.embeddings.isEmpty && neighbour.person == nil)
    }

    @Test func aVoiceTooShortToTellStaysTheUsers() async throws {
        let world = try await world(mic: Self.mic(other: []))
        let meeting = try await world.processed()

        #expect(meeting.utterances.last?.speaker == .me)
        #expect(meeting.utterances.last?.text == "Thanks all")
        #expect(meeting.speakers.count == 3 && meeting.micSegments == nil)
    }

    @Test func withoutAnEnrolledUserTheMicIsNotSeparated() async throws {
        let world = try await World()
        world.diarizer.micOnCall.update { $0 = Self.mic(other: [Embedding(bob)]) }
        let meeting = try await world.processed()

        #expect(meeting.utterances.last?.speaker == .me)
        #expect(world.diarizer.calls.get == 1)
    }

    @Test func wordsTheMicOnlyHeardFromTheSpeakersAreDropped() async throws {
        let world = try await world(mic: Self.mic(other: [Embedding(bob)]))
        world.micCleaner.update { $0 = ScriptedCleaner(echo: TimeRange(start: 50.4, end: 51.2)) }
        let meeting = try await world.processed()

        #expect(meeting.transcription?.me.words.map(\.text) == ["Thanks"])
        #expect(world.cloud.calls.get.last?.file.hasPrefix("mic-clean-") == true, "speech recognition hears the cleaned mic")
        #expect(meeting.utterances.last?.speaker == .me)
        #expect(meeting.speakers.map(\.label) == ["A", "B", "C"], "a voice with no words left is not a speaker")
        let directory = await world.library.audioURL(meeting, track: .me).deletingLastPathComponent()
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!left.contains { $0.hasPrefix("mic-clean-") })
    }

    @Test func mergingARoomSpeakerMovesTheirMicSegments() async throws {
        let world = try await world(mic: Self.mic(other: [Embedding(bob)]))
        let meeting = try await world.processed()
        let merged = try await world.editing.merge(SpeakerID("r4"), into: SpeakerID("r1"), in: meeting.id)

        #expect(merged.micSegments?.map(\.speaker.rawValue) == ["me", "r1"])
    }
}
