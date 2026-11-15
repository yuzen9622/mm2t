import Foundation
import MM2TApp
import Testing

struct MeetingDurationTests {
    @Test func durationsKeepBothUnitsAndSwitchAtExactlyOneHour() {
        let locale = Locale(identifier: "zh_TW")
        for (seconds, expected) in [(0.0, "0分鐘0秒"), (5, "0分鐘5秒"), (60, "1分鐘0秒"),
                                    (3599.99, "59分鐘59秒"), (3600, "1小時0分鐘"),
                                    (3659, "1小時0分鐘"), (3660, "1小時1分鐘"),
                                    (90000, "25小時0分鐘")] {
            let shown = MeetingPresentation.duration(seconds, locale: locale).filter { !$0.isWhitespace }
            #expect(shown == expected)
        }
    }
}
