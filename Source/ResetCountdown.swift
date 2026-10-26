import Foundation

enum ResetReminderLevel: String, Codable, Sendable {
    case unknown
    case normal
    case approaching
    case imminent
    case awaitingConfirmation
}

/// Presents only a supplied reset time; it never infers an unannounced reset.
enum ResetCountdown {
    static func compact(until: Date?, now: Date = Date(), stale: Bool = false) -> String {
        guard !stale else { return "↻ 待更新" }
        guard let seconds = remainingSeconds(until: until, now: now) else { return "↻ 未知" }
        guard seconds > 0 else { return "↻ 确认中" }
        guard seconds >= 60 else { return "↻ <1分" }

        if seconds >= 86_400 {
            // Large intervals are intentionally approximate at hour precision.
            let hours = Int(floor(seconds / 3_600))
            let days = hours / 24
            let remainder = hours % 24
            return remainder == 0 ? "↻ \(days)天" : "↻ \(days)天\(remainder)小时"
        }

        let minutes = Int(ceil(seconds / 60))
        guard minutes >= 60 else { return "↻ \(minutes)分" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "↻ \(hours)小时" : "↻ \(hours)小时\(remainder)分"
    }

    static func detail(until: Date?, timezone: TimeZone = .current) -> String {
        guard let until, until.timeIntervalSinceReferenceDate.isFinite else {
            return "账号暂未提供重置时间"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let offset = timezone.secondsFromGMT(for: until)
        let absoluteMinutes = abs(offset / 60)
        let offsetText = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", absoluteMinutes / 60, absoluteMinutes % 60)
        return "\(formatter.string(from: until))（\(timezone.identifier)，\(offsetText)）"
    }

    static func reminderLevel(until: Date?, now: Date = Date(), stale: Bool = false) -> ResetReminderLevel {
        guard !stale, let seconds = remainingSeconds(until: until, now: now) else { return .unknown }
        if seconds <= 0 { return .awaitingConfirmation }
        if seconds <= 600 { return .imminent }
        if seconds <= 3_600 { return .approaching }
        return .normal
    }

    private static func remainingSeconds(until: Date?, now: Date) -> TimeInterval? {
        guard let until else { return nil }
        let value = until.timeIntervalSince(now)
        // Keep conversions to integer hours/minutes safe even for malformed dates.
        guard value.isFinite, abs(value) < Double(Int.max) else { return nil }
        return value
    }
}
