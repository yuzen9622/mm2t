import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

/// Answers each piece with one word spanning the first second of the file it was given.
struct PieceSTT: TranscriptionProvider {
    let files = Box<[String]>([])
    let fails = Box(false)

    func transcribe(audio: URL, hints: [String], labelSpeakers: Bool) async throws -> TranscribedWords {
        files.update { $0.append(audio.lastPathComponent) }
        if fails.get { throw TranscriptionError.failed("no credit") }
        let seconds = try WAVFormat.read(audio).duration
        return .unlabeled([TimedWord(String(format: "%.0fs", seconds), 0, 1)])
    }
}

@Suite struct LiveTranscriptionTests {
    static let rate = 1000

    /// `seconds` of a loud tone with a silent half-second ending at each of `quietEnds`.
    static func tone(_ seconds: Int, quietEnds: [Double] = []) -> [Int16] {
        (0..<seconds * rate).map { frame in
            let time = Double(frame) / Double(rate)
            if quietEnds.contains(where: { time >= $0 - 0.5 && time < $0 }) { return 0 }
            return frame % 2 == 0 ? 8000 : -8000
        }
    }

    func recording(mic: [Int16], remote: [Int16]) throws -> (directory: URL, mic: URL, remote: URL) {
        let directory = try temporaryDirectory()
        let micURL = directory.appending(path: "mic.wav"), remoteURL = directory.appending(path: "remote.wav")
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: mic), to: micURL)
        try WAVFormat.write(WAVAudio(sampleRate: Self.rate, samples: remote), to: remoteURL)
        return (directory, micURL, remoteURL)
    }

    func transcriber(_ files: (directory: URL, mic: URL, remote: URL), _ stt: PieceSTT) -> LiveTranscriber {
        LiveTranscriber(mic: files.mic, remote: files.remote, chain: TranscriptionChain([.init(.cloud, stt)]),
                        hints: [], scratch: files.directory.appending(path: "scratch"), pieceSeconds: 20)
    }

    @Test func piecesAreCutAtQuietPlacesAndTimedFromTheStart() async throws {
        let files = try recording(mic: Self.tone(50, quietEnds: [17, 33]), remote: [Int16](repeating: 0, count: 50 * Self.rate))
        let stt = PieceSTT()
        let live = transcriber(files, stt)

        await live.advance()
        #expect(abs(await live.transcribedSeconds - 32.65) < 0.01, "two pieces, each ended in the quiet half-second")
        let transcription = try #require(await live.finish(mic: files.mic, remote: files.remote))

        let starts = transcription.me.words.map(\.range.start)
        #expect(starts.count == 3)
        #expect(abs(starts[1] - 16.65) < 0.01 && abs(starts[2] - 32.65) < 0.01)
        #expect(transcription.remote.words.isEmpty)
        #expect(stt.files.get.allSatisfy { $0.hasPrefix("me-") }, "a silent track is never uploaded")
        #expect(!FileManager.default.fileExists(atPath: files.directory.appending(path: "scratch").path))
    }

    @Test func aRecordingShorterThanAPieceIsTranscribedWholeAtTheEnd() async throws {
        let files = try recording(mic: Self.tone(8), remote: Self.tone(8))
        let stt = PieceSTT()
        let live = transcriber(files, stt)

        await live.advance()
        #expect(stt.files.get.isEmpty)
        let transcription = try #require(await live.finish(mic: files.mic, remote: files.remote))
        #expect(transcription.me.words.map(\.text) == ["8s"])
        #expect(transcription.remote.words.map(\.text) == ["8s"])
    }

    @Test func aFailedPieceMeansNoLiveTranscription() async throws {
        let files = try recording(mic: Self.tone(30), remote: Self.tone(30))
        let stt = PieceSTT()
        stt.fails.set(true)
        let live = transcriber(files, stt)

        await live.advance()
        #expect(await live.finish(mic: files.mic, remote: files.remote) == nil)
    }

    @MainActor @Test func wordsHeardWhileRecordingLetProcessingStartAtSpeakerSeparation() async throws {
        let world = try World()
        let meeting = try await world.recordedMeeting()
        let fresh = try await world.library.create(Recording(
            micTrack: try copy(await world.library.audioURL(meeting, track: .me)),
            remoteTrack: try copy(await world.library.audioURL(meeting, track: .remote)),
            highlights: [], metadata: MeetingMetadata(title: "現場", startedAt: Date(), duration: 10)))
        let heard = Transcription(
            me: TrackTranscript(source: .cloud, content: .unlabeled([TimedWord("软件", 0, 1)])),
            remote: TrackTranscript(source: .cloud, content: .unlabeled([])))

        let attached = try await world.library.attach(heard, to: fresh.id)
        #expect(attached.status == .pending(next: .diarize))
        #expect(attached.transcription?.me.words.map(\.text) == ["軟件"])
        #expect(try await world.library.attach(heard, to: meeting.id).status == .completed, "a processed meeting is left alone")
    }

    private func copy(_ url: URL) throws -> URL {
        let target = try temporaryDirectory().appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }
}
