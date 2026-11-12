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

    @Test func aSecondVoiceWithNoVectorAtAllIsStillSomeoneElse() async throws {
        let world = try await world(mic: Self.mic(other: []))
        let meeting = try await world.processed()

        #expect(meeting.utterances.suffix(2).map(\.speaker.rawValue) == ["me", "r4"])
        #expect(meeting.speaker(SpeakerID("r4"))?.embeddings.isEmpty == true)
    }

    @Test func howMuchAVoiceSpeaksDoesNotMakeItTheUser() async throws {
        // Nothing sounds like the enrollment: the voice heard most is someone else all the same,
        // and the one too short for any vector stays the user's.
        let talker = ClusterID("m1"), quiet = ClusterID("m2")
        let world = try await world(mic: Diarization(
            segments: [.init(cluster: quiet, range: TimeRange(start: 50, end: 50.5)),
                       .init(cluster: talker, range: TimeRange(start: 50.5, end: 51)),
                       .init(cluster: talker, range: TimeRange(start: 52, end: 58))],
            overlaps: [], embeddings: [talker: [Embedding([0.7, 0.1, 0.7])]]))
        let meeting = try await world.processed()

        #expect(meeting.utterances.suffix(2).map(\.speaker.rawValue) == ["me", "r4"])
        #expect(meeting.speakers.count == 4)
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
        #expect(meeting.micSegments == nil, "with that voice gone only the user is left on the mic")
        let directory = await world.library.audioURL(meeting, track: .me).deletingLastPathComponent()
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!left.contains { $0.hasPrefix("mic-clean-") })
    }

    @Test func aVoiceThatWentAwayWithTheEchoWasTheSpeakersEvenWithNobodyEnrolled() async throws {
        let world = try await World()
        // Too short a stretch for the word around it to count as echo by itself.
        let played = TimeRange(start: 50.5, end: 50.9)
        world.micCleaner.update { $0 = ScriptedCleaner(echo: played) }
        world.diarizer.micOnCall.update {
            $0 = Diarization(
                segments: [.init(cluster: ClusterID("m1"), range: TimeRange(start: 50, end: 50.5)),
                           .init(cluster: ClusterID("m2"), range: played)],
                overlaps: [], embeddings: [:])
        }
        let meeting = try await world.processed()

        #expect(meeting.transcription?.me.words.map(\.text) == ["Thanks"])
        #expect(meeting.utterances.last?.text == "Thanks" && meeting.utterances.last?.speaker == .me)
        #expect(meeting.speakers.count == 3 && meeting.micSegments == nil)
    }

    @Test func micWordsThatRepeatTheRemoteTrackAreTheCallHeardTwice() {
        let remote = [TimedWord("更", 2.6, 2.8), TimedWord("多", 2.8, 3), TimedWord("的", 3, 3.1), TimedWord("，", 3.1, 3.1),
                      TimedWord("產", 3.2, 3.4), TimedWord("品", 3.4, 3.6), TimedWord("好", 9, 9.2)]
        let echoed = [TimedWord("更", 2.7, 2.9), TimedWord("多", 2.9, 3.1), TimedWord("的", 3.1, 3.2), TimedWord("。", 3.2, 3.2),
                      TimedWord("產", 3.3, 3.5), TimedWord("品", 3.5, 3.7)]
        let own = [TimedWord("好", 9.1, 9.3), TimedWord("的", 9.3, 9.4), TimedWord("更", 30, 30.2), TimedWord("多", 30.2, 30.4)]

        #expect(Alignment.dropping(repeatsOf: remote, from: echoed + own) == own, "agreeing briefly, or the same words much later, is not an echo")
        #expect(Alignment.dropping(repeatsOf: [], from: echoed) == echoed)

        let agreeing = (0..<4).map { TimedWord("對", 9 + Double($0) * 0.2, 9.1 + Double($0) * 0.2) }
        #expect(Alignment.dropping(repeatsOf: [TimedWord("對", 9, 9.2)], from: agreeing) == agreeing, "one word heard is not four words repeated")
    }

    @Test func mergingARoomSpeakerMovesTheirMicSegments() async throws {
        let world = try await world(mic: Self.mic(other: [Embedding(bob)]))
        let meeting = try await world.processed()
        let merged = try await world.editing.merge(SpeakerID("r4"), into: SpeakerID("r1"), in: meeting.id)

        #expect(merged.micSegments?.map(\.speaker.rawValue) == ["me", "r1"])
    }
}
