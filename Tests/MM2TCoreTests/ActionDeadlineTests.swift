import Foundation
import Testing
@testable import MM2TCore

@Suite struct ActionDeadlineTests {
    let zone = "Asia/Taipei"

    @Test func structuredDatesPreservePrecisionAndTimeZone() throws {
        let day = try #require(ActionDeadline.parse("2026-11-15", timeZoneIdentifier: zone))
        #expect(!day.hasTime && day.dateComponents.day == 15)
        #expect(day.dateComponents.hour == nil && day.dateComponents.timeZone == nil)
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

    @Test func naturalLanguageNeverBecomesAStructuredDeadline() {
        for text in ["明天寄出", "今天整理三點建議", "今天或明天", "2026-11-15 寄出", ""] {
            #expect(ActionDeadline.parse(text, timeZoneIdentifier: zone) == nil)
        }
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
