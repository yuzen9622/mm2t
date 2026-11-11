import Foundation
import MM2TCore
import MM2TSystem
import Testing
@testable import MM2TApp

@MainActor @Suite struct RecoveryTests {
    /// What a crash leaves: tracks flushed but never finished, and a manifest without a duration.
    func crashedSession(in recordings: URL, highlight: TimeInterval = 3) throws -> URL {
        let directory = recordings.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = RecordingManifest(title: "當機的會議", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         platform: .teams, targetBundleID: "com.microsoft.teams2")
        manifest.highlights = [highlight]
        try manifest.write(to: directory)
        for name in [RecordingManifest.micFile, RecordingManifest.remoteFile] {
            let writer = try WAVWriter(url: directory.appending(path: name), sampleRate: 16_000)
            writer.appendSilence(frames: 16_000 * 5)
            try writer.flush()
        }
        return directory
    }

    @Test func anInterruptedRecordingIsRepairedAtLaunchAndOfferedNotProcessed() async throws {
        let world = try World()
        let crashed = try crashedSession(in: world.app.paths.recordings)

        await world.app.launch(watchMeetings: false)

        let id = try #require(world.app.recovered.first)
        #expect(world.app.recovered == [id])
        let meeting = try await world.library.meeting(id)
        #expect(meeting.metadata.title == "當機的會議")
        #expect(abs(meeting.metadata.duration - 5) < 0.01)
        #expect(meeting.highlights == [Highlight(time: 3)])
        #expect(meeting.status == .pending(next: .transcribe))
        #expect(world.catalog.providerCalls == 0, "offered, not uploaded behind the user's back")
        #expect(!FileManager.default.fileExists(atPath: crashed.path))
        #expect(world.app.meetings.rows.map(\.status) == [.notProcessed])

        await world.app.processRecovered(id)
        #expect(world.app.recovered.isEmpty)
        #expect(try await world.library.meeting(id).status == .completed)
    }

    @Test func aMeetingLeftUnprocessedByAQuitIsOfferedAgain() async throws {
        let world = try World(keys: false)
        let meeting = try await world.recordedMeeting()
        let relaunched = try AppController(
            paths: world.app.paths, defaults: world.defaults, credentials: world.credentials, catalog: world.catalog,
            recorder: world.recorder, permissions: world.permissions, installer: FakeInstaller(world.catalog.modelsDownloaded),
            validator: world.validator)
        await relaunched.launch(watchMeetings: false)
        #expect(relaunched.recovered == [meeting.id])
    }

    @Test func aRecordingThatStoppedButNeverReachedTheLibraryIsImported() async throws {
        let world = try World()
        let directory = try crashedSession(in: world.app.paths.recordings)
        var manifest = try RecordingManifest.read(from: directory)
        manifest.duration = 5
        try manifest.write(to: directory)

        await world.app.launch(watchMeetings: false)
        #expect(world.app.recovered.count == 1)
        #expect(world.app.recoveryFailures.isEmpty)
    }

    @Test func anUnreadableSessionIsReportedAndLeftOnDisk() async throws {
        let world = try World()
        let directory = world.app.paths.recordings.appending(path: "broken")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appending(path: RecordingManifest.fileName))
        try Data().write(to: directory.appending(path: RecordingManifest.micFile))

        await world.app.launch(watchMeetings: false)
        #expect(world.app.recovered.isEmpty)
        #expect(world.app.recoveryFailures.keys.map(\.lastPathComponent) == ["broken"])
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
