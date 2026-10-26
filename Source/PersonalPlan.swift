import Foundation

enum PersonalPlan {
    static func key(for window: UsageWindow) -> String? {
        window.windowDurationMins.map { "reservePercent.\($0)" }
    }

    static func reserve(for window: UsageWindow, preferences: UserDefaults) -> Int? {
        guard let key = key(for: window), preferences.object(forKey: key) != nil else { return nil }
        return min(100, max(0, preferences.integer(forKey: key)))
    }

    static func summary(for window: UsageWindow, preferences: UserDefaults, stale: Bool) -> String {
        guard let reserve = reserve(for: window, preferences: preferences) else {
            return "\(window.durationLabel)：尚未设置保留线"
        }
        guard !stale, let remaining = window.displayPercent else {
            return "\(window.durationLabel)保留 \(reserve)% · 当前余量待更新"
        }
        return "\(window.durationLabel)剩余 \(remaining)% · 保留 \(reserve)%" +
            (remaining <= reserve ? "（已到保留线）" : "")
    }
}

enum DemoScenario: String, CaseIterable {
    case announcement, timeAdded, rescheduled, withdrawn, completed, unknown, offline, invalidComment

    var title: String {
        switch self {
        case .announcement: return "1 · 新预告（先查看，变为已读）"
        case .timeAdded: return "2 · 本人回复补充明确时间"
        case .rescheduled: return "3 · 本人改期（重新提醒）"
        case .withdrawn: return "4 · 撤回时间，保持待定"
        case .completed: return "5 · 发布完成确认（余额不自动增加）"
        case .unknown: return "6 · 未知额度"
        case .offline: return "7 · 断网 / 超时"
        case .invalidComment: return "8 · 普通评论，不能采用"
        }
    }

    func usage(now: Date) -> UsageSnapshot? {
        if self == .unknown { return nil }
        return UsageSnapshot(
            primary: UsageWindow(usedPercent: 32, windowDurationMins: 300, resetsAt: now.addingTimeInterval(7200).timeIntervalSince1970),
            secondary: UsageWindow(usedPercent: 76, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(183600).timeIntervalSince1970),
            fetchedAt: now)
    }

    func messages(now: Date) -> TiboResetSnapshot {
        let originalID = "2115000000000000001"
        func url(_ id: String) -> URL { URL(string: "https://x.com/thsottiaux/status/\(id)")! }
        var pending = TiboResetAnnouncement(id: originalID,
            text: "We will reset Codex usage soon. Timing will be shared later.",
            postedAt: now.addingTimeInterval(-600), url: url(originalID), referenceResetAt: nil, resetType: "regular")
        if [.timeAdded, .rescheduled].contains(self) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm 'UTC'"
            let id = self == .timeAdded ? "2115000000000000002" : "2115000000000000003"
            pending.timeEvidence = TiboTimeEvidence(postID: id,
                text: "We will reset Codex usage by \(formatter.string(from: now.addingTimeInterval(self == .timeAdded ? 14400 : 21600))).",
                postedAt: now.addingTimeInterval(-300), url: url(id))
        }
        if self == .withdrawn {
            pending.timeWithdrawn = true
            pending.timeEvidence = TiboTimeEvidence(postID: "2115000000000000004",
                text: "The reset is postponed; the time is not confirmed.",
                postedAt: now.addingTimeInterval(-60), url: url("2115000000000000004"))
        }
        let completed = TiboResetAnnouncement(id: "2115000000000000005", text: "We have reset Codex usage limits.",
            postedAt: now.addingTimeInterval(-30), url: url("2115000000000000005"), referenceResetAt: nil, resetType: "regular")
        return TiboResetSnapshot(fetchedAt: now, sourceGeneratedAt: now,
            latest: self == .completed ? completed : nil,
            pending: [.completed, .unknown, .offline, .invalidComment].contains(self) ? nil : pending,
            hasUnverifiedPending: self == .invalidComment, hasExpiredPending: false, hasUnverifiedLatest: false)
    }
}
