import Foundation

/// Re-derives stored voices after the voiceprint model changes, as the update from WeSpeaker to
/// CAM++ did. A vector of another length than the embedder's came from the earlier model and scores
/// nothing against new ones, so each such meeting's speakers are embedded again from its own audio,
/// and a person's vector learned from a speaker becomes that speaker's new vector. The read-aloud
/// enrollment was not kept, so the user's own voice is rebuilt from what they said on recent calls,
/// where the mic heard only them. What no meeting can rebuild is dropped.
///
/// Each meeting is rewritten on its own, voiceprints first, so a run that stops resumes with the
/// meetings still holding old vectors. A meeting whose audio cannot be read loses its old vectors
/// rather than being retried at every launch.
public struct VoiceprintMigration: Sendable {
    public struct Outcome: Equatable, Sendable {
        public var meetings = 0
        public var unreadable = 0
        /// Old vectors no meeting rebuilt, now gone from the voiceprints.
        public var dropped = 0
        /// Calls the user's own voice was rebuilt from; 0 leaves them to enroll again.
        public var userCalls = 0
    }

    /// Calls the user's voice is rebuilt from, newest first: as many as an enrollment plus a couple
    /// of claimed meetings would have held, without reading every call they ever had.
    static let userCalls = 3

    let library: MeetingLibrary
    let voiceprints: VoiceprintStore
    let embedder: any SpeakerEmbedder

    public init(library: MeetingLibrary, voiceprints: VoiceprintStore, embedder: any SpeakerEmbedder) {
        self.library = library
        self.voiceprints = voiceprints
        self.embedder = embedder
    }

    /// `progress` receives meetings rebuilt and meetings to rebuild, first with none done.
    public func run(progress: @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in }) async throws -> Outcome {
        let dimensions = embedder.dimensions
        var outcome = Outcome()
        let meetings = try await library.list()
        let outdated = meetings.filter { Self.holdsVectors(of: $0, otherThan: dimensions) }
        await progress(0, outdated.count)
        for stale in outdated {
            try Task.checkCancellation()
            // Only a recording that is gone counts as unreadable; any other failure, such as the
            // model not loading, stops the run so the next launch tries again with nothing lost.
            let heard: [SpeakerID: Voice]
            if await hasAudio(stale) {
                heard = try await voices(in: stale)
            } else {
                outcome.unreadable += 1
                heard = [:]
            }
            // Re-read: a reprocess or an edit while the audio was embedded must not be overwritten.
            var meeting = try await library.meeting(stale.id)
            for index in meeting.speakers.indices {
                let speaker = meeting.speakers[index]
                guard Self.holdsVectors(of: speaker, otherThan: dimensions) else { continue }
                let voice = heard[speaker.id] ?? Voice(kept: [], brief: nil)
                try await voiceprints.replace(speaker.embeddings + (speaker.briefEmbeddings ?? []), with: voice.learnable)
                meeting.speakers[index].embeddings = voice.kept
                meeting.speakers[index].briefEmbeddings = voice.brief
            }
            try await library.save(meeting)
            outcome.meetings += 1
            await progress(outcome.meetings, outdated.count)
        }
        if let user = await voiceprints.user(), user.embeddings.contains(where: { $0.values.count != dimensions }) {
            let rebuilt = try await userVoice(from: meetings)
            try await voiceprints.addUserEmbeddings(rebuilt)
            outcome.userCalls = rebuilt.count
        }
        outcome.dropped = try await voiceprints.dropVectors(otherThan: dimensions)
        return outcome
    }

    /// One vector per recent call where the mic was the user's alone and they spoke enough: their
    /// words, less any moment the call itself was talking, which the mic may have picked up.
    private func userVoice(from meetings: [Meeting]) async throws -> [Embedding] {
        let me = ClusterID("me")
        var vectors: [Embedding] = []
        for meeting in meetings where meeting.separatedTrack == nil && meeting.micSegments == nil
            && meeting.transcription != nil {
            guard vectors.count < Self.userCalls else { break }
            let mic = await library.audioURL(meeting, track: .me)
            guard FileManager.default.fileExists(atPath: mic.path) else { continue }
            let spoken = meeting.utterances.filter { meeting.resolve($0.speaker) == .me }.map(\.range)
            let clean = Self.subtracting(meeting.remoteSegments.map(\.range), from: spoken)
            guard !clean.isEmpty else { continue }
            let heard = try await embedder.voiceprints(
                track: mic, segments: clean.map { Diarization.Segment(cluster: me, range: $0) }, includingBrief: false)
            vectors += (heard.kept[me] ?? []).map { $0.heard(on: .room) }
        }
        return vectors
    }

    static func subtracting(_ holes: [TimeRange], from ranges: [TimeRange]) -> [TimeRange] {
        let holes = holes.sorted { $0.start < $1.start }
        return ranges.flatMap { range -> [TimeRange] in
            var pieces: [TimeRange] = []
            var start = range.start
            for hole in holes where hole.end > start && hole.start < range.end {
                if hole.start > start { pieces.append(TimeRange(start: start, end: hole.start)) }
                start = max(start, hole.end)
            }
            if start < range.end { pieces.append(TimeRange(start: start, end: range.end)) }
            return pieces
        }
    }

    /// Whether anything still holds a vector of an earlier model.
    public func isNeeded() async throws -> Bool {
        let dimensions = embedder.dimensions
        if await voiceprints.hasVectors(otherThan: dimensions) { return true }
        return try await library.list().contains { Self.holdsVectors(of: $0, otherThan: dimensions) }
    }

    private struct Voice {
        let kept: [Embedding]
        let brief: [Embedding]?
        var learnable: [Embedding] { kept.isEmpty ? brief ?? [] : kept }
    }

    private static func holdsVectors(of meeting: Meeting, otherThan dimensions: Int) -> Bool {
        meeting.speakers.contains { holdsVectors(of: $0, otherThan: dimensions) }
    }

    private static func holdsVectors(of speaker: RemoteSpeaker, otherThan dimensions: Int) -> Bool {
        (speaker.embeddings + (speaker.briefEmbeddings ?? [])).contains { $0.values.count != dimensions }
    }

    private func hasAudio(_ meeting: Meeting) async -> Bool {
        var tracks: [Track] = [meeting.separatedTrack ?? .remote]
        if meeting.micSegments != nil { tracks.append(.me) }
        for track in tracks where !FileManager.default.fileExists(atPath: await library.audioURL(meeting, track: track).path) {
            return false
        }
        return true
    }

    /// Every speaker's voice, from the track and segments that separated them: the remote track
    /// on a call, the mic for a room recording and for anyone the mic heard beside the user.
    private func voices(in meeting: Meeting) async throws -> [SpeakerID: Voice] {
        var sources: [(track: Track, segments: [SpeakerSegment], channel: VoiceChannel)] =
            [(meeting.separatedTrack ?? .remote, meeting.remoteSegments, meeting.separatedTrack == .me ? .room : .call)]
        if let mic = meeting.micSegments { sources.append((.me, mic, .room)) }
        var voices: [SpeakerID: Voice] = [:]
        for source in sources where !source.segments.isEmpty {
            let segments = source.segments.map {
                Diarization.Segment(cluster: ClusterID($0.speaker.rawValue), range: $0.range)
            }
            let heard = try await embedder.voiceprints(
                track: await library.audioURL(meeting, track: source.track), segments: segments, includingBrief: true)
            // A speaker merged with someone the mic heard has speech on both tracks and keeps both voices.
            for speaker in meeting.speakers {
                let cluster = ClusterID(speaker.id.rawValue)
                guard heard.kept[cluster] != nil || heard.brief[cluster] != nil else { continue }
                let earlier = voices[speaker.id]
                let brief = (earlier?.brief ?? []) + (heard.brief[cluster] ?? []).map { $0.heard(on: source.channel) }
                voices[speaker.id] = Voice(
                    kept: (earlier?.kept ?? []) + (heard.kept[cluster] ?? []).map { $0.heard(on: source.channel) },
                    brief: brief.isEmpty ? nil : brief)
            }
        }
        return voices
    }
}
