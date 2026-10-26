import Foundation

@main
enum ResetCountdownTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var checks = 0
        func expect(_ actual: @autoclosure () -> Bool, _ message: String) {
            guard actual() else { fatalError(message) }
            checks += 1
        }
        func compact(_ seconds: Double, stale: Bool = false) -> String {
            ResetCountdown.compact(until: now.addingTimeInterval(seconds), now: now, stale: stale)
        }
        func level(_ seconds: Double, stale: Bool = false) -> ResetReminderLevel {
            ResetCountdown.reminderLevel(until: now.addingTimeInterval(seconds), now: now, stale: stale)
        }

        expect(ResetCountdown.compact(until: nil, now: now) == "↻ 未知", "Missing reset is unknown")
        expect(ResetCountdown.compact(until: nil, now: now, stale: true) == "↻ 待更新", "Stale status takes precedence")
        expect(compact(100, stale: true) == "↻ 待更新", "Do not display stale countdown")
        expect(compact(-1) == "↻ 确认中", "Past reset awaits backend confirmation")
        expect(compact(0) == "↻ 确认中", "Exact reset must not claim it has completed")
        expect(compact(0.01) == "↻ <1分", "Fractional second never displays zero")
        expect(compact(59.99) == "↻ <1分", "Below-minute boundary")
        expect(compact(60) == "↻ 1分", "Exact minute")
        expect(compact(60.01) == "↻ 2分", "Fractional minute rounds up")
        expect(compact(12 * 60) == "↻ 12分", "Minutes are compact")
        expect(compact(3_599) == "↻ 1小时", "Minute rounding crossing an hour stays coherent")
        expect(compact(3_600) == "↻ 1小时", "Exact hour omits zero minutes")
        expect(compact(3 * 3_600 + 12 * 60) == "↻ 3小时12分", "Hours and minutes")
        expect(compact(86_399) == "↻ 24小时", "One-day rounding boundary")
        expect(compact(86_400) == "↻ 1天", "Exact day omits zero hours")
        expect(compact(2 * 86_400 + 3 * 3_600 + 59 * 60) == "↻ 2天3小时", "Days retain floor-hour precision")
        expect(compact(7 * 86_400) == "↻ 7天", "Week interval needs no special prediction")

        expect(ResetCountdown.reminderLevel(until: nil, now: now) == .unknown, "Missing reset level")
        expect(level(100, stale: true) == .unknown, "Stale reset has no reminder level")
        expect(level(-1) == .awaitingConfirmation && level(0) == .awaitingConfirmation, "Elapsed reset level")
        expect(level(0.01) == .imminent && level(600) == .imminent, "Imminent range includes 10-minute boundary")
        expect(level(600.01) == .approaching && level(3_600) == .approaching, "Approaching range includes 1-hour boundary")
        expect(level(3_600.01) == .normal, "Normal immediately outside 1-hour boundary")

        let china = TimeZone(identifier: "Asia/Shanghai")!
        let utc = TimeZone(secondsFromGMT: 0)!
        let epoch = Date(timeIntervalSince1970: 0)
        expect(ResetCountdown.detail(until: epoch, timezone: china) == "1970-01-01 08:00（Asia/Shanghai，UTC+08:00）", "Detail uses supplied timezone")
        expect(ResetCountdown.detail(until: epoch, timezone: utc).contains("1970-01-01 00:00"), "UTC conversion")
        expect(ResetCountdown.detail(until: nil, timezone: china) == "账号暂未提供重置时间", "Missing detail")
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        let summer = Date(timeIntervalSince1970: 1_752_624_000) // 2025-07-16 UTC
        let winter = Date(timeIntervalSince1970: 1_736_942_400) // 2025-01-15 UTC
        expect(ResetCountdown.detail(until: summer, timezone: pacific).contains("UTC−07:00"), "DST offset uses reset date")
        expect(ResetCountdown.detail(until: winter, timezone: pacific).contains("UTC−08:00"), "Winter offset uses reset date")
        let invalid = Date(timeIntervalSince1970: .infinity)
        expect(ResetCountdown.compact(until: invalid, now: now) == "↻ 未知", "Infinite reset cannot overflow conversion")
        expect(ResetCountdown.reminderLevel(until: invalid, now: now) == .unknown, "Invalid date has no reminder")
        expect(ResetCountdown.detail(until: invalid, timezone: china) == "账号暂未提供重置时间", "Invalid date detail")
        print("ResetCountdownTests: \(checks) checks passed")
    }
}
