import Foundation

public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var people: Set<PersonID>
    public var dateRange: ClosedRange<Date>?
    public var limit: Int
    public var names: [PersonID: String]

    public init(text: String = "", people: Set<PersonID> = [], dateRange: ClosedRange<Date>? = nil,
                limit: Int = 30, names: [PersonID: String] = [:]) {
        self.text = text
        self.people = people
        self.dateRange = dateRange
        self.limit = limit
        self.names = names
    }
}

public struct MeetingHits: Sendable, Equatable, Identifiable {
    public var id: MeetingID
    public var title: String
    public var startedAt: Date
    public var hits: [Hit]
    public var totalHits: Int

    public struct Hit: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case title, utterance, cleaned, headline, decision, discussion, action
        }
        public var kind: Kind
        public var snippet: String
        public var matchedRanges: [Range<String.Index>]
        public var utterance: UtteranceID?
        public var time: TimeInterval?
        public var speaker: PersonID?

        init(kind: Kind, text: String, terms: [String], utterance: UtteranceID?, time: TimeInterval?, speaker: PersonID?) {
            self.kind = kind
            self.utterance = utterance
            self.time = time
            self.speaker = speaker
            let first = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
                .map(\.lowerBound).min() ?? text.startIndex
            let start = text.index(first, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(first, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
            snippet = (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
            var ranges: [Range<String.Index>] = []
            for term in terms where !term.isEmpty {
                var remaining = snippet.startIndex..<snippet.endIndex
                while let range = snippet.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                    ranges.append(range)
                    remaining = range.upperBound..<snippet.endIndex
                }
            }
            var merged: [Range<String.Index>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else { merged.append(range) }
            }
            matchedRanges = merged
        }
    }
}
