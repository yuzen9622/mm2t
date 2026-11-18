import MM2TApp
import SwiftUI

extension Copy {
    static func assistantStep(_ step: AssistantStep) -> String {
        switch step.kind {
        case .plan:
            step.state == .running ? String(localized: "Thinking") : String(localized: "Thought for \(Int(step.duration.rounded()))s")
        case .search: String(localized: "Searched")
        case .read: String(localized: "Read")
        case .tasks: String(localized: "Checked assignments")
        case .answer: String(localized: "Answer")
        }
    }
    static func assistantDetail(_ step: AssistantStep) -> String {
        switch step.kind {
        case .plan, .answer: return ""
        case .search:
            let args = step.arguments
            let filters = (args.people + [args.dateFrom, args.dateTo].compactMap { $0 }).joined(separator: " · ")
            return "“\(args.query)”" + (filters.isEmpty ? "" : " · \(filters)") +
                (step.result.map { " · " + String(localized: "\($0.count) meetings") } ?? "")
        case .read: return String(localized: "\(step.result?.count ?? step.arguments.meetings.count) meetings")
        case .tasks: return String(localized: "\(step.result?.count ?? 0) assignments")
        }
    }
    static func assistantActivity(_ turn: AssistantTurn) -> String {
        let searches = turn.steps.filter { $0.kind == .search && $0.state == .done }.count
        let reads = turn.steps.filter { $0.kind == .read }.reduce(0) { $0 + ($1.result?.count ?? 0) }
        return String(localized: "Searched \(searches) times, read \(reads) meetings")
    }
    static func assistantSource(_ source: AssistantSource) -> String {
        source.title + " · " + source.date.formatted(date: .abbreviated, time: .omitted) +
            (source.time.map { " · \(MeetingPresentation.timestamp($0))" } ?? "")
    }
}
