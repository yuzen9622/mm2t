import Foundation

public enum TranscriptEditError: Error, Equatable {
    case unknownUtterance(UtteranceID)
    case unknownParagraph(Int)
    /// The pipeline saves its own copy of the meeting after each step, so an edit made meanwhile would be lost.
    case meetingIsProcessing
}

/// The user's corrections to a meeting's words and title.
public struct TranscriptEditing: Sendable {
    public let library: MeetingLibrary

    public init(library: MeetingLibrary) { self.library = library }

    /// Views generated from the old wording are left as they are: a corrected typo is not a reason to
    /// pay for regeneration, and the user can still ask for it.
    @discardableResult
    public func edit(_ utterance: UtteranceID, in meetingID: MeetingID, to text: String) async throws -> Meeting {
        var meeting = try await editable(meetingID)
        guard let index = meeting.utterances.firstIndex(where: { $0.id == utterance }) else {
            throw TranscriptEditError.unknownUtterance(utterance)
        }
        meeting.utterances[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await library.save(meeting)
        return meeting
    }

    @discardableResult
    public func editCleaned(paragraph index: Int, in meetingID: MeetingID, to text: String) async throws -> Meeting {
        var meeting = try await editable(meetingID)
        guard var cleaned = meeting.outputs.cleaned, cleaned.paragraphs.indices.contains(index) else {
            throw TranscriptEditError.unknownParagraph(index)
        }
        cleaned.paragraphs[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.outputs.cleaned = cleaned
        try await library.save(meeting)
        return meeting
    }

    /// A blank title is ignored. The name sticks: a later summary no longer renames the meeting.
    @discardableResult
    public func rename(_ meetingID: MeetingID, to title: String) async throws -> Meeting {
        var meeting = try await editable(meetingID)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != meeting.metadata.title else { return meeting }
        meeting.metadata.title = title
        meeting.metadata.titleEdited = true
        try await library.save(meeting)
        return meeting
    }

    private func editable(_ id: MeetingID) async throws -> Meeting {
        let meeting = try await library.meeting(id)
        if case .pending = meeting.status { throw TranscriptEditError.meetingIsProcessing }
        return meeting
    }
}

/// The video-call address in a calendar event.
public enum MeetingLink {
    static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "meet.jit.si"]

    /// The first address of a known meeting service in `texts` (an event's URL, location and notes, in that order).
    public static func find(in texts: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts {
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for url in matches.compactMap(\.url) {
                guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let host = url.host()?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}
