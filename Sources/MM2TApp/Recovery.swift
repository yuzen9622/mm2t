import Foundation
import MM2TCore
import MM2TSystem

/// Recordings left in the recordings folder by a crash, a sleep that never woke, or a stop whose
/// move into the library failed. At launch each one is repaired and moved into the library, then
/// offered for processing rather than processed, since processing uploads audio.
public struct RecordingRecoveryScanner: Sendable {
    public let recordingsDirectory: URL
    public let library: MeetingLibrary

    public init(recordingsDirectory: URL, library: MeetingLibrary) {
        self.recordingsDirectory = recordingsDirectory
        self.library = library
    }

    public struct Outcome: Equatable, Sendable {
        public var recovered: [MeetingID] = []
        /// Directories that could not be read or repaired, with why; left untouched on disk.
        public var failures: [URL: String] = [:]
    }

    /// Call before any new recording starts, since it treats every session in the folder as finished.
    public func recoverAll() async -> Outcome {
        var outcome = Outcome()
        let files = FileManager.default
        let directories = (try? files.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        for directory in directories.sorted(by: { $0.path < $1.path })
        where files.fileExists(atPath: directory.appending(path: RecordingManifest.fileName).path) {
            guard files.fileExists(atPath: directory.appending(path: RecordingManifest.micFile).path) else {
                // Only the manifest is left: the tracks already reached the library.
                try? files.removeItem(at: directory)
                continue
            }
            guard !Self.isEmpty(directory) else {
                // Nothing was captured (the app died as recording began); there is nothing to recover.
                try? files.removeItem(at: directory)
                continue
            }
            do {
                let recording = RecordingRecovery.isInterrupted(directory)
                    ? try RecordingRecovery.recover(directory)
                    : try RecordingManifest.read(from: directory).cleanRecording(in: directory)
                let meeting = try await library.create(recording)
                try? files.removeItem(at: directory)
                outcome.recovered.append(meeting.id)
            } catch {
                outcome.failures[directory] = String(describing: error)
            }
        }
        return outcome
    }

    /// Both tracks exist and are only their WAV header: recording began and captured nothing.
    static func isEmpty(_ directory: URL) -> Bool {
        [RecordingManifest.micFile, RecordingManifest.remoteFile].allSatisfy { file in
            let size = (try? directory.appending(path: file).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return size.map { $0 <= 44 } ?? false
        }
    }

    /// Meetings already in the library whose processing never finished or never started.
    public func unprocessedMeetings() async -> [MeetingID] {
        ((try? await library.list()) ?? []).filter {
            if case .pending = $0.status { true } else { false }
        }.map(\.id)
    }
}

extension RecordingManifest {
    /// A session that stopped cleanly but never reached the library.
    func cleanRecording(in directory: URL) -> Recording {
        Recording(
            micTrack: directory.appending(path: Self.micFile),
            remoteTrack: directory.appending(path: Self.remoteFile),
            highlights: highlights.map(Highlight.init(time:)),
            metadata: MeetingMetadata(title: title, startedAt: startedAt, duration: duration ?? 0, platform: platform))
    }
}
