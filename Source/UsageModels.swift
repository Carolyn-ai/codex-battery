import Foundation
import CoreFoundation

enum UsageDisplayWindow: String, Codable, Sendable, CaseIterable {
    case shortTerm
    case weekly
    case limiting
}

/// A server-reported allowance window. Missing usage is unknown, never zero.
struct UsageWindow: Codable, Sendable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    init(usedPercent: Double?, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        self.windowDurationMins = windowDurationMins.flatMap { $0 > 0 ? $0 : nil }
        self.resetsAt = resetsAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
    var displayPercent: Int? { remainingPercent.map { Int(floor($0)) } }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }

    var durationLabel: String {
        guard let minutes = windowDurationMins else { return "当前周期" }
        if minutes == 10_080 { return "本周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    private enum CodingKeys: String, CodingKey { case usedPercent, windowDurationMins, resetsAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            usedPercent: try values.decodeIfPresent(Double.self, forKey: .usedPercent),
            windowDurationMins: try values.decodeIfPresent(Int.self, forKey: .windowDurationMins),
            resetsAt: try values.decodeIfPresent(Double.self, forKey: .resetsAt)
        )
    }
}

enum UsageParseError: Error, LocalizedError {
    case codexLimitsUnavailable
    case malformedWindow

    var errorDescription: String? {
        switch self {
        case .codexLimitsUnavailable: return "暂时无法读取 Codex 用量。"
        case .malformedWindow: return "Codex 返回的用量格式暂不支持。"
        }
    }
}

struct UsageSnapshot: Codable, Sendable, Equatable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let fetchedAt: Date

    var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }

    /// Prefer the canonical Codex bucket, even when its windows are unknown.
    /// Only the legacy unlabelled/Codex bucket can be used as a fallback.
    static func parse(result: [String: Any], fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let canonical = result["rateLimitsByLimitId"] as? [String: Any]
        let bucket: [String: Any]
        if let canonical, canonical.keys.contains("codex") {
            if canonical["codex"] is NSNull {
                bucket = [:]
            } else if let value = canonical["codex"] as? [String: Any] {
                bucket = value
            } else {
                throw UsageParseError.malformedWindow
            }
        } else if let legacy = result["rateLimits"] as? [String: Any],
                  legacy["limitId"] == nil || legacy["limitId"] is NSNull || legacy["limitId"] as? String == "codex" {
            bucket = legacy
        } else {
            throw UsageParseError.codexLimitsUnavailable
        }

        return try UsageSnapshot(
            primary: parseWindow(bucket["primary"]),
            secondary: parseWindow(bucket["secondary"]),
            fetchedAt: fetchedAt
        )
    }

    func chosenWindow(selection: UsageDisplayWindow, now: Date = Date()) -> UsageWindow? {
        switch selection {
        case .shortTerm:
            return windows.filter { ($0.windowDurationMins ?? Int.max) < 10_080 }
                .min { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
        case .weekly:
            return windows.filter { ($0.windowDurationMins ?? 0) >= 10_080 }
                .min { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
        case .limiting:
            let known = windows.filter { $0.remainingPercent != nil }
            let current = known.filter { $0.resetDate.map { $0 > now } ?? true }
            return (current.isEmpty ? known : current)
                .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
                ?? windows.first
        }
    }

    func selectedLabel(selection: UsageDisplayWindow) -> String {
        chosenWindow(selection: selection)?.durationLabel
            ?? (selection == .weekly ? "本周" : selection == .shortTerm ? "短期" : "当前周期")
    }

    private static func parseWindow(_ value: Any?) throws -> UsageWindow? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else { throw UsageParseError.malformedWindow }
        let percent = finiteNumber(object["usedPercent"])
        let duration = finiteNumber(object["windowDurationMins"]).flatMap { value -> Int? in
            guard value > 0, value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        return UsageWindow(usedPercent: percent, windowDurationMins: duration, resetsAt: finiteNumber(object["resetsAt"]))
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
