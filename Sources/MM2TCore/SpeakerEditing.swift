import Foundation

public enum SpeakerEditError: Error, Equatable {
    /// The mic speaker is always the user and cannot be renamed or merged.
    case cannotEditMe
    case unknownSpeaker(SpeakerID)
    case noSuggestion(SpeakerID)
    case mergeIntoSelf
    /// The pipeline rewrites speakers and saves its own copy of the meeting after each step,
    /// so an edit made while processing is pending would be lost.
    case meetingIsProcessing
    /// Only a voice the mic heard can be the user; a call's remote speakers are other people.
    case notHeardOnMic(SpeakerID)
    /// A voiceprint belongs to a person, so a speaker has to be named before their voice is learned.
    case unnamed(SpeakerID)
}

/// User edits to a meeting's speakers. Who a speaker is and whether their voice teaches that
/// person's voiceprint are separate choices: naming, accepting a suggestion and "this is me" can
/// teach, a merge never does, and `learnVoice` and `forgetVoice` change it afterwards. These are
/// the store's only write paths from a meeting.
public struct SpeakerEditing: Sendable {
    public enum Target: Hashable, Sendable {
        case existing(PersonID)
        case newPerson(name: String)
    }

    public let library: MeetingLibrary
    public let voiceprints: VoiceprintStore

    public init(library: MeetingLibrary, voiceprints: VoiceprintStore) {
        self.library = library
        self.voiceprints = voiceprints
    }

    /// Renaming touches no LLM output: names are substituted when views render. With `learn` off
    /// the speaker is only labelled. A speaker moved off another person takes back what this
    /// meeting taught that person, so a wrong name does not stay in their voiceprint.
    @discardableResult
    public func rename(_ speaker: SpeakerID, in meetingID: MeetingID, to target: Target, learn: Bool = true) async throws -> Meeting {
        var meeting = try await editableMeeting(meetingID)
        let index = try speakerIndex(speaker, in: meeting)
        let previous = meeting.speakers[index].person
        let embeddings = learn ? meeting.speakers[index].learnableEmbeddings : []
        let person: PersonID
        switch target {
        case .existing(let id):
            try await voiceprints.addEmbeddings(embeddings, to: id)
            person = id
        case .newPerson(let name):
            person = try await voiceprints.addPerson(name: name, embeddings: embeddings)
        }
        if let previous, previous != person {
            try await voiceprints.removeEmbeddings(meeting.speakers[index].learnableEmbeddings, from: previous)
        }
        let id = meeting.speakers[index].id
        meeting.speakers[index].person = person
        meeting.suggestions.items.removeAll { $0.speaker == id }
        try await library.save(meeting)
        return meeting
    }

    /// Adds the speaker's vectors to the voiceprint of the person they are named as.
    public func learnVoice(of speaker: SpeakerID, in meetingID: MeetingID) async throws {
        let (person, embeddings) = try await namedSpeaker(speaker, in: meetingID)
        try await voiceprints.addEmbeddings(embeddings, to: person)
    }

    /// Takes the speaker's vectors back out of their person's voiceprint; the name stays.
    public func forgetVoice(of speaker: SpeakerID, in meetingID: MeetingID) async throws {
        let (person, embeddings) = try await namedSpeaker(speaker, in: meetingID)
        try await voiceprints.removeEmbeddings(embeddings, from: person)
    }

    /// An inferred name reuses an existing person with the same name before creating one.
    @discardableResult
    public func acceptSuggestion(for speaker: SpeakerID, in meetingID: MeetingID) async throws -> Meeting {
        let meeting = try await editableMeeting(meetingID)
        let id = meeting.resolve(speaker)
        guard let suggestion = meeting.suggestions.items.first(where: { $0.speaker == id }) else {
            throw SpeakerEditError.noSuggestion(speaker)
        }
        let target: Target
        switch suggestion.source {
        case .voiceprint(let person, _):
            target = .existing(person)
        case .inferred(let name, _):
            target = await voiceprints.person(named: name).map { .existing($0.id) } ?? .newPerson(name: name)
        }
        return try await rename(id, in: meetingID, to: target)
    }

    /// Folds `source` into `target`. Generated outputs and suggestions were computed with two
    /// speakers, so they become stale until the user regenerates them. No voiceprint changes: a
    /// merged speaker is often a fragment, and its voice is learned only when the user asks.
    @discardableResult
    public func merge(_ source: SpeakerID, into target: SpeakerID, in meetingID: MeetingID) async throws -> Meeting {
        var meeting = try await editableMeeting(meetingID)
        let sourceIndex = try speakerIndex(source, in: meeting)
        let targetIndex = try speakerIndex(target, in: meeting)
        guard sourceIndex != targetIndex else { throw SpeakerEditError.mergeIntoSelf }
        let from = meeting.speakers[sourceIndex], into = meeting.speakers[targetIndex]

        let person = into.person ?? from.person
        let embeddings = into.embeddings + from.embeddings.filter { !into.embeddings.contains($0) }

        meeting.speakers[targetIndex].person = person
        meeting.speakers[targetIndex].embeddings = embeddings
        let brief = (into.briefEmbeddings ?? []) + (from.briefEmbeddings ?? []).filter { !(into.briefEmbeddings ?? []).contains($0) }
        meeting.speakers[targetIndex].briefEmbeddings = brief.isEmpty ? nil : brief
        meeting.speakers.remove(at: sourceIndex)
        meeting.mergedSpeakers[from.id] = into.id
        for index in meeting.utterances.indices where meeting.utterances[index].speaker == from.id {
            meeting.utterances[index].speaker = into.id
        }
        meeting.remoteSegments = meeting.remoteSegments.map {
            $0.speaker == from.id ? SpeakerSegment(speaker: into.id, range: $0.range) : $0
        }
        meeting.micSegments = meeting.micSegments?.map {
            $0.speaker == from.id ? SpeakerSegment(speaker: into.id, range: $0.range) : $0
        }
        meeting.suggestions.items.removeAll { $0.speaker == from.id || (person != nil && $0.speaker == into.id) }
        meeting.suggestions.isStale = true
        let outputs = meeting.outputs
        if outputs.cleaned != nil || outputs.digests != nil || outputs.summary != nil {
            meeting.outputs.isStale = true
        }
        try await library.save(meeting)
        return meeting
    }

    /// The user says a speaker is them, as when a room recording missed their voice. The speaker's
    /// speech becomes theirs and its vectors join their voiceprint, so the next meeting finds them.
    /// Like a merge, the generated outputs were written with the old speakers and become stale.
    @discardableResult
    public func claimAsMe(_ speaker: SpeakerID, in meetingID: MeetingID) async throws -> Meeting {
        var meeting = try await editableMeeting(meetingID)
        let index = try speakerIndex(speaker, in: meeting)
        let claimed = meeting.speakers[index]
        guard meeting.separatedTrack == .me || meeting.micSegments?.contains(where: { $0.speaker == claimed.id }) == true
        else { throw SpeakerEditError.notHeardOnMic(claimed.id) }
        try await voiceprints.addUserEmbeddings(claimed.learnableEmbeddings)

        meeting.speakers.remove(at: index)
        meeting.mergedSpeakers[claimed.id] = .me
        for index in meeting.utterances.indices where meeting.utterances[index].speaker == claimed.id {
            meeting.utterances[index].speaker = .me
        }
        meeting.remoteSegments = meeting.remoteSegments.map {
            $0.speaker == claimed.id ? SpeakerSegment(speaker: .me, range: $0.range) : $0
        }
        meeting.micSegments = meeting.micSegments?.map {
            $0.speaker == claimed.id ? SpeakerSegment(speaker: .me, range: $0.range) : $0
        }
        meeting.suggestions.items.removeAll { $0.speaker == claimed.id }
        meeting.suggestions.isStale = true
        let outputs = meeting.outputs
        if outputs.cleaned != nil || outputs.digests != nil || outputs.summary != nil {
            meeting.outputs.isStale = true
        }
        try await library.save(meeting)
        return meeting
    }

    @discardableResult
    public func restoreBackground(_ speaker: SpeakerID, in meetingID: MeetingID) async throws -> Meeting {
        var meeting = try await editableMeeting(meetingID)
        guard let index = meeting.backgroundSpeakers.firstIndex(where: { $0.id == speaker }) else {
            throw SpeakerEditError.unknownSpeaker(speaker)
        }
        meeting.speakers.append(meeting.backgroundSpeakers.remove(at: index))
        meeting.utterances += meeting.backgroundUtterances.filter { $0.speaker == speaker }
        meeting.backgroundUtterances.removeAll { $0.speaker == speaker }
        meeting.utterances.sort { ($0.range.start, $0.speaker.rawValue) < ($1.range.start, $1.speaker.rawValue) }
        meeting.relabelSpeakers()
        meeting.invalidateSpeakerOutputs()
        try await library.save(meeting)
        return meeting
    }

    @discardableResult
    public func delete(_ speaker: SpeakerID, in meetingID: MeetingID) async throws -> Meeting {
        var meeting = try await editableMeeting(meetingID)
        let index = try speakerIndex(speaker, in: meeting)
        let removed = meeting.speakers[index]
        if let person = removed.person, let stored = await voiceprints.person(person),
           removed.learnableEmbeddings.contains(where: stored.embeddings.contains) {
            try await forgetVoice(of: removed.id, in: meetingID)
        }
        let main = meeting.separatedTrack ?? .remote
        let segments: [Track: [SpeakerSegment]] = main == .me
            ? [.me: meeting.remoteSegments] : [.remote: meeting.remoteSegments, .me: meeting.micSegments ?? []]
        var deleted = meeting.deletedSpeakerRanges ?? [:]
        var overlaps = meeting.deletedSpeakerSharedRanges ?? [:]
        for (track, turns) in segments {
            let kept = turns.filter { $0.speaker != removed.id }.map(\.range)
            let removedRanges = turns.filter { $0.speaker == removed.id }.map(\.range)
            let ranges = removedRanges.flatMap { range in
                kept.reduce([range]) { parts, other in parts.flatMap { $0.subtracting(other) } }
            }
            let shared = removedRanges.filter { range in
                kept.contains { $0.overlap(with: range) > 0 } && !kept.contains {
                    $0.hasBoundaries(of: range, within: 2 * TimeRange.speakerTurnTolerance)
                }
            }
            if !shared.isEmpty { overlaps[track, default: []] += shared }
            if !ranges.isEmpty { deleted[track, default: []] += ranges }
        }
        meeting.deletedSpeakerRanges = deleted.isEmpty ? nil : deleted
        meeting.deletedSpeakerSharedRanges = overlaps.isEmpty ? nil : overlaps
        if let transcription = meeting.transcription {
            func keeping(_ track: Track, _ transcript: TrackTranscript) -> TrackTranscript {
                let turns = segments[track] ?? []
                return transcript.keeping {
                    Alignment.speaker(for: $0, in: turns, preferUserOnTie: track == .me && main != .me) != removed.id
                }
            }
            meeting.transcription = Transcription(me: keeping(.me, transcription.me), remote: keeping(.remote, transcription.remote))
        }
        meeting.mergedSpeakers = meeting.mergedSpeakers.filter { meeting.resolve($0.key) != removed.id }
        meeting.speakers.remove(at: index)
        meeting.utterances.removeAll { $0.speaker == removed.id }
        meeting.remoteSegments.removeAll { $0.speaker == removed.id }
        meeting.micSegments?.removeAll { $0.speaker == removed.id }
        meeting.suggestions.items.removeAll { $0.speaker == removed.id }
        meeting.relabelSpeakers()
        meeting.invalidateSpeakerOutputs()
        try await library.save(meeting)
        return meeting
    }

    /// A failed meeting is editable: a retry reloads the document, so it keeps the edit.
    private func editableMeeting(_ id: MeetingID) async throws -> Meeting {
        let meeting = try await library.meeting(id)
        if case .pending = meeting.status { throw SpeakerEditError.meetingIsProcessing }
        return meeting
    }

    private func namedSpeaker(_ speaker: SpeakerID, in meetingID: MeetingID) async throws -> (PersonID, [Embedding]) {
        let meeting = try await editableMeeting(meetingID)
        let named = meeting.speakers[try speakerIndex(speaker, in: meeting)]
        guard let person = named.person else { throw SpeakerEditError.unnamed(named.id) }
        return (person, named.learnableEmbeddings)
    }

    private func speakerIndex(_ speaker: SpeakerID, in meeting: Meeting) throws -> Int {
        let id = meeting.resolve(speaker)
        guard id != .me else { throw SpeakerEditError.cannotEditMe }
        guard let index = meeting.speakers.firstIndex(where: { $0.id == id }) else {
            throw SpeakerEditError.unknownSpeaker(speaker)
        }
        return index
    }
}
