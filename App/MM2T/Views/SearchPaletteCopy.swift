import MM2TApp
import MM2TCore
import SwiftUI

extension Copy {
    static func searchDate(_ filter: SearchPaletteModel.DateFilter) -> String {
        switch filter {
        case .today: String(localized: "Today")
        case .last7Days: String(localized: "Last 7 days")
        case .last30Days: String(localized: "Last 30 days")
        case .last3Months: String(localized: "Last 3 months")
        case .thisYear: String(localized: "This year")
        }
    }

    static func searchKind(_ kind: MeetingHits.Hit.Kind) -> String? {
        switch kind {
        case .title, .utterance, .cleaned: nil
        case .headline, .discussion: String(localized: "Summary")
        case .decision: String(localized: "Decision")
        case .action: String(localized: "Action item")
        }
    }

    static func searchMore(_ count: Int) -> String { String(localized: "+ \(count) more in this meeting") }

    static func searchRow(_ row: SearchPaletteModel.Row, locale: Locale) -> String {
        switch row.content {
        case .meeting(let meeting):
            return "\(meeting.title), \(searchMeetingDate(meeting.startedAt, locale: locale))"
        case .hit(let meeting, let index):
            let hit = meeting.hits[index]
            return "\(meeting.title), \(searchMeetingDate(meeting.startedAt, locale: locale)), \(hit.snippet)"
        case .more(let meeting): return "\(meeting.title), \(searchMore(meeting.totalHits - meeting.hits.count))"
        case .person(_, let name): return name
        case .date(let date): return searchDate(date)
        case .ask(let question): return String(localized: "Ask AI: “\(question)”")
        }
    }

    static func searchMeetingDate(_ date: Date, locale: Locale) -> String {
        var format = Date.FormatStyle.dateTime.month().day().locale(locale)
        if !Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) { format = format.year() }
        return date.formatted(format)
    }
}
