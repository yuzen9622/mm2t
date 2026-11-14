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
}
