import Foundation
import MM2TCore
import Observation

public struct SpeakerRow: Hashable, Sendable, Identifiable {
    public enum Suggestion: Hashable, Sendable {
        case voiceprint(name: String, similarity: Double)
        /// `reason` already has speaker tokens replaced with names.
        case inferred(name: String, reason: String)

        public var name: String {
            switch self {
            case .voiceprint(let name, _), .inferred(let name, _): name
            }
        }
    }

    public let id: SpeakerID
    public let label: String
    public let displayName: String
    public let person: PersonID?
    public let suggestion: Suggestion?
}

@MainActor @Observable
public final class MeetingDetailModel {
    public let id: MeetingID
    public var selectedView: TranscriptView = .raw
    /// The utterance a jump landed on, for the transcript to scroll to and mark.
    public private(set) var focusedUtterance: UtteranceID?
    public private(set) var meeting: Meeting?
    public private(set) var names: [PersonID: String] = [:]
    public private(set) var people: [Person] = []
    public private(set) var errorMessage: String?

    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private let voiceprints: VoiceprintStore
    @ObservationIgnored private let queue: ProcessingQueue
    @ObservationIgnored private let labels: PresentationLabels
    @ObservationIgnored public let playback: (any MeetingPlayback)?
    @ObservationIgnored private var loadedAudio = false
    @ObservationIgnored private let learn: @MainActor (String) -> Void

    /// `learn` receives each term a correction replaced what speech recognition heard with.
    public init(id: MeetingID, library: MeetingLibrary, voiceprints: VoiceprintStore, queue: ProcessingQueue,
                labels: PresentationLabels, playback: (any MeetingPlayback)?,
                learn: @escaping @MainActor (String) -> Void = { _ in }) {
        self.learn = learn
        self.id = id
        self.library = library
        self.voiceprints = voiceprints
        self.queue = queue
        self.labels = labels
        self.playback = playback
    }

    public func load() async {
        do {
            let meeting = try await library.meeting(id)
            self.meeting = meeting
            names = await voiceprints.names()
            people = await voiceprints.allPersons().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !loadedAudio, let playback {
                playback.load(mic: await library.audioURL(meeting, track: .me),
                              remote: await library.audioURL(meeting, track: .remote))
                loadedAudio = true
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public var presentation: MeetingPresentation? {
        meeting.map { MeetingPresentation(meeting: $0, names: names, labels: labels) }
    }

    public var job: JobState? { queue.jobs[id] }

    /// The pipeline rewrites the document after every step, so edits wait until it is done.
    public var isProcessing: Bool {
        if queue.isBusy(id) { return true }
        if case .pending = meeting?.status { return true }
        return false
    }

    public var canEditSpeakers: Bool { meeting != nil && !isProcessing }

    /// Generated views were written for speakers that a merge or re-separation has since changed.
    public var isStale: Bool {
        guard let meeting else { return false }
        return meeting.outputs.isStale || meeting.suggestions.isStale
    }

    /// The failure that left speakers unseparated or without voiceprints; nil when separation worked
    /// or simply had no source, where re-running cannot help.
    public var separationFailure: String? {
        switch meeting?.attribution {
        case .unseparated(.failed(let reason)), .transcription(voiceprintsUnavailable: .failed(let reason)): reason
        default: nil
        }
    }

    public var canReseparate: Bool { separationFailure != nil && meeting?.status == .completed && !isProcessing }

    /// Re-separation rebuilds speakers, dropping names the user assigned and merges they made.
    public var reseparationDiscardsEdits: Bool {
        guard let meeting else { return false }
        return !meeting.mergedSpeakers.isEmpty || meeting.speakers.contains { $0.person != nil }
    }

    public var speakers: [SpeakerRow] {
        guard let meeting, let presentation else { return [] }
        return meeting.speakers.map { speaker in
            let suggestion = meeting.suggestions.items.first { $0.speaker == speaker.id }.flatMap { item -> SpeakerRow.Suggestion? in
                switch item.source {
                case .voiceprint(let person, let similarity):
                    names[person].map { .voiceprint(name: $0, similarity: similarity) }
                case .inferred(let name, let reason):
                    .inferred(name: name, reason: presentation.substitute(reason))
                }
            }
            return SpeakerRow(id: speaker.id, label: speaker.label, displayName: presentation.speakerName(speaker.id),
                              person: speaker.person, suggestion: suggestion)
        }
    }

    // MARK: Actions

    public func regenerate() async {
        await queue.run(.regenerate, on: id)
        await load()
    }

    public func reseparate() async {
        guard canReseparate else { return }
        await queue.run(.reseparate, on: id)
        await load()
    }

    public func retry() async {
        await queue.run(.process, on: id)
        await load()
    }

    /// Shows the source utterance in the raw transcript and plays from it.
    public func jump(to target: JumpTarget) {
        selectedView = .raw
        focusedUtterance = target.utterance
        playback?.play(from: target.time)
    }

    public func play(_ row: UtteranceRow) {
        focusedUtterance = row.id
        playback?.play(from: row.start)
    }

    public func rename(_ speaker: SpeakerID, to target: SpeakerEditing.Target) async {
        await edit { try await $0.rename(speaker, in: self.id, to: target) }
    }

    public func acceptSuggestion(for speaker: SpeakerID) async {
        await edit { try await $0.acceptSuggestion(for: speaker, in: self.id) }
    }

    public func merge(_ source: SpeakerID, into target: SpeakerID) async {
        await edit { try await $0.merge(source, into: target, in: self.id) }
    }

    public func export(_ view: TranscriptView, as format: ExportFormat) -> String? {
        presentation?.export(view, as: format)
    }

    /// SubRip text; nil for the views that are not a timed transcript.
    public func subtitles(_ view: TranscriptView) -> String? {
        guard let meeting, let presentation else { return nil }
        return Subtitles.srt(meeting, view: view, name: presentation.speakerName)
    }

    /// Corrects one line of the raw transcript and learns the term the correction introduced.
    public func edit(_ utterance: UtteranceID, to text: String) async {
        guard let old = meeting?.utterance(utterance)?.text else { return }
        await editTranscript(from: old, to: text) { try await $0.edit(utterance, in: self.id, to: text) }
    }

    /// `row` is a row of `presentation.cleaned`.
    public func editCleaned(_ row: SourcedRow, to text: String) async {
        guard let index = presentation?.cleaned?.firstIndex(where: { $0.id == row.id }) else { return }
        await editTranscript(from: row.text, to: text) { try await $0.editCleaned(paragraph: index, in: self.id, to: text) }
    }

    public func rename(to title: String) async {
        await editTranscript(from: "", to: "") { try await $0.rename(self.id, to: title) }
    }

    private func editTranscript(from old: String, to new: String, _ change: (TranscriptEditing) async throws -> Meeting) async {
        guard canEditSpeakers else { return }
        do {
            meeting = try await change(TranscriptEditing(library: library))
            for term in VocabularyLearning.terms(correcting: old, to: new) { learn(term) }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func dismissError() { errorMessage = nil }

    private func edit(_ change: (SpeakerEditing) async throws -> Meeting) async {
        guard canEditSpeakers else { return }
        do {
            meeting = try await change(SpeakerEditing(library: library, voiceprints: voiceprints))
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        await load()
    }
}
