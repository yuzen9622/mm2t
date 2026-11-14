import Foundation

/// A due day, optionally with an explicit time. Date-only deadlines never invent a midnight alarm.
public struct ActionDeadline: Codable, Hashable, Sendable {
    public let date: Date
    public let hasTime: Bool
    public let timeZoneIdentifier: String

    public init(date: Date, hasTime: Bool, timeZoneIdentifier: String) {
        self.date = date
        self.hasTime = hasTime
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var dateComponents: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let fields: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        var components = calendar.dateComponents(fields, from: date)
        components.calendar = calendar
        if hasTime { components.timeZone = calendar.timeZone }
        return components
    }

    /// The structured summary contract accepts a local ISO date or an RFC 3339 timestamp.
    public static func parse(_ value: String?, timeZoneIdentifier: String) -> ActionDeadline? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        if let match = groups(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})$"#, in: value).first,
           let year = Int(match[0]), let month = Int(match[1]), let day = Int(match[2]),
           let date = validDate(year: year, month: month, day: day, calendar: calendar) {
            return ActionDeadline(date: date, hasTime: false, timeZoneIdentifier: calendar.timeZone.identifier)
        }
        // A timezone is required; silently interpreting an offset-free timestamp changes its meaning.
        guard let parts = groups(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(?:Z|[+-]([0-9]{2}):([0-9]{2}))$"#, in: value).first,
              validDate(year: Int(parts[0])!, month: Int(parts[1])!, day: Int(parts[2])!, calendar: calendar) != nil,
              (0...23).contains(Int(parts[3])!), (0...59).contains(Int(parts[4])!), (0...59).contains(Int(parts[5])!),
              parts[6].isEmpty || ((0...23).contains(Int(parts[6])!) && (0...59).contains(Int(parts[7])!)) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { return nil }
        return ActionDeadline(date: date, hasTime: true, timeZoneIdentifier: calendar.timeZone.identifier)
    }

    /// A fallback for saved summaries without a structured deadline. Only unambiguous dates in
    /// the action itself count; vague wording and multiple dates are left unscheduled.
    public static func resolve(in text: String, relativeTo reference: Date, timeZoneIdentifier: String) -> ActionDeadline? {
        // These need broader context than this legacy fallback has.
        guard !["下個月", "下个月", "上個月", "上个月", "下月", "上月"].contains(where: text.contains) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let base = calendar.dateComponents([.year, .month, .day], from: reference)
        var candidates: [Date] = []
        let relative = groups(#"(今天|今日|明天|明日|後天|后天|大後天|大后天|(?i:\btoday\b|\btomorrow\b))"#, in: text)
        for match in relative {
            let token = match[0].lowercased()
            let offset = ["今天": 0, "今日": 0, "today": 0, "明天": 1, "明日": 1, "tomorrow": 1,
                          "後天": 2, "后天": 2, "大後天": 3, "大后天": 3][token]!
            if let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference)) { candidates.append(day) }
        }
        let absolute = groups(#"(?<!\d)(?:(\d{4})\s*(?:年|[-/])\s*)?([0-9一二三四五六七八九十]{1,3})\s*(?:月|[-/])\s*([0-9一二三四五六七八九十]{1,3})(?:\s*[日號号])?(?!\d)"#, in: text)
        for match in absolute {
            guard let month = number(match[1]), let day = number(match[2]) else { return nil }
            var year = Int(match[0]) ?? base.year!
            if match[0].isEmpty, month < base.month! { year += 1 }
            guard let date = validDate(year: year, month: month, day: day, calendar: calendar) else { return nil }
            candidates.append(date)
        }
        if absolute.isEmpty {
            for match in groups(#"(?<![\d月一二三四五六七八九十])([0-9一二三四五六七八九十]{1,3})\s*[日號号]"#, in: text) {
                guard let day = number(match[0]), (1...31).contains(day),
                      let date = calendar.nextDate(after: calendar.startOfDay(for: reference).addingTimeInterval(-1),
                        matching: DateComponents(day: day, hour: 0, minute: 0, second: 0), matchingPolicy: .strict) else { return nil }
                candidates.append(date)
            }
        }
        guard let day = candidates.first, Set(candidates).count == 1 else { return nil }
        // A colon needs two minute digits. A ratio such as 3:2 is not a spoken clock time.
        guard groups(#"\d\s*[:：]\s*(?!\s*\d{2}(?!\d))"#, in: text).isEmpty else { return nil }
        var times = groups(#"(上午|早上|凌晨|中午|下午|傍晚|晚上)?\s*(?<![第0-9一二兩两三四五六七八九十零〇])([0-9一二兩两三四五六七八九十零〇]{1,3})\s*(?::|：|[點点](?!\s*(?:建議|建议|意見|意见|看法|原因|理由|問題|问题|重點|重点|結論|结论|事項|事项|注意|需求|優勢|优势|改善))|時|时)\s*(半|[0-9一二兩两三四五六七八九十零〇]{1,3})?\s*(?:分)?\s*(?i:(am|pm))?"#, in: text)
        if times.isEmpty {
            times = groups(#"(?i:\b(\d{1,2})\s*(am|pm)\b)"#, in: text).map { ["", $0[0], "", $0[1]] }
        }
        guard times.count <= 1 else { return nil }
        if let time = times.first {
            guard var hour = number(time[1]) else { return nil }
            let minute = time[2] == "半" ? 30 : time[2].isEmpty ? 0 : number(time[2]) ?? -1
            // "Tomorrow night at twelve" straddles a day boundary; don't silently turn it into noon.
            guard !(time[0] == "晚上" && hour == 12) else { return nil }
            if ["下午", "傍晚", "晚上", "中午"].contains(time[0]) || time[3].lowercased() == "pm" {
                guard (1...12).contains(hour) else { return nil }
                if hour < 12 { hour += 12 }
            } else if ["上午", "早上", "凌晨"].contains(time[0]) || time[3].lowercased() == "am" {
                guard (1...12).contains(hour) else { return nil }
                if hour == 12 { hour = 0 }
            }
            guard (0...23).contains(hour), (0...59).contains(minute),
                  let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  calendar.component(.hour, from: date) == hour, calendar.component(.minute, from: date) == minute else { return nil }
            return ActionDeadline(date: date, hasTime: true, timeZoneIdentifier: calendar.timeZone.identifier)
        }
        return ActionDeadline(date: day, hasTime: false, timeZoneIdentifier: calendar.timeZone.identifier)
    }

    private static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    private static func groups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }

    private static func number(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let characters = Array(value)
        if characters.count == 1 { return value == "十" ? 10 : digits[characters[0]] }
        if let ten = characters.firstIndex(of: "十"), ten <= 1, characters.count <= ten + 2 {
            let tens = ten == 0 ? 1 : digits[characters[0]] ?? -10
            let units = ten == characters.count - 1 ? 0 : digits[characters[ten + 1]] ?? -100
            return tens * 10 + units
        }
        return nil
    }
}
