import Foundation

enum ResetTimeQualifier: String, Sendable {
    case exact
    case noLaterThan
}

/// A time stated in a verified original post, never a community estimate.
struct ResetAnnouncementTime: Sendable, Equatable {
    let date: Date
    let qualifier: ResetTimeQualifier
    let sourceTimeZone: String

    func compact(timezone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) -> String {
        let formatter = Self.formatter(timezone: timezone, format: "MM/dd HH:mm")
        return formatter.string(from: date) + (qualifier == .noLaterThan ? "前" : "")
    }

    func detail(timezone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) -> String {
        let formatter = Self.formatter(timezone: timezone, format: "yyyy-MM-dd HH:mm")
        let offset = timezone.secondsFromGMT(for: date) / 60
        let offsetText = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", abs(offset) / 60, abs(offset) % 60)
        let suffix = qualifier == .noLaterThan ? "前（原文截止时间）" : "（原文指定时间）"
        return "\(formatter.string(from: date))\(suffix)；\(timezone.identifier)，\(offsetText)；原帖时区 \(sourceTimeZone)"
    }

    private static func formatter(timezone: TimeZone, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.dateFormat = format
        return formatter
    }
}

/// Intentionally narrow grammar: one definite date, one clock, one known zone.
/// Ambiguous prose, clocks, DST abbreviations and folds fall back to a message alert.
enum ResetAnnouncementTimeParser {
    static func parse(text: String, postedAt: Date) -> ResetAnnouncementTime? {
        guard postedAt.timeIntervalSinceReferenceDate.isFinite, text.count <= 10_000 else { return nil }
        let cleaned = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"(?i)\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\."#, with: "$1", options: .regularExpression)
        let lower = cleaned.lowercased()
        let uncertain = #"\b(?:maybe|might|approximately|around|roughly|hopefully|tentatively|cancelled|canceled|delayed|postponed)\b|\b(?:not|no|won't|will not)\s+(?:be\s+|a\s+)?reset\b|\b(?:next hour|in an? hour|not before|no earlier than)\b"#
        guard matches(uncertain, in: lower).isEmpty else { return nil }

        let zonePattern = #"\b(?:UTC|GMT)(?:[+-]\d{1,2}(?::?\d{2})?)?\b|\b(?:PDT|PST|PT)\b|(?<=\d)(?:Z|[+-]\d{2}:\d{2})\b|(?<![A-Za-z0-9])[+-]\d{2}:\d{2}(?!\d)"#
        let zones = matches(zonePattern, in: cleaned)
        guard zones.count == 1, let zoneMatch = zones.first else { return nil }
        let rawZone = substring(cleaned, zoneMatch.range).uppercased()
        guard let zone = sourceZone(rawZone) else { return nil }
        var withoutZone = cleaned
        withoutZone.replaceSubrange(Range(zoneMatch.range, in: withoutZone)!, with: String(repeating: " ", count: zoneMatch.range.length))

        let clockPattern = #"(?<![\d:+-])(\d{1,2})(?::(\d{2}))?\s*(a\.m\.|p\.m\.|am|pm)(?![A-Za-z])|(?<![\d:+-])(\d{1,2}):(\d{2})(?![:\d])|\b(noon|midnight)\b"#
        let clocks = matches(clockPattern, in: withoutZone)
        guard clocks.count == 1, let clockMatch = clocks.first,
              clockMatch.range.upperBound <= zoneMatch.range.location else { return nil }
        let gapRange = NSRange(location: clockMatch.range.upperBound, length: zoneMatch.range.location - clockMatch.range.upperBound)
        let gap = substring(cleaned, gapRange)
        guard gap.range(of: #"^\s*[\(\[]?\s*$"#, options: .regularExpression) != nil,
              let clock = clock(from: clockMatch, in: withoutZone) else { return nil }
        guard substring(withoutZone, clockMatch.range(at: 6)).lowercased() != "midnight" else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone.timezone
        let sourcePosted = calendar.dateComponents([.year, .month, .day], from: postedAt)
        var requested: DateComponents?
        var implicitYear = false
        var dateCount = 0
        var dateRange: NSRange?

        for match in matches(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#, in: cleaned) {
            dateCount += 1
            dateRange = match.range
            requested = DateComponents(year: integer(cleaned, match.range(at: 1)), month: integer(cleaned, match.range(at: 2)), day: integer(cleaned, match.range(at: 3)))
        }
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let namedPattern = #"\b(January|Jan|February|Feb|March|Mar|April|Apr|May|June|Jun|July|Jul|August|Aug|September|Sept|Sep|October|Oct|November|Nov|December|Dec)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#
        for match in matches(namedPattern, in: cleaned) {
            dateCount += 1
            dateRange = match.range
            let monthName = String(substring(cleaned, match.range(at: 1)).lowercased().prefix(3))
            let explicitYear = integer(cleaned, match.range(at: 3))
            implicitYear = explicitYear == nil
            requested = DateComponents(year: explicitYear ?? sourcePosted.year, month: months[monthName], day: integer(cleaned, match.range(at: 2)))
        }
        for match in matches(#"\b(today|tomorrow)\b"#, in: cleaned) {
            dateCount += 1
            dateRange = match.range
            let days = substring(cleaned, match.range(at: 1)).lowercased() == "tomorrow" ? 1 : 0
            guard let target = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: postedAt)) else { return nil }
            requested = calendar.dateComponents([.year, .month, .day], from: target)
        }
        guard dateCount == 1, let dateRange,
              isSingleTimingClause(cleaned, dateRange: dateRange, clockRange: clockMatch.range, zoneRange: zoneMatch.range),
              var components = requested,
              let year = components.year, (2000...2200).contains(year) else { return nil }
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = 0
        guard var date = strictDate(components, calendar: calendar) else { return nil }
        // A missing year is accepted near the post, including a close New Year rollover.
        if implicitYear {
            if date.timeIntervalSince(postedAt) < -86_400 {
                components.year = year + 1
                guard let nextYear = strictDate(components, calendar: calendar),
                      nextYear.timeIntervalSince(postedAt) >= 0,
                      nextYear.timeIntervalSince(postedAt) <= 32 * 86_400 else { return nil }
                date = nextYear
            } else if date.timeIntervalSince(postedAt) > 32 * 86_400 { return nil }
        }
        // PST/PDT are frequently used colloquially. Reject seasonally conflicting labels.
        if rawZone == "PST" && zone.timezone.isDaylightSavingTime(for: date) { return nil }
        if rawZone == "PDT" && !zone.timezone.isDaylightSavingTime(for: date) { return nil }
        let deadlinePrefix = #"\b(?:before|by|no later than)\s*$"#
        let beforeClock = substring(cleaned, NSRange(location: 0, length: clockMatch.range.location))
        let beforeDate = substring(cleaned, NSRange(location: 0, length: dateRange.location))
        let afterZone = substring(cleaned, NSRange(location: zoneMatch.range.upperBound, length: (cleaned as NSString).length - zoneMatch.range.upperBound))
        let deadline = !matches(deadlinePrefix, in: beforeClock).isEmpty || !matches(deadlinePrefix, in: beforeDate).isEmpty
            || !matches(#"^\s*at the latest\b"#, in: afterZone).isEmpty
        let qualifier: ResetTimeQualifier = deadline ? .noLaterThan : .exact
        return ResetAnnouncementTime(date: date, qualifier: qualifier, sourceTimeZone: rawZone)
    }

    private struct SourceZone { let timezone: TimeZone }

    private static func isSingleTimingClause(_ text: String, dateRange: NSRange, clockRange: NSRange, zoneRange: NSRange) -> Bool {
        guard dateRange.upperBound <= clockRange.location else { return false }
        let prefix = substring(text, NSRange(location: 0, length: dateRange.location))
        let connector = substring(text, NSRange(location: dateRange.upperBound, length: clockRange.location - dateRange.upperBound))
        let suffix = substring(text, NSRange(location: zoneRange.upperBound, length: (text as NSString).length - zoneRange.upperBound))
        // Positive grammar binds the entire date/clock/zone to one reset clause.
        // Unknown subjects, predicates, clauses or prose stay as ordinary message alerts.
        let speaker = #"(?:(?:we|i)\s+will\s+|we'll\s+|i'll\s+)?"#
        let resetObject = #"(?:\s+(?:the\s+)?(?:usage(?:\s+limits)?|limits|codex\s+usage(?:\s+limits)?))?"#
        let resetPredicate = speaker + #"reset(?:ting)?"# + resetObject
        let limitsPredicate = #"(?:usage(?:\s+limits)?|limits|codex\s+usage(?:\s+limits)?)\s+(?:will\s+)?reset(?:s)?"#
        let creditPredicate = speaker + #"add(?:ing)?\s+(?:(?:a|one)\s+)?(?:banked reset|reset credit|reset card)"#
        let deliveryPredicate = #"(?:landing|lands|will\s+land)"#
        let predicate = #"(?:"# + resetPredicate + "|" + limitsPredicate + "|" + creditPredicate + "|" + deliveryPredicate + #")"#
        let prefixPattern = #"^\s*(?:by the way,\s*)?(?:"# + predicate + #"\s*)?(?:(?:on|at|before|by|no later than)\s*)?$"#
        let connectorPattern = #"^\s*(?:T|(?:at|before|by|no later than)\s*)?$"#
        let suffixPattern = #"^\s*[\)\]]?\s*(?:(?:together with a small (?:ship|update))|(?:for all (?:paid )?users))?\s*[.!]?\s*$"#
        return !matches(prefixPattern, in: prefix).isEmpty
            && !matches(connectorPattern, in: connector).isEmpty
            && !matches(suffixPattern, in: suffix).isEmpty
    }

    private static func sourceZone(_ value: String) -> SourceZone? {
        if ["PT", "PST", "PDT"].contains(value) {
            return TimeZone(identifier: "America/Los_Angeles").map(SourceZone.init)
        }
        if ["UTC", "GMT", "Z"].contains(value) { return SourceZone(timezone: TimeZone(secondsFromGMT: 0)!) }
        var offset = value
        if offset.hasPrefix("UTC") || offset.hasPrefix("GMT") { offset = String(offset.dropFirst(3)) }
        guard let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        let digits = String(offset.dropFirst())
        let hours: Int?
        let minutes: Int?
        if digits.contains(":") {
            let parts = digits.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].count == 2 else { return nil }
            hours = Int(parts[0]); minutes = Int(parts[1])
        } else if digits.count > 2 {
            hours = Int(digits.dropLast(2)); minutes = Int(digits.suffix(2))
        } else { hours = Int(digits); minutes = 0 }
        guard let hours, let minutes, (0...14).contains(hours), (0...59).contains(minutes), hours < 14 || minutes == 0,
              let timezone = TimeZone(secondsFromGMT: (hours * 3_600 + minutes * 60) * (sign == "-" ? -1 : 1)) else { return nil }
        return SourceZone(timezone: timezone)
    }

    private static func strictDate(_ parts: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: parts) else { return nil }
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        func equalsRequested(_ candidate: Date) -> Bool {
            let roundTrip = calendar.dateComponents(units, from: candidate)
            return roundTrip.year == parts.year && roundTrip.month == parts.month && roundTrip.day == parts.day
                && roundTrip.hour == parts.hour && roundTrip.minute == parts.minute && roundTrip.second == parts.second
        }
        guard equalsRequested(date) else { return nil }
        // Reject a repeated local clock during a daylight-saving fold.
        guard !equalsRequested(date.addingTimeInterval(-3_600)), !equalsRequested(date.addingTimeInterval(3_600)) else { return nil }
        return date
    }

    private static func clock(from match: NSTextCheckingResult, in text: String) -> (hour: Int, minute: Int)? {
        if let rawHour = integer(text, match.range(at: 1)) {
            let minute = integer(text, match.range(at: 2)) ?? 0
            guard (1...12).contains(rawHour), (0...59).contains(minute) else { return nil }
            let isPM = substring(text, match.range(at: 3)).lowercased().hasPrefix("p")
            return (rawHour % 12 + (isPM ? 12 : 0), minute)
        }
        if let hour = integer(text, match.range(at: 4)), let minute = integer(text, match.range(at: 5)),
           (0...23).contains(hour), (0...59).contains(minute) { return (hour, minute) }
        let word = substring(text, match.range(at: 6)).lowercased()
        if word == "noon" { return (12, 0) }
        if word == "midnight" { return (0, 0) }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        guard range.location != NSNotFound, let range = Range(range, in: text) else { return "" }
        return String(text[range])
    }

    private static func integer(_ text: String, _ range: NSRange) -> Int? { Int(substring(text, range)) }
}
