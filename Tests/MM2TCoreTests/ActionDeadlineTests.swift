import Foundation
import Testing
@testable import MM2TCore

@Suite struct ActionDeadlineTests {
    let zone = "Asia/Taipei"
    var reference: Date { ISO8601DateFormatter().date(from: "2026-11-14T10:00:00+08:00")! }

    @Test func resolvesRelativeDaysAndChineseTimesFromTheMeetingDate() throws {
        for (text, expected) in [
            ("今天下午三點半寄報價", "2026-11-14T15:30:00+08:00"),
            ("明天上午十點十五分交稿", "2026-11-15T10:15:00+08:00"),
            ("後天 16:45 確認", "2026-11-16T16:45:00+08:00"),
            ("大後天晚上九點完成", "2026-11-17T21:00:00+08:00"),
            ("11 月 20 號下午 2:05 寄出", "2026-11-20T14:05:00+08:00"),
            ("16 號上午 9 點聯繫", "2026-11-16T09:00:00+08:00"),
            ("十五號上午 9 點聯繫", "2026-11-15T09:00:00+08:00"),
            ("十二月十五號上午 9 點聯繫", "2026-12-15T09:00:00+08:00"),
            ("Send tomorrow 3pm", "2026-11-15T15:00:00+08:00"),
        ] {
            let due = try #require(ActionDeadline.resolve(in: text, relativeTo: reference, timeZoneIdentifier: zone))
            #expect(due.date == ISO8601DateFormatter().date(from: expected), "\(text)")
            #expect(due.hasTime && due.timeZoneIdentifier == zone)
        }
    }

    @Test func dayOnlyDeadlinesStayAllDayAndRolloverUsesCalendarDays() throws {
        let endOfYear = ISO8601DateFormatter().date(from: "2026-12-31T23:30:00+08:00")!
        let due = try #require(ActionDeadline.resolve(in: "明天寄出", relativeTo: endOfYear, timeZoneIdentifier: zone))
        #expect(!due.hasTime)
        #expect(due.dateComponents.year == 2027 && due.dateComponents.month == 1 && due.dateComponents.day == 1)
        #expect(due.dateComponents.hour == nil && due.dateComponents.timeZone == nil)
        let nextMonth = try #require(ActionDeadline.resolve(in: "3 號寄出", relativeTo: reference, timeZoneIdentifier: zone))
        #expect(nextMonth.dateComponents.month == 12 && nextMonth.dateComponents.day == 3)
        let thirtyFirst = try #require(ActionDeadline.resolve(in: "31 號寄出", relativeTo: reference, timeZoneIdentifier: zone))
        #expect(thirtyFirst.dateComponents.month == 12 && thirtyFirst.dateComponents.day == 31)
    }

    @Test func uncertainMissingOrInvalidDeadlinesDoNotInventAnAlarm() {
        for text in ["儘快寄出", "之後再確認", "下週找時間討論", "3:30 再討論", "明天 25:00 寄出", "2026-02-30 寄出", "今天或明天寄出", "明天 09:00 或 15:00 寄出", "明天 15:xx 交稿", "下個月十五號"] {
            #expect(ActionDeadline.resolve(in: text, relativeTo: reference, timeZoneIdentifier: zone) == nil, "\(text)")
        }
    }

    @Test func structuredDatesPreservePrecisionAndTimeZone() throws {
        let day = try #require(ActionDeadline.parse("2026-11-15", timeZoneIdentifier: zone))
        #expect(!day.hasTime && day.dateComponents.day == 15)
        let timed = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: zone))
        #expect(timed.hasTime && timed.dateComponents.hour == 15 && timed.dateComponents.minute == 30)
        #expect(timed.dateComponents.timeZone?.identifier == zone)
        #expect(ActionDeadline.parse("2026-11-15T15:30:00", timeZoneIdentifier: zone) == nil)
        #expect(ActionDeadline.parse("2026-02-30", timeZoneIdentifier: zone) == nil)
        #expect(ActionDeadline.parse("2026-02-30T15:00:00+08:00", timeZoneIdentifier: zone) == nil)
        #expect(ActionDeadline.parse("2026-11-15T15:30:00+25:00", timeZoneIdentifier: zone) == nil)
        #expect(ActionDeadline.parse("2026-11-15T15:30:00+08:99", timeZoneIdentifier: zone) == nil)
        #expect(ActionDeadline.parse(nil, timeZoneIdentifier: zone) == nil)
    }

    @Test func countsRatiosAndAnAmbiguousMidnightNeverBecomeClockTimes() throws {
        let count = try #require(ActionDeadline.resolve(in: "明天整理三點建議", relativeTo: reference, timeZoneIdentifier: zone))
        #expect(!count.hasTime && count.dateComponents.day == 15)
        #expect(ActionDeadline.resolve(in: "今天整理 3:2 的長寬比例", relativeTo: reference, timeZoneIdentifier: zone) == nil)
        #expect(ActionDeadline.resolve(in: "明天晚上十二點交稿", relativeTo: reference, timeZoneIdentifier: zone) == nil)
    }

    @Test func oldActionsDecodeAndNewDeadlinesSurvivePersistenceAndLocalization() throws {
        let old = try JSONDecoder().decode(Summary.ActionItem.self, from: Data(#"{"text":"寄出","owner":null,"sources":[]}"#.utf8))
        #expect(old.due == nil)
        let due = try #require(ActionDeadline.parse("2026-11-15T15:30:00+08:00", timeZoneIdentifier: zone))
        let summary = Summary(decisions: [], discussionPoints: [], actionItems: [.init(text: "联络", owner: nil, sources: [], due: due)])
        let restored = try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(summary))
        #expect(restored.inTraditionalChinese.actionItems.first?.due == due)
        #expect(restored.inTraditionalChinese.actionItems.first?.text == "聯絡")
    }
}
