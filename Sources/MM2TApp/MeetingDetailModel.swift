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

    /// The recording's owner, who has no voice of their own to rename or merge.
    public var isMe: Bool { id == .me }
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
    @ObservationIgnored private var correctionRevisions: [CorrectionTarget: UUID] = [:]
    @ObservationIgnored public let todos: TodoStatus?
    @ObservationIgnored public let reminders: RemindersSync?

    /// `learn` receives the names and terms corrected in a saved transcript passage.
    public init(id: MeetingID, library: MeetingLibrary, voiceprints: VoiceprintStore, queue: ProcessingQueue,
                labels: PresentationLabels, playback: (any MeetingPlayback)?,
                todos: TodoStatus? = nil, reminders: RemindersSync? = nil,
                learn: @escaping @MainActor (String) -> Void = { _ in }) {
        self.learn = learn
        self.todos = todos
        self.reminders = reminders
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
                // Queue updates can reenter load while playback prepares its filtered audio.
                loadedAudio = true
                await playback.load(mic: await library.audioURL(meeting, track: .me),
                              remote: await library.audioURL(meeting, track: .remote))
            }
            await reminders?.fillMissingDeadlines(reminderDrafts())
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

    /// Whether "this is me" applies: only a voice the mic heard can be the user.
    public func canClaimAsMe(_ speaker: SpeakerID) -> Bool {
        guard canEditSpeakers, let meeting else { return false }
        return meeting.separatedTrack == .me || meeting.micSegments?.contains { $0.speaker == speaker } == true
    }

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

    /// Everyone who spoke, the user first when the mic heard them.
    public var speakers: [SpeakerRow] {
        guard let meeting, let presentation else { return [] }
        let me = meeting.utterances.contains { meeting.resolve($0.speaker) == .me }
            ? [SpeakerRow(id: .me, label: "", displayName: presentation.speakerName(.me), person: nil, suggestion: nil)]
            : []
        return me + meeting.speakers.map { speaker in
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

    // MARK: To-dos

    /// The to-do id of a row of `presentation.summary.actionItems`; nil for any other row.
    public func todoID(_ row: SourcedRow) -> String? {
        guard row.id.hasPrefix("action-"), let index = Int(row.id.dropFirst("action-".count)) else { return nil }
        return TodoStatus.id(meeting: id, index: index)
    }

    public func isDone(_ row: SourcedRow) -> Bool {
        todoID(row).map { todos?.isDone($0) ?? false } ?? false
    }

    public func toggleDone(_ row: SourcedRow) {
        if let id = todoID(row) { todos?.toggle(id) }
    }

    public func isInReminders(_ row: SourcedRow) -> Bool {
        todoID(row).map { reminders?.isLinked($0) ?? false } ?? false
    }

    /// Nil when this model has no Reminders sync to offer.
    public var remindersAccess: RemindersAccess? { reminders?.access }

    /// Creates reminders for `rows` (every action item when nil) that do not have one yet.
    public func addToReminders(_ rows: [SourcedRow]? = nil) async {
        await reminders?.add(reminderDrafts(rows))
    }

    private func reminderDrafts(_ rows: [SourcedRow]? = nil) -> [ReminderDraft] {
        guard let meeting, let all = presentation?.summary?.actionItems else { return [] }
        let date = meeting.metadata.startedAt.formatted(date: .abbreviated, time: .shortened)
        return (rows ?? all).compactMap { row -> ReminderDraft? in
            guard let id = todoID(row) else { return nil }
            let owner = row.speakerName.map { "\($0)\n" } ?? ""
            return ReminderDraft(todoID: id, title: row.text, notes: "\(owner)\(meeting.metadata.title), \(date)", due: row.due)
        }
    }

    public func requestRemindersAccess() async { await reminders?.requestAccess() }

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

    /// Plays from `time` in the view on screen, the way a synced lyric line does.
    public func play(at time: TimeInterval) {
        focusedUtterance = nil
        playback?.play(from: time)
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

    /// "This is me": the speaker's speech becomes the user's and teaches their voiceprint.
    public func claimAsMe(_ speaker: SpeakerID) async {
        await edit { try await $0.claimAsMe(speaker, in: self.id) }
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
        await editTranscript(from: old, to: text, target: .raw(utterance)) { try await $0.edit(utterance, in: self.id, to: text) }
    }

    /// `row` is a row of `presentation.cleaned`.
    public func editCleaned(_ row: SourcedRow, to text: String) async {
        guard let index = presentation?.cleaned?.firstIndex(where: { $0.id == row.id }) else { return }
        await editTranscript(from: row.text, to: text, target: .cleaned(index)) { try await $0.editCleaned(paragraph: index, in: self.id, to: text) }
    }

    /// A cleaned paragraph rewritten the way `instruction` asks, for the user to review and save.
    public func rewrite(_ text: String, instruction: String) async throws -> String {
        try await queue.rewrite(text, instruction: instruction)
    }

    public func rename(to title: String) async {
        await editTranscript(from: "", to: "") { try await $0.rename(self.id, to: title) }
    }

    private enum CorrectionTarget: Hashable {
        case raw(UtteranceID)
        case cleaned(Int)

        func text(in meeting: Meeting) -> String? {
            switch self {
            case .raw(let id): return meeting.utterance(id)?.text
            case .cleaned(let index):
                guard let paragraphs = meeting.outputs.cleaned?.paragraphs, paragraphs.indices.contains(index) else { return nil }
                return paragraphs[index].text
            }
        }
    }

    private func editTranscript(from old: String, to new: String, target: CorrectionTarget? = nil, _ change: (TranscriptEditing) async throws -> Meeting) async {
        guard canEditSpeakers else { return }
        let revision = UUID()
        if let target { correctionRevisions[target] = revision }
        do {
            meeting = try await change(TranscriptEditing(library: library))
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            return
        }
        guard let target, let saved = meeting, let savedText = target.text(in: saved), !old.isEmpty, old != new else { return }
        // The edit is already durable. A model failure must not undo it or turn into a save error.
        guard let corrections = try? await queue.vocabularyCorrections(from: old, to: new),
              let current = try? await library.meeting(id),
              target.text(in: current) == savedText,
              correctionRevisions[target] == revision, !Task.isCancelled else { return }
        for correction in VocabularyLearning.validated(corrections, from: old, to: new) { learn(correction.correct) }
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
