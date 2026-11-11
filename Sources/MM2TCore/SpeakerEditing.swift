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
}

/// User edits to a meeting's speakers. Each edit writes the speaker's voiceprints back to the
/// store so the next meeting recognizes the person; this is the store's only write path from a meeting.
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

    /// Renaming touches no LLM output: names are substituted when views render.
    @discardableResult
    public func rename(_ speaker: SpeakerID, in meetingID: MeetingID, to target: Target) async throws -> Meeting {
        var meeting = try await editableMeeting(meetingID)
        let index = try speakerIndex(speaker, in: meeting)
        let embeddings = meeting.speakers[index].embeddings
        let person: PersonID
        switch target {
        case .existing(let id):
            try await voiceprints.addEmbeddings(embeddings, to: id)
            person = id
        case .newPerson(let name):
            person = try await voiceprints.addPerson(name: name, embeddings: embeddings)
        }
        let id = meeting.speakers[index].id
        meeting.speakers[index].person = person
        meeting.suggestions.items.removeAll { $0.speaker == id }
        try await library.save(meeting)
        return meeting
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
    /// speakers, so they become stale until the user regenerates them.
    @discardableResult
    public func merge(_ source: SpeakerID, into target: SpeakerID, in meetingID: MeetingID) async throws -> Meeting {
        var meeting = try await editableMeeting(meetingID)
        let sourceIndex = try speakerIndex(source, in: meeting)
        let targetIndex = try speakerIndex(target, in: meeting)
        guard sourceIndex != targetIndex else { throw SpeakerEditError.mergeIntoSelf }
        let from = meeting.speakers[sourceIndex], into = meeting.speakers[targetIndex]

        let person = into.person ?? from.person
        let embeddings = into.embeddings + from.embeddings.filter { !into.embeddings.contains($0) }
        if let person {
            try await voiceprints.addEmbeddings(embeddings, to: person)
        }

        meeting.speakers[targetIndex].person = person
        meeting.speakers[targetIndex].embeddings = embeddings
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

    /// A failed meeting is editable: a retry reloads the document, so it keeps the edit.
    private func editableMeeting(_ id: MeetingID) async throws -> Meeting {
        let meeting = try await library.meeting(id)
        if case .pending = meeting.status { throw SpeakerEditError.meetingIsProcessing }
        return meeting
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
