import Foundation

/// What the recorder hands over when a meeting ends.
public struct Recording: Sendable {
    public let micTrack: URL
    public let remoteTrack: URL
    public let highlights: [Highlight]
    public let metadata: MeetingMetadata

    public init(micTrack: URL, remoteTrack: URL, highlights: [Highlight], metadata: MeetingMetadata) {
        self.micTrack = micTrack
        self.remoteTrack = remoteTrack
        self.highlights = highlights
        self.metadata = metadata
    }
}

public enum LibraryError: Error, Equatable {
    case unknownMeeting(MeetingID)
}

/// One directory per meeting under `root`, holding `meeting.json` and both audio tracks.
public actor MeetingLibrary {
    public let root: URL
    private let files = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    /// Moves the track files into the meeting's directory, so the library owns them from here on.
    public func create(_ recording: Recording) throws -> Meeting {
        let id = MeetingID()
        let directory = self.directory(id)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = RecordingAudio(
            micFile: "mic." + recording.micTrack.pathExtension,
            remoteFile: "remote." + recording.remoteTrack.pathExtension)
        try files.moveItem(at: recording.micTrack, to: directory.appending(path: audio.micFile))
        try files.moveItem(at: recording.remoteTrack, to: directory.appending(path: audio.remoteFile))
        let meeting = Meeting(id: id, metadata: recording.metadata, audio: audio, highlights: recording.highlights)
        try save(meeting)
        return meeting
    }

    public func meeting(_ id: MeetingID) throws -> Meeting {
        let url = documentURL(id)
        guard files.fileExists(atPath: url.path) else { throw LibraryError.unknownMeeting(id) }
        return try JSONFile.read(Meeting.self, from: url)
    }

    public func save(_ meeting: Meeting) throws {
        try JSONFile.write(meeting, to: documentURL(meeting.id))
    }

    public func audioURL(_ meeting: Meeting, track: Track) -> URL {
        directory(meeting.id).appending(path: track == .me ? meeting.audio.micFile : meeting.audio.remoteFile)
    }

    /// Newest first.
    public func list() throws -> [Meeting] {
        guard files.fileExists(atPath: root.path) else { return [] }
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { files.fileExists(atPath: $0.appending(path: "meeting.json").path) }
            .map { try JSONFile.read(Meeting.self, from: $0.appending(path: "meeting.json")) }
            .sorted { $0.metadata.startedAt > $1.metadata.startedAt }
    }

    /// Matches title, raw and cleaned transcript text, and the names of people in the meeting.
    public func search(_ query: String, names: [PersonID: String]) throws -> [Meeting] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return try list() }
        return try list().filter { meeting in
            let haystack = [meeting.metadata.title]
                + meeting.utterances.map(\.text)
                + (meeting.outputs.cleaned?.paragraphs.map(\.text) ?? [])
                + meeting.speakers.compactMap { $0.person.flatMap { names[$0] } }
            return haystack.contains { $0.localizedStandardContains(query) }
        }
    }

    /// Removes the document and both audio tracks.
    public func delete(_ id: MeetingID) throws {
        guard files.fileExists(atPath: documentURL(id).path) else { throw LibraryError.unknownMeeting(id) }
        try files.removeItem(at: directory(id))
    }

    private func directory(_ id: MeetingID) -> URL { root.appending(path: id.description) }
    private func documentURL(_ id: MeetingID) -> URL { directory(id).appending(path: "meeting.json") }
}
