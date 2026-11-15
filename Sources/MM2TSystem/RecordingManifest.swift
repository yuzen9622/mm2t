import Foundation
import MM2TCore

/// `session.json` beside the two tracks in a recording directory. Rewritten on every highlight,
/// pause and stop, so a crashed session can still become a `Recording`.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public static let fileName = "session.json"
    public static let micFile = "mic.wav"
    public static let remoteFile = "remote.wav"

    public var title: String
    public var startedAt: Date
    public var timeZoneIdentifier: String?
    public var platform: MeetingPlatform?
    public var targetBundleID: String?
    public var highlights: [TimeInterval] = []
    /// Set at a clean stop; nil means the session ended without one.
    public var duration: TimeInterval?

    public init(title: String, startedAt: Date, platform: MeetingPlatform?, targetBundleID: String?,
                timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.title = title
        self.startedAt = startedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.platform = platform
        self.targetBundleID = targetBundleID
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }

    public static func read(from directory: URL) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: directory.appending(path: fileName)))
    }

    func recording(in directory: URL, duration: TimeInterval) -> Recording {
        Recording(
            micTrack: directory.appending(path: Self.micFile),
            remoteTrack: directory.appending(path: Self.remoteFile),
            highlights: highlights.map(Highlight.init(time:)),
            metadata: MeetingMetadata(title: title, startedAt: startedAt, duration: duration, platform: platform,
                                      timeZoneIdentifier: timeZoneIdentifier ?? TimeZone.current.identifier))
    }
}

public enum RecordingRecovery {
    /// True when the directory holds a session that never reached a clean stop.
    public static func isInterrupted(_ directory: URL) -> Bool {
        (try? RecordingManifest.read(from: directory))?.duration == nil
    }

    /// Repairs both track headers after a crash and returns what `MeetingLibrary.create` needs.
    /// The duration is the longer track, since the other may have lost its last unflushed second.
    public static func recover(_ directory: URL) throws -> Recording {
        var manifest = try RecordingManifest.read(from: directory)
        let mic = try WAVFormat.repair(directory.appending(path: RecordingManifest.micFile))
        let remote = try WAVFormat.repair(directory.appending(path: RecordingManifest.remoteFile))
        let duration = max(mic, remote)
        manifest.duration = duration
        try manifest.write(to: directory)
        return manifest.recording(in: directory, duration: duration)
    }
}
