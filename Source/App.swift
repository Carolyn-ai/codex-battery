import AppKit

private struct TiboMessageLink {
    let url: URL
    let readKeys: Set<String>
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let livePreferences: UserDefaults
    private var demoPreferences: UserDefaults?
    private var preferences: UserDefaults { demoPreferences ?? livePreferences }
    private var demoSuite: String?
    private var demoScenario: DemoScenario?
    private var demoRequested = false
    private var demoViewedStages = Set<String>()
    private var restoreState: (UsageSnapshot?, TiboResetSnapshot?, String?, Bool, UsageDisplayWindow)?
    private var onboardingWindow: NSWindow?
    private var onboardingLabels: [NSTextField] = []
    private var demoWindow: NSWindow?
    private var demoStateLabel: NSTextField?
    private var demoCardLabel: NSTextField?
    private var demoLogLabel: NSTextField?
    private var demoNextButton: NSButton?
    private var demoExecutionLog: [String] = []
    private var demoCardViewed = false
    private var menuTarget: NSMenu?
    private var targetMenu: NSMenu { menuTarget ?? menu }
    private var displayTimezone: TimeZone {
        preferences.bool(forKey: "useLocalTimezone") ? .current : TimeZone(identifier: "Asia/Shanghai")!
    }
    private var headlessTestMode = false
    private var menuViewedMessage: TiboAlert?
    private var menuViewedAnnouncement: TiboResetAnnouncement?
    private var supplementalScanCursor = 0
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let queue = DispatchQueue(label: "local.codex-battery.usage", qos: .utility)
    private var timer: Timer?
    private var freshnessTimer: Timer?
    private var snapshot: UsageSnapshot?
    private var refreshInProgress = false
    private var lastError: String?
    private var announcementTimer: Timer?
    private var announcements: TiboResetSnapshot?
    private var announcementError = false
    private var announcementRefreshInProgress = false
    private var announcementRefreshRequested = false
    private var selection: UsageDisplayWindow = .limiting
    private let refreshInterval: TimeInterval = 60
    private let freshnessInterval: TimeInterval = 180
    private let announcementRefreshInterval: TimeInterval = 300

    init(preferences: UserDefaults = .standard) { self.livePreferences = preferences; super.init() }

    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Battery", isDirectory: true)
    }
    private var usageDataStale: Bool {
        lastError != nil || snapshot == nil || Date().timeIntervalSince(snapshot!.fetchedAt) > freshnessInterval
    }
    private var isStale: Bool {
        usageDataStale
            || (snapshot?.chosenWindow(selection: selection)?.resetDate.map { $0 <= Date() } ?? false)
    }
    private var announcementDataStale: Bool {
        announcementError || announcements == nil || Date().timeIntervalSince(announcements!.fetchedAt) > 900
            || (announcements?.sourceGeneratedAt.map { Date().timeIntervalSince($0) > 900 } ?? false)
    }
    private var showCountdown: Bool {
        preferences.object(forKey: "showResetCountdown") == nil || preferences.bool(forKey: "showResetCountdown")
    }
    private var countdownText: String {
        ResetCountdown.compact(until: snapshot?.chosenWindow(selection: selection)?.resetDate, stale: usageDataStale)
    }
    private var acknowledgedTiboIDs: Set<String> {
        Set(preferences.stringArray(forKey: "acknowledgedTiboIDs") ?? [])
    }
    private var readTiboRevisions: Set<String> {
        Set(preferences.stringArray(forKey: "readTiboRevisions") ?? [])
    }
    private var supplementalPostIDs: [String] {
        preferences.stringArray(forKey: "supplementalTiboPostIDs") ?? []
    }
    private var activeTiboAlert: TiboAlert? {
        TiboAlert.select(from: announcements, acknowledgedIDs: [], acknowledgedRevisions: readTiboRevisions, sourceStale: announcementDataStale).map(localizedAlert)
    }
    private var displayTiboMessage: TiboAlert? {
        TiboAlert.latestDisplay(from: announcements, sourceStale: announcementDataStale).map(localizedAlert)
    }
    private func localizedAlert(_ alert: TiboAlert) -> TiboAlert {
        guard let pending = announcements?.pending, pending.id == alert.id,
              !pending.timeWithdrawn, let time = pending.announcedResetTime else { return alert }
        return TiboAlert(id: alert.id, kind: alert.kind,
            title: "Tibo \(time.compact(timezone: displayTimezone))\(pending.resetType == "banked" ? "发重置券" : "重置")",
            sourceURL: alert.sourceURL, postedAt: alert.postedAt, revisionDetails: alert.revisionDetails)
    }
    private var readTiboIndicator: String {
        guard activeTiboAlert == nil, let message = displayTiboMessage, readTiboRevisions.contains(message.readKey),
              announcements?.hasUnverifiedPending != true else { return "" }
        return message.kind == .pendingReset || message.kind == .pendingCredit ? "  · \(message.title)（已读）" : "  · ✓ Tibo已读"
    }
    private var announcementIndicator: String {
        if let alert = activeTiboAlert { return "  · \(alert.title)" }
        guard !announcementDataStale, let announcements else { return "" }
        if announcements.hasUnverifiedPending { return "  · Tibo待核实" }
        return readTiboIndicator
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: LoginLaunch.identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }
        if let saved = preferences.string(forKey: "displayWindow"),
           let value = UsageDisplayWindow(rawValue: saved) { selection = value }
        announcements = cachedVerifiedLatest()
        migrateLegacyReadState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.setAccessibilityLabel("Codex 剩余用量")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if !preferences.bool(forKey: "loginConfigured") {
            do {
                try LoginLaunch.setEnabled(true)
                preferences.set(true, forKey: "loginConfigured")
            } catch { lastError = "登录启动设置未能保存，可在菜单中重试。" }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(appearanceChanged), name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.updateDisplay() }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(freshnessTimer!, forMode: .common)
        announcementTimer = Timer.scheduledTimer(withTimeInterval: announcementRefreshInterval, repeats: true) { [weak self] _ in self?.refreshAnnouncements() }
        RunLoop.main.add(announcementTimer!, forMode: .common)
        rebuildMenu()
        updateDisplay()
        refresh()
        refreshAnnouncements()
        if !livePreferences.bool(forKey: "onboardingDismissed") {
            DispatchQueue.main.async { self.showOnboarding() }
        }
    }

    @objc private func appearanceChanged() { updateDisplay() }
    @objc private func wokeUp() { updateDisplay(); refresh(); refreshAnnouncements() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if demoScenario != nil { showDemoControls() } else { showOnboarding() }
        return true
    }

    @objc private func showStatusMenu() { statusItem?.button?.performClick(nil) }

    @objc private func refreshAnnouncements() {
        guard !headlessTestMode, demoScenario == nil, !demoRequested else { return }
        guard !announcementRefreshInProgress else { announcementRefreshRequested = true; return }
        announcementRefreshInProgress = true
        let savedIDs = Array(supplementalPostIDs.reversed())
        var additionalIDs = Array(savedIDs.prefix(1))
        let olderIDs = Array(savedIDs.dropFirst())
        if !olderIDs.isEmpty {
            let offset = supplementalScanCursor % olderIDs.count
            additionalIDs += Array(olderIDs[offset...]) + Array(olderIDs[..<offset])
            supplementalScanCursor += 1
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try TiboResetMonitor(additionalPostIDs: additionalIDs).fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.announcementRefreshInProgress = false
                switch result {
                case .success(let data):
                    self.applyAnnouncementUpdate(data)
                    self.announcementError = false
                case .failure: self.announcementError = true
                }
                self.startDemoIfReady()
                self.updateDisplay()
                self.rebuildMenu()
                if self.announcementRefreshRequested {
                    self.announcementRefreshRequested = false
                    self.refreshAnnouncements()
                }
            }
        }
    }

    @objc private func refresh() {
        guard !headlessTestMode, demoScenario == nil, !demoRequested else { return }
        guard !refreshInProgress else { return }
        refreshInProgress = true
        rebuildMenu()
        writeStatus()
        queue.async { [weak self] in
            let result = Result { try UsageClient().fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInProgress = false
                switch result {
                case .success(let data): self.snapshot = data; self.lastError = nil
                case .failure(let error): self.lastError = error.localizedDescription
                }
                self.startDemoIfReady()
                self.updateDisplay()
                self.rebuildMenu()
            }
        }
    }

    private func updateDisplay() {
        guard !headlessTestMode else { return }
        let percent = snapshot?.chosenWindow(selection: selection)?.displayPercent
        let alert = activeTiboAlert
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        statusItem.button?.image = BatteryIcon.image(percent: percent, stale: isStale, dark: dark, alert: alert != nil)
        let reminderLevel = ResetCountdown.reminderLevel(until: snapshot?.chosenWindow(selection: selection)?.resetDate, stale: usageDataStale)
        let title = NSMutableAttributedString(attributedString: AlertAppearance.title(countdown: showCountdown ? countdownText : "", alert: alert,
            fallbackIndicator: alert == nil && readTiboIndicator.isEmpty ? announcementIndicator : "", imminent: reminderLevel == .imminent,
            readIndicator: alert == nil ? readTiboIndicator : ""))
        if demoScenario != nil {
            title.insert(NSAttributedString(string: "演示模式｜虚构示例  ", attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.boldSystemFont(ofSize: 12)]), at: 0)
        }
        statusItem.button?.attributedTitle = title
        let label = snapshot?.selectedLabel(selection: selection) ?? "Codex"
        let description = (!isStale ? percent.map { "\($0)%" } : nil) ?? "暂不可用"
        let resetDetail = ResetCountdown.detail(until: snapshot?.chosenWindow(selection: selection)?.resetDate, timezone: displayTimezone)
        let alertDetail = alert.map { "\n新变化：\($0.title)；打开消息详情后自动已读" } ?? (readTiboIndicator.isEmpty ? "" : "\nTibo消息已读；有新预告、补充时间或确认消息会再次亮红")
        statusItem.button?.toolTip = "Codex · \(label)剩余 \(description)\n账号周期重置：\(resetDetail)\(alertDetail)\n消息发布不等于本人账号已重置"
        statusItem.button?.setAccessibilityValue("\(label)剩余 \(description)，周期重置 \(countdownText)\(announcementIndicator)")
        writeStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Acknowledge the exact revision whose summary is about to be shown, never a later fetch.
        let viewed = activeTiboAlert ?? displayTiboMessage
        menuViewedMessage = viewed
        menuViewedAnnouncement = announcements?.pending?.id == viewed?.id ? announcements?.pending : announcements?.latest
        if let viewed {
            saveReadKeys(TiboAlert.revisionKeysToAcknowledge(alert: viewed, snapshot: announcements))
        }
        updateDisplay()
        rebuildMenu()
        refresh()
        if announcements == nil || Date().timeIntervalSince(announcements!.fetchedAt) > announcementRefreshInterval {
            refreshAnnouncements()
        }
    }

    func menuDidClose(_ menu: NSMenu) { menuViewedMessage = nil; menuViewedAnnouncement = nil }

    private func info(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        targetMenu.addItem(item)
    }

    @discardableResult
    private func action(_ title: String, selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        targetMenu.addItem(item)
        return item
    }

    private func rebuildMenu() {
        menuTarget = nil
        menu.removeAllItems()
        timeFormatter.timeZone = displayTimezone
        resetFormatter.timeZone = displayTimezone
        if demoScenario != nil { info("演示模式｜虚构示例 · 不发外部请求") }
        info("Codex 电量管家 · 账号剩余额度")
        info("电池内数字 = 剩余额度")
        if let alert = menuViewedMessage ?? activeTiboAlert ?? displayTiboMessage {
            targetMenu.addItem(.separator())
            let unread = activeTiboAlert?.readKey == alert.readKey
            let message = menuViewedMessage?.readKey == alert.readKey ? menuViewedAnnouncement : (announcements?.pending?.id == alert.id ? announcements?.pending : announcements?.latest)
            let isPreview = alert.kind == .pendingReset || alert.kind == .pendingCredit
            let detailURL = isPreview ? (message?.timeEvidence?.url ?? alert.sourceURL) : alert.sourceURL
            let item = messageLink("\(unread ? "🔴 新变化" : "✓ 已读") · \(alert.title) · 查看消息", url: detailURL, message: alert)
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: unread ? NSColor.systemRed : NSColor.labelColor
            ])
            info("发布于 \(resetFormatter.string(from: alert.postedAt))；账号额度以电池读数为准")
            if let message {
                for line in wrap(String(message.text.prefix(140))) { info(line) }
            }
            info("打开本详情即已读；新时间或新确认会再提醒")
        }
        targetMenu.addItem(.separator())
        if let snapshot {
            if snapshot.windows.isEmpty { info("账号未提供额度百分比") }
            for window in snapshot.windows {
                let value = window.displayPercent.map { "\($0)%" } ?? "未知"
                let staleSuffix = (usageDataStale || (window.resetDate.map { $0 <= Date() } ?? false)) ? "（上次读数）" : ""
                info("\(window.durationLabel)剩余：\(value)\(staleSuffix)")
                if let reset = window.resetDate {
                    info("  周期重置：\(resetFormatter.string(from: reset))")
                }
            }
            info("上次更新：\(timeFormatter.string(from: snapshot.fetchedAt))")
        } else {
            info(refreshInProgress ? "正在读取账号用量…" : "暂未取得用量数据")
        }
        if let lastError {
            info("刷新失败，电池显示 --")
            for line in wrap(lastError) { info(line) }
        } else if isStale && snapshot != nil {
            info("读数已过期，等待刷新")
        }
        targetMenu.addItem(.separator())
        info("账号周期重置：\(countdownText)")
        if let reset = snapshot?.chosenWindow(selection: selection)?.resetDate {
            info(ResetCountdown.detail(until: reset, timezone: displayTimezone))
        }
        let countdownItem = action("电池旁显示重置倒计时", selector: #selector(toggleCountdown))
        countdownItem.state = showCountdown ? .on : .off
        targetMenu.addItem(.separator())
        if demoScenario == nil && activeTiboAlert == nil && displayTiboMessage == nil {
            info(announcementDataStale ? "Tibo：消息来源待更新" : "Tibo：暂无可查看的真实新消息")
        }
        let sourceDetails = NSMenu()
        menuTarget = sourceDetails
        info("Tibo 临时重置消息")
        if announcementDataStale {
            info(announcementRefreshInProgress ? "正在查询公开预告…" : "消息待更新，暂不能确认预告")
        } else if let pending = announcements?.pending {
            info(pending.resetType == "banked" ? "已核对 Tibo 原帖：重置券预告" : "已核对 Tibo 原帖：重置预告")
            info("生效状态仍待确认")
            for line in wrap(String(pending.text.prefix(100))) { info(line) }
            if pending.timeWithdrawn {
                info("Tibo 后续更正：此前时间已调整或撤回")
                info("新的具体时间待明确")
            } else if let announcedTime = pending.announcedResetTime {
                info("原帖重置时间：\(announcedTime.detail(timezone: displayTimezone))")
                info("以上时间已换算为 \(displayTimezone.identifier)")
            } else if let reference = pending.referenceResetAt {
                info("社区参考截止：\(resetFormatter.string(from: reference))")
                info("预告时间可能调整，以账号更新为准")
            } else { info("尚无可确认的准确重置时间") }
            messageLink("查看这条 X 原帖", url: pending.url, message: messageAlert(pending, pending: true))
            if let evidence = pending.timeEvidence {
                info("时间说明/更正来自 Tibo 本人的补充消息")
                messageLink("查看时间补充的 X 原帖", url: evidence.url, message: messageAlert(pending, pending: true))
            }
            for related in pending.relatedPosts.prefix(4) where related.postID != pending.id && related.postID != pending.timeEvidence?.postID {
                messageLink("相关回复/引用：\(resetFormatter.string(from: related.postedAt))", url: related.url, message: messageAlert(pending, pending: true))
            }
        } else if announcements?.hasUnverifiedPending == true {
            info("来源发现预告，X 原帖尚未核实")
        } else if announcements?.hasExpiredPending == true {
            info("来源预告已过参考时限，生效待确认")
        } else {
            info("暂未发现可用的待生效预告")
        }
        if !announcementDataStale, let latest = announcements?.latest {
            info("最近核对的\(latest.resetType == "banked" ? "重置券" : "重置")消息：\(resetFormatter.string(from: latest.postedAt))")
            messageLink("查看最近消息的 X 原帖", url: latest.url, message: messageAlert(latest, pending: false))
            for related in latest.relatedPosts.prefix(4) where related.postID != latest.id {
                messageLink("相关预告/回复：\(resetFormatter.string(from: related.postedAt))", url: related.url, message: messageAlert(latest, pending: false))
            }
        }
        if let fetched = announcements?.fetchedAt {
            info("消息检查：\(timeFormatter.string(from: fetched))")
        }
        action(announcementRefreshInProgress ? "正在检查预告…" : "检查 Tibo 预告", selector: #selector(refreshAnnouncements)).isEnabled = !announcementRefreshInProgress
        action("打开 Tibo 的 X", selector: #selector(openTibo))
        action("补充一条 Tibo 帖子链接…", selector: #selector(addSupplementalTiboLink))
        let sourceItem = action("动态来源：Codex Resets（社区）", selector: #selector(openPublicLink(_:)))
        sourceItem.representedObject = URL(string: "https://codex-resets.com/")!
        let extraSource = action("回复线索：Nightwatch（社区，有延迟）", selector: #selector(openPublicLink(_:)))
        extraSource.representedObject = URL(string: "https://will-codex-reset.com/")!
        if let scanned = announcements?.supplementalScannedAt { info("补充来源扫描：\(timeFormatter.string(from: scanned))") }
        info("每 5 分钟检查；无法保证覆盖全部评论")
        if !supplementalPostIDs.isEmpty { info("已保存 \(supplementalPostIDs.count) 条补充链接，仅采用核实且相关的消息") }
        targetMenu.addItem(.separator())
        menuTarget = nil
        let sourceEntry = NSMenuItem(title: "Tibo 来源与核实明细", action: nil, keyEquivalent: "")
        sourceEntry.submenu = sourceDetails
        menu.addItem(sourceEntry)
        action("补充一条 Tibo 帖子链接…", selector: #selector(addSupplementalTiboLink)).isEnabled = demoScenario == nil && !demoRequested
        targetMenu.addItem(.separator())
        addPlanMenu()
        addDemoMenu()
        action("首次使用与状态检查…", selector: #selector(showOnboarding))
        let settings = NSMenu()
        menuTarget = settings
        let periods: [(UsageDisplayWindow, String)] = [(.limiting, "显示：剩余最少的周期"), (.shortTerm, "显示：短期额度"), (.weekly, "显示：每周额度")]
        for (value, title) in periods {
            let item = action(title, selector: #selector(changeSelection(_:)))
            item.representedObject = value.rawValue
            item.state = selection == value ? .on : .off
            item.isEnabled = value == .limiting || snapshot?.chosenWindow(selection: value) != nil
        }
        targetMenu.addItem(.separator())
        let refreshItem = action(refreshInProgress ? "正在刷新…" : "立即刷新", selector: #selector(refresh), key: "r")
        refreshItem.isEnabled = !refreshInProgress
        info("每 60 秒自动刷新")
        action("打开 Codex", selector: #selector(openCodex))
        let timezoneItem = action("使用本地时区（默认北京时间）", selector: #selector(toggleTimezone))
        timezoneItem.state = preferences.bool(forKey: "useLocalTimezone") ? .on : .off
        action("查看使用说明", selector: #selector(showHelp))
        let loginItem = action("登录时自动启动", selector: #selector(toggleLogin))
        loginItem.state = LoginLaunch.isEnabled ? .on : .off
        loginItem.isEnabled = demoScenario == nil
        action("完整卸载说明…", selector: #selector(showUninstall))
        menuTarget = nil
        let settingsEntry = NSMenuItem(title: "显示、启动与帮助", action: nil, keyEquivalent: "")
        settingsEntry.submenu = settings
        menu.addItem(settingsEntry)
        action(refreshInProgress ? "正在刷新…" : "重新检查真实额度", selector: #selector(refresh)).isEnabled = demoScenario == nil && !demoRequested && !refreshInProgress
        targetMenu.addItem(.separator())
        action("退出 Codex 电量管家", selector: #selector(quit), key: "q")
        updateOnboarding()
        updateDemoControls()
    }

    private func wrap(_ text: String) -> [String] {
        let safe = String(text.prefix(180)).replacingOccurrences(of: "\n", with: " ")
        var result: [String] = []; var line = ""
        for ch in safe {
            line.append(ch)
            if line.count >= 32 { result.append(line); line = "" }
        }
        if !line.isEmpty { result.append(line) }
        return result
    }

    @objc private func changeSelection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = UsageDisplayWindow(rawValue: raw) else { return }
        selection = value
        preferences.set(raw, forKey: "displayWindow")
        updateDisplay()
        rebuildMenu()
    }

    @objc private func openCodex() {
        guard demoScenario == nil else { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func toggleCountdown() {
        preferences.set(!showCountdown, forKey: "showResetCountdown")
        updateDisplay(); rebuildMenu()
    }

    @objc private func acknowledgeTiboAlert() {
        guard let alert = activeTiboAlert else { return }
        saveReadKeys(TiboAlert.revisionKeysToAcknowledge(alert: alert, snapshot: announcements))
        updateDisplay(); rebuildMenu()
    }

    private func saveReadKeys(_ keys: Set<String>) {
        var saved = preferences.stringArray(forKey: "readTiboRevisions") ?? []
        for key in keys.sorted() { saved.removeAll { $0 == key }; saved.append(key) }
        preferences.set(Array(saved.suffix(300)), forKey: "readTiboRevisions")
        if let demoScenario {
            demoViewedStages.insert(demoScenario.rawValue)
        } else if !keys.isEmpty {
            livePreferences.set(true, forKey: "realMessageViewed")
        }
    }

    private func migrateLegacyReadState() {
        var migrated = Set(preferences.stringArray(forKey: "migratedTiboReadIDs") ?? [])
        for message in [announcements?.pending, announcements?.latest].compactMap({ $0 }) {
            guard acknowledgedTiboIDs.contains(message.id), !migrated.contains(message.id),
                  let alert = messageAlert(message, pending: announcements?.pending?.id == message.id) else { continue }
            saveReadKeys(TiboAlert.revisionKeysToAcknowledge(alert: alert, snapshot: announcements))
            migrated.insert(message.id)
        }
        preferences.set(Array(migrated), forKey: "migratedTiboReadIDs")
    }

    private func messageAlert(_ message: TiboResetAnnouncement, pending: Bool) -> TiboAlert? {
        let single = TiboResetSnapshot(fetchedAt: Date(), sourceGeneratedAt: nil, latest: pending ? nil : message,
            pending: pending ? message : nil, hasUnverifiedPending: false, hasExpiredPending: false, hasUnverifiedLatest: false)
        return TiboAlert.latestDisplay(from: single)
    }

    @discardableResult
    private func messageLink(_ title: String, url: URL, message: TiboAlert?) -> NSMenuItem {
        let item = action(title, selector: #selector(openTiboMessage(_:)))
        item.representedObject = TiboMessageLink(url: url, readKeys: message.map { TiboAlert.revisionKeysToAcknowledge(alert: $0, snapshot: announcements) } ?? [])
        return item
    }

    @objc private func openTiboMessage(_ sender: NSMenuItem) {
        guard demoScenario == nil, let link = sender.representedObject as? TiboMessageLink, link.url.scheme == "https", link.url.host == "x.com" else { return }
        if NSWorkspace.shared.open(link.url) {
            saveReadKeys(link.readKeys)
            updateDisplay(); rebuildMenu()
        }
    }

    @objc private func addSupplementalTiboLink() {
        guard demoScenario == nil, !demoRequested else { return }
        let alert = NSAlert()
        alert.messageText = "补充 Tibo 的回复或后续帖文"
        alert.informativeText = "粘贴 Tibo 本人的 X 帖子链接。程序会核对作者和关联关系；普通评论及猜测不会成为确定的重置时间。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
        field.placeholderString = "https://x.com/thsottiaux/status/…"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存并核对"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let id = TiboPostLink.postID(from: field.stringValue) else {
            let invalid = NSAlert(); invalid.messageText = "请输入 Tibo 本人的有效 X 帖子链接"; invalid.runModal(); return
        }
        var ids = supplementalPostIDs.filter { $0 != id }; ids.append(id)
        preferences.set(Array(ids.suffix(12)), forKey: "supplementalTiboPostIDs")
        supplementalScanCursor = 0
        refreshAnnouncements(); rebuildMenu()
    }

    private func cacheVerifiedLatest() {
        guard let latest = announcements?.latest else { return }
        var record: [String: Any] = [
            "id": latest.id, "text": String(latest.text.prefix(1000)), "postedAt": latest.postedAt,
            "url": latest.url.absoluteString, "resetType": latest.resetType
        ]
        if let evidence = latest.timeEvidence { record["timeEvidence"] = evidenceRecord(evidence) }
        record["timeWithdrawn"] = latest.timeWithdrawn
        record["relatedPosts"] = latest.relatedPosts.prefix(6).map(evidenceRecord)
        preferences.set(record, forKey: "lastVerifiedTiboLatest")
    }

    private func applyAnnouncementUpdate(_ incoming: TiboResetSnapshot) {
        var previous = announcements
        if previous?.pending == nil, let fact = cachedPendingFacts() {
            previous = TiboResetSnapshot(fetchedAt: .distantPast, sourceGeneratedAt: nil, latest: previous?.latest, pending: fact,
                hasUnverifiedPending: false, hasExpiredPending: false, hasUnverifiedLatest: false)
        }
        announcements = TiboAlert.preservingVerifiedLatest(in: incoming, previous: previous)
        cacheVerifiedLatest()
        if let pending = announcements?.pending, let evidence = pending.timeEvidence {
            var record: [String: Any] = ["id": pending.id, "text": pending.text, "postedAt": pending.postedAt,
                "url": pending.url.absoluteString, "resetType": pending.resetType, "timeWithdrawn": pending.timeWithdrawn,
                "timeEvidence": evidenceRecord(evidence)]
            if let reference = pending.referenceResetAt { record["referenceResetAt"] = reference }
            preferences.set(record, forKey: "lastVerifiedTiboPendingFacts")
        }
        migrateLegacyReadState()
    }

    private func cachedPendingFacts() -> TiboResetAnnouncement? {
        guard let record = preferences.dictionary(forKey: "lastVerifiedTiboPendingFacts"),
              let id = record["id"] as? String, let text = record["text"] as? String,
              let date = record["postedAt"] as? Date, Date().timeIntervalSince(date) <= 172_800,
              Date().timeIntervalSince(date) >= -300,
              let rawURL = record["url"] as? String, TiboPostLink.postID(from: rawURL) == id,
              let url = URL(string: rawURL), let resetType = record["resetType"] as? String,
              let evidence = cachedEvidence(record["timeEvidence"]) else { return nil }
        var fact = TiboResetAnnouncement(id: id, text: text, postedAt: date, url: url,
            referenceResetAt: record["referenceResetAt"] as? Date, resetType: resetType)
        fact.timeEvidence = evidence
        fact.timeWithdrawn = record["timeWithdrawn"] as? Bool ?? false
        return fact
    }

    private func evidenceRecord(_ evidence: TiboTimeEvidence) -> [String: Any] {
        ["id": evidence.postID, "text": String(evidence.text.prefix(1000)), "postedAt": evidence.postedAt, "url": evidence.url.absoluteString]
    }

    private func cachedEvidence(_ value: Any?) -> TiboTimeEvidence? {
        guard let record = value as? [String: Any], let id = record["id"] as? String,
              let text = record["text"] as? String, let date = record["postedAt"] as? Date,
              let rawURL = record["url"] as? String, let url = URL(string: rawURL), TiboPostLink.postID(from: rawURL) == id else { return nil }
        return TiboTimeEvidence(postID: id, text: text, postedAt: date, url: url)
    }

    private func cachedVerifiedLatest() -> TiboResetSnapshot? {
        guard let value = preferences.dictionary(forKey: "lastVerifiedTiboLatest"),
              let id = value["id"] as? String, let text = value["text"] as? String,
              let postedAt = value["postedAt"] as? Date, let rawURL = value["url"] as? String,
              let url = URL(string: rawURL), let resetType = value["resetType"] as? String else { return nil }
        var latest = TiboResetAnnouncement(id: id, text: text, postedAt: postedAt, url: url, referenceResetAt: nil, resetType: resetType)
        latest.timeEvidence = cachedEvidence(value["timeEvidence"])
        latest.timeWithdrawn = value["timeWithdrawn"] as? Bool ?? false
        latest.relatedPosts = (value["relatedPosts"] as? [[String: Any]] ?? []).compactMap(cachedEvidence)
        let cached = TiboResetSnapshot(fetchedAt: .distantPast, sourceGeneratedAt: nil, latest: latest, pending: nil,
            hasUnverifiedPending: false, hasExpiredPending: false, hasUnverifiedLatest: false)
        // The alert selector validates canonical URL, date and lifetime before displaying cached facts.
        return TiboAlert.select(from: cached, acknowledgedIDs: [], sourceStale: true) == nil ? nil : cached
    }

    @objc private func openTibo() { guard demoScenario == nil else { return }; NSWorkspace.shared.open(URL(string: "https://x.com/thsottiaux")!) }

    @objc private func openPublicLink(_ sender: NSMenuItem) {
        guard demoScenario == nil, let url = sender.representedObject as? URL, url.scheme == "https",
              ["x.com", "codex-resets.com", "will-codex-reset.com"].contains(url.host ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLogin() {
        guard demoScenario == nil else { return }
        do { try LoginLaunch.setEnabled(!LoginLaunch.isEnabled) }
        catch {
            let alert = NSAlert()
            alert.messageText = "无法保存登录启动设置"
            alert.informativeText = "请确认当前用户可以写入“资源库/LaunchAgents”文件夹。"
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); freshnessTimer?.invalidate(); announcementTimer?.invalidate()
        if let suite = demoSuite { demoPreferences?.removePersistentDomain(forName: suite) }
        if !headlessTestMode { try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("demo-status.json")) }
        if statusItem != nil {
            try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("status.json"))
        }
    }

    private func writeStatus() {
        guard !headlessTestMode else { return }
        var status: [String: Any] = [
            "appVersion": "1.5.2",
            "demoMode": demoScenario != nil, "demoScenario": demoScenario?.rawValue ?? "",
            "demoOperationLog": demoScenario == nil ? [] : demoExecutionLog,
            "timezone": displayTimezone.identifier, "processId": ProcessInfo.processInfo.processIdentifier,
            "isRefreshing": refreshInProgress, "isStale": isStale,
            "refreshIntervalSeconds": Int(refreshInterval), "loginEnabled": LoginLaunch.isEnabled,
            "selection": selection.rawValue, "statusItemVisible": statusItem?.isVisible ?? false,
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "countdownText": countdownText,
            "menuBarTitle": statusItem?.button?.attributedTitle.string ?? "",
            "statusItemWidth": Double(statusItem?.button?.frame.width ?? 0),
            "menuBarIconWidth": Double(statusItem?.button?.image?.size.width ?? 0),
            "showResetCountdown": showCountdown,
            "tiboCheckIntervalSeconds": Int(announcementRefreshInterval),
            "tiboSourceStale": announcementDataStale,
            "tiboSource": "https://codex-resets.com/api/v1/status",
            "tiboPending": !announcementDataStale && announcements?.pending != nil,
            "tiboRedAlertActive": activeTiboAlert != nil,
            "tiboBadgeStyle": activeTiboAlert == nil ? "none" : "red-circle-exclamation",
            "tiboAcknowledgedCount": acknowledgedTiboIDs.count,
            "tiboReadRevisionCount": readTiboRevisions.count,
            "tiboReadIndicator": readTiboIndicator,
            "tiboAutoReadOnView": true,
            "tiboSupplementalLinkCount": supplementalPostIDs.count
        ]
        if let snapshot {
            status["lastUpdatedAt"] = ISO8601DateFormatter().string(from: snapshot.fetchedAt)
            status["period"] = snapshot.selectedLabel(selection: selection)
            if let reset = snapshot.chosenWindow(selection: selection)?.resetDate {
                status["resetAt"] = ISO8601DateFormatter().string(from: reset)
                status["resetLocalTime"] = ResetCountdown.detail(until: reset, timezone: displayTimezone)
            }
            if let percent = snapshot.chosenWindow(selection: selection)?.displayPercent, !isStale {
                status["displayedPercent"] = percent
            }
        }
        if let announcements {
            status["tiboLastCheckedAt"] = ISO8601DateFormatter().string(from: announcements.fetchedAt)
            if let latest = announcements.latest { status["tiboLatestVerifiedPost"] = latest.url.absoluteString }
            if let pending = announcements.pending { status["tiboPendingPost"] = pending.url.absoluteString }
            status["tiboTimeWithdrawn"] = announcements.pending?.timeWithdrawn ?? false
            if let latest = announcements.latest { status["tiboRelatedVerifiedPosts"] = latest.relatedPosts.map { $0.url.absoluteString } }
            if let pending = announcements.pending, let announced = pending.announcedResetTime {
                status["tiboAnnouncedResetAt"] = ISO8601DateFormatter().string(from: announced.date)
                status["tiboAnnouncedResetQualifier"] = announced.qualifier.rawValue
                status["tiboAnnouncedResetLocal"] = announced.detail(timezone: displayTimezone)
                status["tiboTimeEvidencePost"] = pending.timeEvidence?.url.absoluteString ?? pending.url.absoluteString
            }
            if let scanned = announcements.supplementalScannedAt { status["tiboSupplementalScannedAt"] = ISO8601DateFormatter().string(from: scanned) }
            status["tiboSupplementalDiscoveryAvailable"] = announcements.supplementalDiscoveryAvailable
        }
        if let alert = activeTiboAlert {
            status["tiboRedAlertPost"] = alert.sourceURL.absoluteString
            status["tiboRedAlertKind"] = alert.kind.rawValue
            status["tiboRedAlertTitle"] = alert.title
            if let title = statusItem?.button?.attributedTitle {
                let range = (title.string as NSString).range(of: alert.title)
                if range.location != NSNotFound,
                   let color = title.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor {
                    status["tiboAlertTextIsRed"] = color.isEqual(NSColor.systemRed)
                }
            }
        }
        if let lastError { status["error"] = lastError }
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: supportDirectory.appendingPathComponent(demoScenario == nil ? "status.json" : "demo-status.json"), options: .atomic)
        } catch { /* Diagnostics must never interrupt the menu bar. */ }
    }

    private let timeFormatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "MM-dd HH:mm:ss"; return value
    }()
    private let resetFormatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "MM月dd日 HH:mm"; return value
    }()

    @objc private func toggleTimezone() {
        preferences.set(!preferences.bool(forKey: "useLocalTimezone"), forKey: "useLocalTimezone")
        updateDisplay(); rebuildMenu()
    }

    private func addPlanMenu() {
        let plan = NSMenu()
        menuTarget = plan
        info("个人保留线 · 仅本机提醒，不增加额度")
        for window in snapshot?.windows ?? [] {
            let stale = usageDataStale || (window.resetDate.map { $0 <= Date() } ?? false)
            info(PersonalPlan.summary(for: window, preferences: preferences, stale: stale))
            if let key = PersonalPlan.key(for: window) {
                let item = action("设置\(window.durationLabel)保留线…", selector: #selector(editReserve(_:)))
                item.representedObject = key
            }
        }
        if snapshot?.windows.isEmpty != false { info("读到真实周期后可设置保留线") }
        let note = preferences.string(forKey: "taskNote") ?? ""
        info(note.isEmpty ? "今日便签：未填写" : "今日便签：\(String(note.prefix(40)))")
        action("编辑今日便签…", selector: #selector(editNote))
        menuTarget = nil
        let item = NSMenuItem(title: "个人用量安排", action: nil, keyEquivalent: "")
        item.submenu = plan
        menu.addItem(item)
        for window in snapshot?.windows ?? [] {
            guard let reserve = PersonalPlan.reserve(for: window, preferences: preferences),
                  !usageDataStale, (window.resetDate.map { $0 > Date() } ?? true),
                  let remaining = window.displayPercent, remaining <= reserve else { continue }
            info("⚑ \(window.durationLabel)已到个人保留线 \(reserve)%")
        }
    }

    @objc private func editReserve(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, key.hasPrefix("reservePercent.") else { return }
        let alert = NSAlert()
        alert.messageText = "设置希望保留的额度比例"
        alert.informativeText = "输入 0–100 的整数；留空取消这条保留线。它只提醒当前周期余量，不预测任务数，也不增加服务额度。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 25))
        field.stringValue = preferences.object(forKey: key) == nil ? "" : String(preferences.integer(forKey: key))
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { preferences.removeObject(forKey: key) }
        else if let value = Int(text), (0...100).contains(value) { preferences.set(value, forKey: key) }
        else {
            let error = NSAlert(); error.messageText = "请输入 0–100 的整数"; error.runModal(); return
        }
        rebuildMenu(); writeStatus()
    }

    @objc private func editNote() {
        let alert = NSAlert()
        alert.messageText = demoScenario == nil ? "今日任务便签 · 只保存在本机" : "演示便签 · 退出后丢弃"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
        field.stringValue = preferences.string(forKey: "taskNote") ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            preferences.set(String(field.stringValue.prefix(200)), forKey: "taskNote")
            rebuildMenu()
        }
    }

    private func addDemoMenu() {
        if demoScenario != nil {
            let steps = NSMenu()
            menuTarget = steps
            for step in DemoScenario.allCases {
                let item = action(step.title, selector: #selector(selectDemoScenario(_:)))
                item.representedObject = step.rawValue
                item.state = demoScenario == step ? .on : .off
            }
            action("导出演示状态示意图…", selector: #selector(exportDemoImage))
            menuTarget = nil
            let item = NSMenuItem(title: "演示步骤｜虚构示例", action: nil, keyEquivalent: "")
            item.submenu = steps
            menu.addItem(item)
            action("退出演示，恢复真实状态", selector: #selector(exitDemo))
        } else {
            action(demoRequested ? "等待本次查询结束后进入演示…" : "进入隔离演示（虚构示例）", selector: #selector(beginDemo)).isEnabled = !demoRequested
        }
    }

    @objc private func beginDemo() {
        guard demoScenario == nil else { showDemoControls(); return }
        demoRequested = true
        startDemoIfReady()
        rebuildMenu()
    }

    private func startDemoIfReady() {
        // Drain existing bounded requests before entering; timers cannot start new requests while requested.
        guard demoRequested, !refreshInProgress, !announcementRefreshInProgress, demoScenario == nil else { return }
        restoreState = (snapshot, announcements, lastError, announcementError, selection)
        let suite = "local.codex-battery.demo." + UUID().uuidString
        demoSuite = suite
        demoPreferences = UserDefaults(suiteName: suite)!
        demoPreferences?.removePersistentDomain(forName: suite)
        demoViewedStages.removeAll()
        demoExecutionLog.removeAll()
        announcementRefreshRequested = false
        selection = .limiting
        demoRequested = false
        applyDemo(.announcement)
        if !headlessTestMode { showDemoControls() }
    }

    @objc private func selectDemoScenario(_ sender: NSMenuItem) {
        guard demoScenario != nil, let raw = sender.representedObject as? String, let value = DemoScenario(rawValue: raw) else { return }
        applyDemo(value)
    }

    private func applyDemo(_ scenario: DemoScenario) {
        guard demoPreferences != nil else { return }
        demoScenario = scenario
        demoCardViewed = false
        let now = Date()
        snapshot = scenario.usage(now: now)
        announcements = scenario.messages(now: now)
        lastError = scenario == .offline ? "演示：网络中断或查询超时，请重新检查。" : nil
        announcementError = scenario == .offline
        menuViewedMessage = nil; menuViewedAnnouncement = nil
        appendDemoLog("切换虚构场景：\(scenario.title)")
        updateDisplay(); rebuildMenu()
    }

    @objc private func exitDemo() {
        guard demoScenario != nil, let restored = restoreState else { return }
        let required = [DemoScenario.announcement, .timeAdded, .rescheduled, .withdrawn, .completed].map(\.rawValue)
        if required.allSatisfy({ demoViewedStages.contains($0) }) {
            livePreferences.set(true, forKey: "demoInteractionCompleted")
        }
        if let suite = demoSuite { demoPreferences?.removePersistentDomain(forName: suite) }
        if !headlessTestMode { try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("demo-status.json")) }
        demoPreferences = nil; demoSuite = nil; demoScenario = nil; restoreState = nil
        demoWindow?.close()
        snapshot = restored.0; announcements = restored.1; lastError = restored.2
        announcementError = restored.3; selection = restored.4
        menuViewedMessage = nil; menuViewedAnnouncement = nil
        updateDisplay(); rebuildMenu()
        refresh(); refreshAnnouncements()
        if !headlessTestMode { showOnboarding() }
    }

    private func appendDemoLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"; formatter.timeZone = displayTimezone
        demoExecutionLog.append("\(formatter.string(from: Date()))  \(message)")
    }

    @objc private func viewDemoMessage() {
        guard demoScenario != nil, let viewed = activeTiboAlert ?? displayTiboMessage else { return }
        let keys = TiboAlert.revisionKeysToAcknowledge(alert: viewed, snapshot: announcements)
        demoCardViewed = true
        saveReadKeys(keys)
        appendDemoLog("展示当前版本摘要 → 记为已读 → 关闭该版本红色提醒")
        updateDisplay(); rebuildMenu()
    }

    @objc private func nextDemoStep() {
        guard let current = demoScenario else { return }
        let steps: [DemoScenario] = [.announcement, .timeAdded, .rescheduled, .withdrawn, .completed]
        guard let index = steps.firstIndex(of: current), index + 1 < steps.count else { return }
        applyDemo(steps[index + 1])
    }

    private func showDemoControls() {
        guard demoScenario != nil, !headlessTestMode else { return }
        if let demoWindow {
            updateDemoControls(); demoWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Codex 电量管家 · 虚构演示与执行记录"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        func label(_ text: String, size: CGFloat = 14) -> NSTextField {
            let value = NSTextField(wrappingLabelWithString: text)
            value.preferredMaxLayoutWidth = 608; value.font = .systemFont(ofSize: size)
            stack.addArrangedSubview(value); return value
        }
        let title = label("演示模式｜虚构示例", size: 23)
        title.textColor = .systemOrange; title.font = .boldSystemFont(ofSize: 23)
        _ = label("此窗口展示实际执行的演示操作。演示余额为虚构数据；不发外部请求，不改真实设置与已读。")
        demoStateLabel = label("", size: 18)
        demoCardLabel = label("")
        let row = NSStackView(); row.spacing = 10
        let view = NSButton(title: "查看当前消息（自动已读）", target: self, action: #selector(viewDemoMessage))
        view.bezelStyle = .rounded; row.addArrangedSubview(view)
        let next = NSButton(title: "下一步", target: self, action: #selector(nextDemoStep))
        next.bezelStyle = .rounded; row.addArrangedSubview(next); demoNextButton = next
        stack.addArrangedSubview(row)
        _ = label("执行记录", size: 16)
        demoLogLabel = label("")
        let exit = NSButton(title: "结束演示，恢复真实状态", target: self, action: #selector(exitDemo))
        exit.bezelStyle = .rounded; stack.addArrangedSubview(exit)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        demoWindow = window; updateDemoControls(); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateDemoControls() {
        guard let scenario = demoScenario else { return }
        let unread = activeTiboAlert != nil
        let state = unread ? "🔴 新变化，等待查看" : "✓ 当前版本已读"
        demoStateLabel?.stringValue = "\(scenario.title)\n\(state) · 虚构余额 24%"
        demoStateLabel?.textColor = unread ? .systemRed : .secondaryLabelColor
        let message = displayTiboMessage
        if demoCardViewed {
            let pending = announcements?.pending
            let time = pending?.announcedResetTime?.detail(timezone: displayTimezone) ?? (pending?.timeWithdrawn == true ? "原时间已撤回，新的时间待定" : "尚无明确时间")
            demoCardLabel?.stringValue = "已展示摘要：\(message?.title ?? "虚构完成确认")\n\(time)"
        } else {
            demoCardLabel?.stringValue = "当前版本尚未查看。点击下方按钮展示摘要并记为已读；下一次有效变化会再次亮红。"
        }
        let next: String
        switch scenario {
        case .announcement: next = "下一步：补充明确时间"
        case .timeAdded: next = "下一步：本人改期"
        case .rescheduled: next = "下一步：撤回时间"
        case .withdrawn: next = "下一步：完成确认"
        default: next = "演示步骤已结束"
        }
        demoNextButton?.title = next
        demoNextButton?.isEnabled = [.announcement, .timeAdded, .rescheduled, .withdrawn].contains(scenario)
        demoLogLabel?.stringValue = demoExecutionLog.suffix(7).joined(separator: "\n")
    }

    @objc private func showOnboarding() {
        if let onboardingWindow {
            updateOnboarding(); onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Codex 电量管家 · 首次使用与状态"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        let heading = NSTextField(labelWithString: "看见真实结果，再开始安排用量")
        heading.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(heading)
        for _ in 0..<5 {
            let label = NSTextField(wrappingLabelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.preferredMaxLayoutWidth = 484
            stack.addArrangedSubview(label); onboardingLabels.append(label)
        }
        let row = NSStackView(); row.spacing = 8
        for (title, selector) in [("查看菜单", #selector(showStatusMenu)), ("打开 Codex", #selector(openCodex)), ("重新检查", #selector(refresh)), ("查看说明", #selector(showHelp)), ("隔离演示", #selector(beginDemo))] {
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded; row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
        let close = NSButton(title: "知道了，回到菜单栏", target: self, action: #selector(dismissOnboarding))
        close.bezelStyle = .rounded; stack.addArrangedSubview(close)
        let content = window.contentView!
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        onboardingWindow = window
        updateOnboarding(); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateOnboarding() {
        guard onboardingLabels.count == 5 else { return }
        let live = demoScenario == nil
        onboardingLabels[0].stringValue = live ? (statusItem?.isVisible == true ? "✓ 程序已在菜单栏运行" : "程序正在运行，菜单栏图标等待显示") : "演示模式｜虚构示例 · 此处不验证真实账号"
        onboardingLabels[1].stringValue = !live ? "额度：当前为虚构示例" : (!isStale && snapshot?.windows.contains(where: { $0.remainingPercent != nil }) == true ? "✓ 已读到真实账号额度，更新时间 \(timeFormatter.string(from: snapshot!.fetchedAt))" : "额度未完成：\(lastError ?? (refreshInProgress ? "正在读取，请稍候" : "尚无有效账号读数，请打开 Codex 登录后重新检查"))")
        onboardingLabels[2].stringValue = !live ? "消息：\(demoScenario!.title)" : (livePreferences.bool(forKey: "realMessageViewed") ? "✓ 曾完成真实消息的查看 → 已读交互" : "真实消息：\(displayTiboMessage == nil ? "暂无可查看的真实新消息" : "请点开菜单栏查看摘要，自动记为已读")")
        onboardingLabels[3].stringValue = livePreferences.bool(forKey: "demoInteractionCompleted") ? "✓ 已完成隔离演示；与真实消息验证分别记录" : "隔离演示：可依次体验预告 → 补时间 → 改期 → 撤回 → 完成；每次切换后重新点开菜单查看。"
        onboardingLabels[4].stringValue = live ? (announcementDataStale ? "消息来源暂不可用不影响额度查询。无需等待真实公告即可使用；公共消息不会自动增加账号余额。" : "公开消息存在采集延迟，无法覆盖全部 X 评论。默认北京时间，可在显示设置中切换。") : "演示数据、已读与保留线完全隔离；退出演示即可恢复真实状态。演示不发外部请求。"
    }

    @objc private func dismissOnboarding() {
        livePreferences.set(true, forKey: "onboardingDismissed")
        onboardingWindow?.close()
    }

    @objc private func showHelp() {
        let url = Bundle.main.resourceURL?.appendingPathComponent("使用说明.md")
        if let url, FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    @objc private func showUninstall() {
        let alert = NSAlert()
        alert.messageText = "完整卸载 Codex 电量管家"
        alert.informativeText = "先关闭“登录时自动启动”，退出工具，再将“应用程序”中的 Codex 电量管家移到废纸篓。\n\n项目源码目录中的 uninstall.sh 可完整卸载，并先备份设置、已读与便签；支持恢复。"
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }

    @objc private func exportDemoImage() {
        guard let demoScenario else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Codex电量管家_演示示意.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DemoPreview.save(to: url, scenario: demoScenario, summary: menu.items.filter { $0.action == nil && $0.submenu == nil }.map(\.title)) }
        catch { let alert = NSAlert(); alert.messageText = "示意图保存失败，请换一个文件夹"; alert.runModal() }
    }

    static func selfTestInteraction() -> Int {
        let suite = "local.codex-battery.test." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(preferences: prefs)
        delegate.headlessTestMode = true
        let now = Date()
        let originalID = "2115000000000000001", latestID = "2116000000000000001"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm 'UTC'"
        func announcement(_ id: String, offset: TimeInterval, minutes: Int, type: String = "regular") -> TiboResetAnnouncement {
            let future = now.addingTimeInterval(Double(minutes) * 60)
            return TiboResetAnnouncement(id: id, text: "We will reset usage on \(formatter.string(from: future)).", postedAt: now.addingTimeInterval(offset),
                url: URL(string: "https://x.com/thsottiaux/status/\(id)")!, referenceResetAt: future, resetType: type)
        }
        func snapshot(_ pending: TiboResetAnnouncement?, _ latest: TiboResetAnnouncement? = nil) -> TiboResetSnapshot {
            TiboResetSnapshot(fetchedAt: Date(), sourceGeneratedAt: Date(), latest: latest, pending: pending,
                hasUnverifiedPending: false, hasExpiredPending: false, hasUnverifiedLatest: false)
        }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) { precondition(value()); checks += 1 }
        let original = announcement(originalID, offset: -600, minutes: 120)
        delegate.announcements = snapshot(original)
        let first = delegate.activeTiboAlert!
        check(delegate.readTiboRevisions.isEmpty)
        delegate.menuWillOpen(delegate.menu)
        check(delegate.activeTiboAlert == nil)
        check(delegate.readTiboIndicator.contains("已读"))
        check(delegate.menuViewedMessage?.readKey == first.readKey)
        check(delegate.menu.items.contains { $0.title.contains("✓ 已读") })
        delegate.menuDidClose(delegate.menu)
        check(delegate.menuViewedMessage == nil)
        let restarted = AppDelegate(preferences: prefs); restarted.headlessTestMode = true; restarted.announcements = snapshot(original)
        check(restarted.activeTiboAlert == nil)
        let changed = announcement(originalID, offset: -600, minutes: 180)
        delegate.announcements = snapshot(changed)
        check(delegate.activeTiboAlert != nil)
        delegate.saveReadKeys([first.readKey])
        check(delegate.activeTiboAlert != nil) // An old link opening cannot read a newer correction.
        delegate.menuWillOpen(delegate.menu)
        check(delegate.activeTiboAlert == nil)
        delegate.menuDidClose(delegate.menu)
        let completed = announcement(latestID, offset: -60, minutes: 240)
        delegate.announcements = snapshot(changed, completed)
        check(delegate.activeTiboAlert?.id == latestID)
        delegate.menuWillOpen(delegate.menu)
        check(delegate.menuViewedMessage?.id == latestID) // Keep the exact just-viewed card.
        check(delegate.menuViewedAnnouncement?.id == latestID)
        check(delegate.activeTiboAlert == nil)
        var withdrawn = original
        withdrawn.timeWithdrawn = true
        withdrawn.timeEvidence = TiboTimeEvidence(postID: "2117000000000000001", text: "The reset is postponed; the time is not confirmed.",
            postedAt: now.addingTimeInterval(-30), url: URL(string: "https://x.com/thsottiaux/status/2117000000000000001")!)
        delegate.applyAnnouncementUpdate(snapshot(withdrawn))
        let afterRestart = AppDelegate(preferences: prefs); afterRestart.headlessTestMode = true
        check(afterRestart.announcements == nil) // Cached facts alone never revive an upcoming event.
        afterRestart.applyAnnouncementUpdate(snapshot(original))
        check(afterRestart.announcements?.pending?.timeWithdrawn == true)
        check(afterRestart.announcements?.pending?.announcedResetTime == nil)
        afterRestart.applyAnnouncementUpdate(snapshot(nil))
        check(afterRestart.announcements?.pending == nil)
        return checks
    }

    static func selfTestNewFeatures() -> Int {
        let suite = "local.codex-battery.test." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(preferences: prefs)
        delegate.headlessTestMode = true
        let now = Date()
        let real = UsageSnapshot(primary: UsageWindow(usedPercent: 7, windowDurationMins: 10080,
            resetsAt: now.addingTimeInterval(86400).timeIntervalSince1970), secondary: nil, fetchedAt: now)
        delegate.snapshot = real
        prefs.set(20, forKey: "reservePercent.10080")
        prefs.set("真实便签", forKey: "taskNote")
        prefs.set(["real-read-version"], forKey: "readTiboRevisions")
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, line: UInt = #line) { precondition(condition(), "Feature check \(checks + 1), source line \(line)"); checks += 1 }
        delegate.refreshInProgress = true
        delegate.beginDemo()
        check(delegate.demoRequested && delegate.demoScenario == nil)
        delegate.refreshInProgress = false
        delegate.startDemoIfReady()
        check(delegate.demoScenario == .announcement)
        check(delegate.snapshot?.secondary?.displayPercent == 24)
        check(delegate.readTiboRevisions.isEmpty)
        check(delegate.preferences.string(forKey: "taskNote") == nil)
        check(PersonalPlan.reserve(for: real.primary!, preferences: delegate.preferences) == nil)
        check(delegate.activeTiboAlert != nil)
        for step in [DemoScenario.announcement, .timeAdded, .rescheduled, .withdrawn, .completed] {
            delegate.applyDemo(step)
            check(delegate.activeTiboAlert != nil)
            delegate.viewDemoMessage()
            check(delegate.activeTiboAlert == nil)
            check(delegate.demoCardViewed)
            delegate.menuDidClose(delegate.menu)
        }
        delegate.preferences.set(90, forKey: "reservePercent.10080")
        delegate.preferences.set("演示便签", forKey: "taskNote")
        check(prefs.string(forKey: "taskNote") == "真实便签")
        check(prefs.integer(forKey: "reservePercent.10080") == 20)
        delegate.applyDemo(.invalidComment)
        check(delegate.activeTiboAlert == nil && delegate.announcements?.hasUnverifiedPending == true)
        delegate.applyDemo(.unknown)
        check(delegate.isStale && delegate.snapshot == nil)
        delegate.applyDemo(.offline)
        check(delegate.isStale && delegate.announcementDataStale)
        delegate.refresh(); delegate.refreshAnnouncements()
        check(!delegate.refreshInProgress && !delegate.announcementRefreshInProgress)
        delegate.exitDemo()
        check(delegate.demoScenario == nil && delegate.demoPreferences == nil)
        check(delegate.snapshot == real)
        check(delegate.readTiboRevisions == ["real-read-version"])
        check(prefs.bool(forKey: "demoInteractionCompleted"))
        check(!prefs.bool(forKey: "realMessageViewed"))
        check(PersonalPlan.summary(for: real.primary!, preferences: prefs, stale: true).contains("待更新"))
        check(delegate.displayTimezone.identifier == "Asia/Shanghai")
        prefs.set(true, forKey: "useLocalTimezone")
        check(delegate.displayTimezone == .current)
        return checks
    }
}

@main
enum CodexBatteryApp {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--self-test-interaction") {
            _ = NSApplication.shared
            print("InteractionTests: \(AppDelegate.selfTestInteraction()) checks passed")
            return
        }
        if arguments.contains("--self-test-features") {
            _ = NSApplication.shared
            print("FeatureTests: \(AppDelegate.selfTestNewFeatures()) checks passed")
            return
        }
        if let i = arguments.firstIndex(of: "--render-demo-preview"), arguments.count > i + 1 {
            _ = NSApplication.shared
            do {
                try DemoPreview.save(to: URL(fileURLWithPath: arguments[i+1]), scenario: .timeAdded,
                    summary: ["账号周期：本周剩余 24% · 个人保留线 20%", "新预告 → 查看已读 → 本人补时间 → 改期 / 撤回 → 完成", "未知、断网与无效评论均有独立示例", "演示不查询外部来源；不修改真实余额与已读记录"])
            } catch { fputs("演示示意图保存失败\n", stderr); exit(1) }
            return
        }
        if let i = arguments.firstIndex(of: "--render-alert-preview"), arguments.count > i + 1 {
            _ = NSApplication.shared
            do { try AlertAppearance.savePreview(to: URL(fileURLWithPath: arguments[i+1])) }
            catch { fputs("提醒样式预览保存失败\n", stderr); exit(1) }
            return
        }
        if arguments.contains("--check-tibo") {
            do {
                let data = try TiboResetMonitor().fetch()
                var summary: [String: Any] = [
                    "source": "https://codex-resets.com/api/v1/status",
                    "hasVerifiedPending": data.pending != nil,
                    "hasUnverifiedPending": data.hasUnverifiedPending,
                    "hasExpiredPending": data.hasExpiredPending,
                    "checkedAt": ISO8601DateFormatter().string(from: data.fetchedAt)
                ]
                if let latest = data.latest { summary["latestVerifiedPost"] = latest.url.absoluteString }
                if let pending = data.pending { summary["pendingVerifiedPost"] = pending.url.absoluteString }
                if let pending = data.pending, let announced = pending.announcedResetTime {
                    summary["announcedResetAt"] = ISO8601DateFormatter().string(from: announced.date)
                    summary["announcedResetTime"] = announced.detail(timezone: TimeZone(identifier: "Asia/Shanghai")!)
                }
                let encoded = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: encoded, as: UTF8.self))
            } catch { fputs("公开预告暂时不可用\n", stderr); exit(1) }
            return
        }
        if arguments.contains("--check") {
            do {
                let snapshot = try UsageClient().fetch()
                var summary: [String: Any] = ["source": "Codex account/rateLimits/read", "period": snapshot.selectedLabel(selection: .limiting), "windowCount": snapshot.windows.count]
                if let percent = snapshot.chosenWindow(selection: .limiting)?.displayPercent { summary["remainingPercent"] = percent }
                if let reset = snapshot.chosenWindow(selection: .limiting)?.resetDate {
                    summary["resetAt"] = ISO8601DateFormatter().string(from: reset)
                    summary["resetLocalTime"] = ResetCountdown.detail(until: reset, timezone: TimeZone(identifier: "Asia/Shanghai")!)
                    summary["resetCountdown"] = ResetCountdown.compact(until: reset)
                }
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if let i = arguments.firstIndex(of: "--render-preview"), arguments.count > i + 1 {
            _ = NSApplication.shared
            do { try BatteryIcon.savePreview(to: URL(fileURLWithPath: arguments[i+1])) }
            catch { fputs("图标预览保存失败\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
