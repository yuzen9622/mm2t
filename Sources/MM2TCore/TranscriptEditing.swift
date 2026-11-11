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

/// What a correction teaches: the words the user typed in place of what speech recognition heard.
public enum VocabularyLearning {
    /// Longest replacement taken as a term; a longer one is a rewritten sentence, not a spelling.
    static let maxTermCharacters = 24

    /// The replaced stretch of `new`, widened to whole Latin words. Empty when the edit only
    /// deleted text, changed punctuation or spacing, or rewrote too much to be one term.
    public static func terms(correcting old: String, to new: String) -> [String] {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var start = prefix, end = b.count - suffix
        guard start < end else { return [] }
        while start > 0, isLatinWord(b[start - 1]), isLatinWord(b[start]) { start -= 1 }
        while end < b.count, isLatinWord(b[end]), isLatinWord(b[end - 1]) { end += 1 }
        let term = String(b[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        guard !term.isEmpty, term.count <= maxTermCharacters,
              term.contains(where: { $0.isLetter }), !term.contains(where: \.isNewline) else { return [] }
        // One changed Han character is a fixed typo ("在" for "再"), not a term.
        if term.count == 1, !isLatinWord(Character(term)) { return [] }
        return [term]
    }

    private static func isLatinWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
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
