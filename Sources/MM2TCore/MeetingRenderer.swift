import Foundation

public enum TranscriptView: String, Sendable, CaseIterable {
    case raw
    case cleaned
    case perPerson
    case summary
}

public enum ExportFormat: Sendable {
    case markdown
    case plainText
}

/// Renders the four views, substituting names at render time so a rename never needs regeneration.
public struct MeetingRenderer: Sendable {
    public let meeting: Meeting
    public let names: [PersonID: String]

    /// `names` is the voiceprint store's directory (`VoiceprintStore.names()`).
    public init(meeting: Meeting, names: [PersonID: String]) {
        self.meeting = meeting
        self.names = names
    }

    public func displayName(_ id: SpeakerID) -> String {
        let id = meeting.resolve(id)
        if id == .me { return "Me" }
        guard let speaker = meeting.speaker(id) else { return id.rawValue }
        return speaker.person.flatMap { names[$0] } ?? speaker.label
    }

    public func render(_ view: TranscriptView, as format: ExportFormat) -> String {
        var out = Output(format: format)
        out.heading(1, "\(meeting.metadata.title): \(Self.titles[view]!)")
        switch view {
        case .raw: raw(&out)
        case .cleaned: cleaned(&out)
        case .perPerson: perPerson(&out)
        case .summary: summary(&out)
        }
        return out.text
    }

    static let titles: [TranscriptView: String] = [
        .raw: "Transcript", .cleaned: "Cleaned transcript", .perPerson: "By person", .summary: "Summary",
    ]

    private func raw(_ out: inout Output) {
        for utterance in meeting.utterances {
            let overlap = utterance.isOverlapping ? " (overlapping speech)" : ""
            out.line(out.entry(time: utterance.range.start, speaker: displayName(utterance.speaker),
                               text: utterance.text + overlap))
        }
    }

    private func cleaned(_ out: inout Output) {
        guard let cleaned = meeting.outputs.cleaned else { return out.line("Not generated yet.") }
        staleNotice(&out)
        for paragraph in cleaned.paragraphs {
            out.line(out.entry(time: meeting.timeRange(of: paragraph.sources)?.start,
                               speaker: displayName(paragraph.speaker), text: substitute(paragraph.text)))
        }
    }

    private func perPerson(_ out: inout Output) {
        guard let digests = meeting.outputs.digests else { return out.line("Not generated yet.") }
        staleNotice(&out)
        for digest in digests {
            out.heading(2, displayName(digest.speaker))
            for point in digest.points { out.bullet(sourced(point.text, point.sources)) }
        }
    }

    private func summary(_ out: inout Output) {
        guard let summary = meeting.outputs.summary else { return out.line("Not generated yet.") }
        staleNotice(&out)
        out.heading(2, "Decisions")
        for item in summary.decisions { out.bullet(sourced(item.text, item.sources)) }
        out.heading(2, "Discussion points")
        for item in summary.discussionPoints { out.bullet(sourced(item.text, item.sources)) }
        out.heading(2, "Action items")
        for item in summary.actionItems {
            let owner = item.owner.map { " (owner: \(displayName($0)))" } ?? ""
            out.bullet(sourced(item.text + owner, item.sources))
        }
    }

    private func staleNotice(_ out: inout Output) {
        guard meeting.outputs.isStale else { return }
        out.line("Speakers changed since this was generated. Regenerate to update it.")
    }

    private func sourced(_ text: String, _ sources: [UtteranceID]) -> String {
        let time = meeting.timeRange(of: sources).map { " [\(Output.timestamp($0.start))]" } ?? ""
        return substitute(text) + time
    }

    private func substitute(_ text: String) -> String {
        SpeakerMention.substitute(in: text, name: displayName)
    }
}

private struct Output {
    let format: ExportFormat
    private(set) var text = ""

    mutating func heading(_ level: Int, _ title: String) {
        if !text.isEmpty { text += "\n" }
        switch format {
        case .markdown: line(String(repeating: "#", count: level) + " " + title)
        case .plainText: line(level == 1 ? title.uppercased() : title)
        }
        text += "\n"
    }

    mutating func line(_ content: String) { text += content + "\n" }

    mutating func bullet(_ content: String) { line("- " + content) }

    func entry(time: TimeInterval?, speaker: String, text: String) -> String {
        let stamp = time.map { "[\(Self.timestamp($0))] " } ?? ""
        switch format {
        case .markdown: return "\(stamp)**\(speaker)**: \(text)\n"
        case .plainText: return "\(stamp)\(speaker): \(text)"
        }
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
