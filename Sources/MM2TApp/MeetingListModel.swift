import Foundation
import MM2TCore
import Observation

public struct MeetingRow: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        case notProcessed
        case processing(ProcessingStep?)
        case needsSetup
        case failed(String)
        case completed
    }

    public let id: MeetingID
    public let title: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let platform: MeetingPlatform?
    public let status: Status
    /// The summary's one-line preview with speaker names filled in; nil until a summary exists.
    public let headline: String?
    public let participants: [Participant]

    public struct Participant: Hashable, Sendable, Identifiable {
        public let id: SpeakerID
        public let name: String
        public let isNamed: Bool
    }
}

@MainActor @Observable
public final class MeetingListModel {
    public var query = ""
    public private(set) var rows: [MeetingRow] = []
    public private(set) var errorMessage: String?
    /// How the mic speaker is named in previews and avatars; the app sets its localized word.
    public var meLabel = "Me"

    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private let voiceprints: VoiceprintStore
    @ObservationIgnored private let queue: ProcessingQueue

    public init(library: MeetingLibrary, voiceprints: VoiceprintStore, queue: ProcessingQueue) {
        self.library = library
        self.voiceprints = voiceprints
        self.queue = queue
    }

    /// Lists every meeting, or those matching `query` by title, transcript or speaker name.
    public func reload() async {
        do {
            let names = await voiceprints.names()
            let meetings = try await library.search(query, names: names)
            rows = meetings.map { meeting in
                let presentation = MeetingPresentation(meeting: meeting, names: names, labels: Self.labels(me: meLabel))
                return MeetingRow(
                    id: meeting.id, title: meeting.metadata.title, startedAt: meeting.metadata.startedAt,
                    duration: meeting.metadata.duration, platform: meeting.metadata.platform,
                    status: Self.status(meeting.status, job: queue.jobs[meeting.id]),
                    headline: meeting.outputs.summary?.headline.map(presentation.substitute),
                    participants: Self.participants(meeting, presentation))
            }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Removes the document and both audio tracks. A meeting being processed cannot be deleted.
    public func delete(_ id: MeetingID) async {
        guard !queue.isBusy(id) else { return }
        do {
            try await library.delete(id)
            queue.remove(id)
        } catch {
            errorMessage = String(describing: error)
        }
        await reload()
    }

    public func process(_ id: MeetingID) async {
        await queue.run(.process, on: id)
        await reload()
    }

    /// Everyone who spoke, the user first, then remote speakers in order of first appearance.
    static func participants(_ meeting: Meeting, _ presentation: MeetingPresentation) -> [MeetingRow.Participant] {
        var seen: [SpeakerID] = []
        for utterance in meeting.utterances {
            let id = meeting.resolve(utterance.speaker)
            if !seen.contains(id) { seen.append(id) }
        }
        let named = Set(meeting.speakers.filter { $0.person != nil }.map(\.id))
        return (seen.filter { $0 == .me } + seen.filter { $0 != .me }).map {
            .init(id: $0, name: presentation.speakerName($0), isNamed: $0 == .me || named.contains($0))
        }
    }

    /// Only the mic speaker's name is rendered from a list row, so the other labels stay empty.
    private static func labels(me: String) -> PresentationLabels {
        PresentationLabels(me: me, viewTitle: { _ in "" }, overlapping: "", notGenerated: "", stale: "",
                           decisions: "", discussionPoints: "", actionItems: "", owner: { $0 })
    }

    static func status(_ status: ProcessingStatus, job: JobState?) -> MeetingRow.Status {
        switch job {
        case .queued: return .processing(nil)
        case .running(let step): return .processing(step)
        case .needsSetup: return .needsSetup
        case .failed(_, let reason): return .failed(reason)
        case .completed, nil: break
        }
        switch status {
        case .completed: return .completed
        case .failed(_, let reason): return .failed(reason)
        case .pending: return .notProcessed
        }
    }
}
