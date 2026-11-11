import Foundation
import MM2TCore

/// The words the presentation and export need, supplied by the app from its String Catalog so this
/// target stays free of UI strings.
public struct PresentationLabels: Sendable {
    public var me: String
    public var viewTitle: @Sendable (TranscriptView) -> String
    public var overlapping: String
    public var notGenerated: String
    public var stale: String
    public var decisions: String
    public var discussionPoints: String
    public var actionItems: String
    public var owner: @Sendable (String) -> String

    public init(
        me: String, viewTitle: @escaping @Sendable (TranscriptView) -> String, overlapping: String,
        notGenerated: String, stale: String, decisions: String, discussionPoints: String,
        actionItems: String, owner: @escaping @Sendable (String) -> String
    ) {
        self.me = me
        self.viewTitle = viewTitle
        self.overlapping = overlapping
        self.notGenerated = notGenerated
        self.stale = stale
        self.decisions = decisions
        self.discussionPoints = discussionPoints
        self.actionItems = actionItems
        self.owner = owner
    }
}

/// Where selecting a generated item takes the user: its earliest source utterance.
public struct JumpTarget: Hashable, Sendable {
    public let utterance: UtteranceID
    public let time: TimeInterval
}

public struct UtteranceRow: Hashable, Sendable, Identifiable {
    public let id: UtteranceID
    public let start: TimeInterval
    public let speaker: SpeakerID
    public let speakerName: String
    public let text: String
    public let isOverlapping: Bool
    public let isHighlighted: Bool
}

public struct SourcedRow: Hashable, Sendable, Identifiable {
    /// Unique across the whole view, since lists show several sections at once.
    public let id: String
    public let speakerName: String?
    public let text: String
    public let jump: JumpTarget?
}

public struct DigestSection: Hashable, Sendable, Identifiable {
    public let id: SpeakerID
    public let speakerName: String
    public let points: [SourcedRow]
}

public struct SummarySections: Hashable, Sendable {
    public let decisions: [SourcedRow]
    public let discussionPoints: [SourcedRow]
    /// `speakerName` holds the owner.
    public let actionItems: [SourcedRow]
}

/// The four views as rows, with names substituted at display time (a rename never regenerates).
public struct MeetingPresentation: Sendable {
    public let meeting: Meeting
    public let names: [PersonID: String]
    public let labels: PresentationLabels

    public init(meeting: Meeting, names: [PersonID: String], labels: PresentationLabels) {
        self.meeting = meeting
        self.names = names
        self.labels = labels
    }

    public func speakerName(_ id: SpeakerID) -> String {
        let id = meeting.resolve(id)
        if id == .me { return labels.me }
        return MeetingRenderer(meeting: meeting, names: names).displayName(id)
    }

    public var raw: [UtteranceRow] {
        meeting.utterances.map {
            UtteranceRow(id: $0.id, start: $0.range.start, speaker: meeting.resolve($0.speaker),
                         speakerName: speakerName($0.speaker), text: $0.text,
                         isOverlapping: $0.isOverlapping, isHighlighted: meeting.isHighlighted($0))
        }
    }

    public var cleaned: [SourcedRow]? {
        meeting.outputs.cleaned.map { cleaned in
            cleaned.paragraphs.enumerated().map { index, paragraph in
                SourcedRow(id: "cleaned-\(index)", speakerName: speakerName(paragraph.speaker),
                           text: substitute(paragraph.text), jump: jump(paragraph.sources))
            }
        }
    }

    public var digests: [DigestSection]? {
        meeting.outputs.digests.map { digests in
            digests.map { digest in
                DigestSection(id: digest.speaker, speakerName: speakerName(digest.speaker),
                              points: rows(digest.points, section: "digest-\(digest.speaker.rawValue)"))
            }
        }
    }

    public var summary: SummarySections? {
        meeting.outputs.summary.map { summary in
            SummarySections(
                decisions: rows(summary.decisions, section: "decision"),
                discussionPoints: rows(summary.discussionPoints, section: "discussion"),
                actionItems: summary.actionItems.enumerated().map { index, item in
                    SourcedRow(id: "action-\(index)", speakerName: item.owner.map(speakerName),
                               text: substitute(item.text), jump: jump(item.sources))
                })
        }
    }

    public func jump(_ sources: [UtteranceID]) -> JumpTarget? {
        sources.compactMap { meeting.utterance($0) }.min { $0.range.start < $1.range.start }
            .map { JumpTarget(utterance: $0.id, time: $0.range.start) }
    }

    /// LLM text names speakers as `{{speaker:r2}}` tokens.
    public func substitute(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{speaker:"), let close = rest[open.upperBound...].range(of: "}}") {
            result += rest[..<open.lowerBound]
            result += speakerName(SpeakerID(String(rest[open.upperBound..<close.lowerBound])))
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    private func rows(_ items: [SourcedText], section: String) -> [SourcedRow] {
        items.enumerated().map {
            SourcedRow(id: "\(section)-\($0)", speakerName: nil, text: substitute($1.text), jump: jump($1.sources))
        }
    }

    // MARK: Export

    public func export(_ view: TranscriptView, as format: ExportFormat) -> String {
        var out = ExportText(format: format)
        out.heading(1, "\(meeting.metadata.title): \(labels.viewTitle(view))")
        switch view {
        case .raw:
            for row in raw {
                out.entry(time: row.start, speaker: row.speakerName,
                          text: row.text + (row.isOverlapping ? " (\(labels.overlapping))" : ""))
            }
        case .cleaned:
            guard let cleaned else { return out.finished(labels.notGenerated) }
            if meeting.outputs.isStale { out.line(labels.stale) }
            for row in cleaned { out.entry(time: row.jump?.time, speaker: row.speakerName ?? "", text: row.text) }
        case .perPerson:
            guard let digests else { return out.finished(labels.notGenerated) }
            if meeting.outputs.isStale { out.line(labels.stale) }
            for digest in digests {
                out.heading(2, digest.speakerName)
                for point in digest.points { out.bullet(point.text, time: point.jump?.time) }
            }
        case .summary:
            guard let summary else { return out.finished(labels.notGenerated) }
            if meeting.outputs.isStale { out.line(labels.stale) }
            for (title, items) in [(labels.decisions, summary.decisions), (labels.discussionPoints, summary.discussionPoints)] {
                out.heading(2, title)
                for item in items { out.bullet(item.text, time: item.jump?.time) }
            }
            out.heading(2, labels.actionItems)
            for item in summary.actionItems {
                out.bullet(item.text + (item.speakerName.map { " (\(labels.owner($0)))" } ?? ""), time: item.jump?.time)
            }
        }
        return out.text
    }

    /// `hh:mm:ss`, as exports and the transcript show it.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

private struct ExportText {
    let format: ExportFormat
    private(set) var text = ""

    init(format: ExportFormat) { self.format = format }

    mutating func heading(_ level: Int, _ title: String) {
        if !text.isEmpty, !text.hasSuffix("\n\n") { text += "\n" }
        switch format {
        case .markdown: line(String(repeating: "#", count: level) + " " + title)
        case .plainText: line(title)
        }
        text += "\n"
    }

    mutating func line(_ content: String) { text += content + "\n" }

    mutating func entry(time: TimeInterval?, speaker: String, text content: String) {
        let stamp = time.map { "[\(MeetingPresentation.timestamp($0))] " } ?? ""
        switch format {
        case .markdown: line("\(stamp)**\(speaker)**: \(content)\n")
        case .plainText: line("\(stamp)\(speaker): \(content)")
        }
    }

    mutating func bullet(_ content: String, time: TimeInterval?) {
        line("- " + content + (time.map { " [\(MeetingPresentation.timestamp($0))]" } ?? ""))
    }

    mutating func finished(_ last: String) -> String {
        line(last)
        return text
    }
}
