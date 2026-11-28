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
            segments: [.init(cluster: user, range: TimeRange(start: 48.5, end: 50.5)),
                       .init(cluster: neighbour, range: TimeRange(start: 50.5, end: 52.5))],
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
            segments: [.init(cluster: quiet, range: TimeRange(start: 48.5, end: 50.5)),
                       .init(cluster: talker, range: TimeRange(start: 50.5, end: 52.5)),
                       .init(cluster: talker, range: TimeRange(start: 52, end: 58))],
            overlaps: [], embeddings: [talker: [Embedding([0.7, 0.1, 0.7])]]))
        let meeting = try await world.processed()

        #expect(meeting.utterances.suffix(2).map(\.speaker.rawValue) == ["me", "r4"])
        #expect(meeting.speakers.count == 4)
    }

    @Test func withoutAnEnrolledUserTwoMicClustersAreNotAssumedToBeMe() async throws {
        let world = try await World()
        world.diarizer.micOnCall.update { $0 = Self.mic(other: [Embedding(bob)]) }
        let meeting = try await world.processed()

        #expect(meeting.utterances.suffix(2).allSatisfy { $0.speaker != .me })
        #expect(meeting.utterances.suffix(2).map(\.text) == ["Thanks", "all"])
        #expect(world.diarizer.calls.get == 1 && world.diarizer.micCalls.get == 1)
    }

    @Test func wordsTheMicOnlyHeardFromTheSpeakersAreDropped() async throws {
        let world = try await world(mic: Self.mic(other: [Embedding(bob)]))
        world.micCleaner.update { $0 = ScriptedCleaner(echo: TimeRange(start: 50.5, end: 52.5)) }
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
        let laterEcho = TimeRange(start: 53, end: 55)
        world.micCleaner.update { $0 = ScriptedCleaner(echo: played, additionalEcho: laterEcho) }
        world.diarizer.micOnCall.update {
            $0 = Diarization(
                segments: [.init(cluster: ClusterID("m1"), range: TimeRange(start: 48.5, end: 50.5)),
                           .init(cluster: ClusterID("m2"), range: played),
                           .init(cluster: ClusterID("m2"), range: laterEcho)],
                overlaps: [], embeddings: [:])
        }
        let meeting = try await world.processed()

        #expect(meeting.transcription?.me.words.map(\.text) == ["Thanks"])
        #expect(meeting.utterances.last?.text == "Thanks" && meeting.utterances.last?.speaker != .me)
        #expect(meeting.speakers.count == 4 && meeting.micSegments != nil)
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

    @Test func playbackWithDifferentTokenBoundariesKeepsSimultaneousLocalSpeech() async throws {
        let near = [TimedWord("我在講話", 2, 2.1), TimedWord("wait", 2.1, 2.2)]
        let remote = [TimedWord("The", 0.5, 0.8), TimedWord("J-space", 1, 1.4), TimedWord("after", 1.5, 1.8),
                      TimedWord("the", 2.3, 2.5), TimedWord("Jacobian", 2.6, 2.9), TimedWord("was", 3, 3.2),
                      TimedWord("found", 3.3, 3.6)]
        let mic = [remote[0], TimedWord("J", 1, 1.1), TimedWord("space", 1.2, 1.4), remote[2]] + near
            + [remote[3], TimedWord("Jacobi", 2.6, 2.9), remote[5], remote[6]]
        let power = [Float](repeating: 0.1, count: 100)
        var cleaned = power
        for frame in 15..<33 { cleaned[frame] /= 10 }
        let echo = EchoProfile(frameDuration: 0.05, before: power, after: cleaned, remote: power)
        let headphones = EchoProfile(frameDuration: 0.05, before: power, after: power, remote: power)
        #expect(PlaybackTranscript.echoes(mic: mic, remote: remote, profile: headphones).isEmpty)
        let world = try await World()
        let record = try await world.record()
        let tracks = Transcription(me: TrackTranscript(source: .local, content: .unlabeled(mic)),
                                   remote: TrackTranscript(source: .local, content: .unlabeled(remote)))
        let turns = Diarization(segments: [.init(cluster: ClusterID("near"), range: TimeRange(start: 0, end: 4))],
                                overlaps: [], embeddings: [:])
        try await world.pipeline.attachRecording(tracks, diarizations: [.me: turns, .remote: turns], echo: echo, to: record.id)
        let saved = try await world.library.meeting(record.id)
        #expect(saved.utterances.filter { $0.speaker == .me }.flatMap(\.words) == near)
        #expect(saved.utterances.filter { $0.speaker != .me }.flatMap(\.words) == remote)
        #expect(saved.transcription?.me.words == mic)
    }

    @Test func mergingARoomSpeakerMovesTheirMicSegments() async throws {
        let world = try await world(mic: Self.mic(other: [Embedding(bob)]))
        let meeting = try await world.processed()
        let merged = try await world.editing.merge(SpeakerID("r4"), into: SpeakerID("r1"), in: meeting.id)

        #expect(merged.micSegments?.map(\.speaker.rawValue) == ["me", "r1"])
    }
}
