import Foundation
import MM2TCore
import MM2TLocal
import MM2TSystem
import Testing
@testable import MM2TApp

/// Accelerated replay. Prefix files omit the last seconds of the corresponding full files.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_BREEZE_FINISH_DIR"] != nil))
func breezeStopToSavedTranscript() async throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(filePath: try #require(env["MM2T_BREEZE_FINISH_DIR"]))
    let models = URL(filePath: try #require(env["MM2T_LOCAL_MODELS"]))
    let provider = LocalTranscription(model: .breeze(in: models), language: .auto)
    let run = root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    let library = MeetingLibrary(root: run.appending(path: "meetings"))
    let mic = run.appending(path: "mic.wav"), remote = run.appending(path: "remote.wav")
    for track in ["mic", "remote"] {
        try FileManager.default.copyItem(at: root.appending(path: "\(track)-full.wav"), to: run.appending(path: "\(track).wav"))
    }
    let seconds = Double(try WAVFormat.frameCount(remote)) / 16_000
    let live = LiveTranscriber(mic: root.appending(path: "mic-prefix.wav"), remote: root.appending(path: "remote-prefix.wav"),
        chain: TranscriptionChain([.init(.local, provider)]), hints: [], scratch: run.appending(path: "pieces"),
        pieceSeconds: LiveTranscriber.breezePieceSeconds)
    let clock = ContinuousClock()
    let started = clock.now
    await live.advance()
    let covered = await live.transcribedSeconds
    #expect(covered >= seconds - 20)
    let stop = clock.now
    await live.prepareForMove()
    let meeting = try await library.create(Recording(micTrack: mic, remoteTrack: remote, highlights: [],
        metadata: MeetingMetadata(title: "Breeze timing", startedAt: Date(), duration: seconds)))
    let transcript = try #require(await live.finish(mic: library.audioURL(meeting, track: .me),
                                                    remote: library.audioURL(meeting, track: .remote)))
    try await library.attach(transcript, to: meeting.id)
    let saved = clock.now
    let persisted = try await library.meeting(meeting.id)
    let stored = try #require(persisted.transcription)
    let preview = stored.trackPreview(duration: seconds)
    let ready = clock.now
    #expect(!preview.isEmpty)
    #expect(stored.me.words.count == transcript.me.words.count)
    #expect(stored.remote.words.count == transcript.remote.words.count)
    #expect(await live.transcribedSeconds == seconds)
    print("BREEZE_RESULT audio=\(seconds) covered=\(covered) prefixWall=\(started.duration(to: stop)) stopToSaved=\(stop.duration(to: saved)) stopToReadableRows=\(stop.duration(to: ready)) rows=\(preview.count) micWords=\(transcript.me.words.count) remoteWords=\(transcript.remote.words.count)")
}
