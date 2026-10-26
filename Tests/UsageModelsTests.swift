import Foundation

@main
enum UsageModelsTests {
    static func main() throws {
        let fixed = Date(timeIntervalSince1970: 1_790_000_000)
        let canonical = try parse("""
        {"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},
         "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":33,"windowDurationMins":10080,"resetsAt":1793517196},"secondary":null},
          "other-model":{"primary":{"usedPercent":100,"windowDurationMins":300}}}}
        """, at: fixed)
        expect(canonical.primary?.displayPercent == 67, "canonical Codex overrides legacy and other model")
        expect(canonical.chosenWindow(selection: .weekly)?.displayPercent == 67, "primary can be weekly")
        expect(canonical.chosenWindow(selection: .shortTerm) == nil, "no invented short-term window")
        expect(canonical.selectedLabel(selection: .limiting) == "本周", "label follows actual duration")
        expect(canonical.fetchedAt == fixed, "fetch time preserved")
        expect(canonical.primary?.resetDate == Date(timeIntervalSince1970: 1793517196), "server reset preserved")

        let twoWindows = try parse("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300},"secondary":{"usedPercent":76.2,"windowDurationMins":10080}}}
        """)
        expect(twoWindows.chosenWindow(selection: .shortTerm)?.displayPercent == 90, "short-term selection")
        expect(twoWindows.chosenWindow(selection: .weekly)?.displayPercent == 23, "remaining floors conservatively")
        expect(twoWindows.chosenWindow(selection: .limiting)?.displayPercent == 23, "most constrained allowance selected")
        expect(twoWindows.primary?.durationLabel == "5 小时", "actual short-term label")

        let emptyCanonical = try parse("""
        {"rateLimits":{"primary":{"usedPercent":0}},"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":null}}}
        """)
        expect(emptyCanonical.windows.isEmpty, "empty canonical never falls back to old allowance")
        expect(emptyCanonical.chosenWindow(selection: .limiting) == nil, "unknown is no percent")
        let nullCanonical = try parse("""
        {"rateLimits":{"primary":{"usedPercent":0}},"rateLimitsByLimitId":{"codex":null}}
        """)
        expect(nullCanonical.windows.isEmpty, "null canonical is authoritative unknown")

        let legacy = try parse("""
        {"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":100,"windowDurationMins":10080}}}
        """)
        expect(legacy.primary?.displayPercent == 100 && legacy.secondary?.displayPercent == 0, "real zero and full usage distinguished")
        expectThrows("other model cannot masquerade as Codex") {
            _ = try parse("""
            {"rateLimits":{"limitId":"special","primary":{"usedPercent":1}},"rateLimitsByLimitId":{"special":{"primary":{"usedPercent":1}}}}
            """)
        }
        expectThrows("no arbitrary map bucket fallback") {
            _ = try parse("""
            {"rateLimitsByLimitId":{"special":{"primary":{"usedPercent":1}}}}
            """)
        }
        expectThrows("malformed canonical rejected") { _ = try parse("{\"rateLimitsByLimitId\":{\"codex\":\"bad\"}}") }
        expectThrows("malformed window rejected") { _ = try parse("{\"rateLimits\":{\"primary\":[]}}") }

        let unknown = try parse("""
        {"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300},"secondary":{"usedPercent":true,"windowDurationMins":10080}}}
        """)
        expect(unknown.primary?.displayPercent == nil && unknown.secondary?.displayPercent == nil, "null and booleans never become a percentage")
        let clamped = try parse("""
        {"rateLimits":{"primary":{"usedPercent":-6},"secondary":{"usedPercent":106}}}
        """)
        expect(clamped.primary?.displayPercent == 100 && clamped.secondary?.displayPercent == 0, "bounds clamp")
        let nonfinite = try UsageSnapshot.parse(result: ["rateLimits": ["primary": ["usedPercent": Double.infinity, "windowDurationMins": -1, "resetsAt": Double.nan]]])
        expect(nonfinite.primary?.usedPercent == nil && nonfinite.primary?.windowDurationMins == nil && nonfinite.primary?.resetDate == nil, "nonfinite and invalid values discarded")
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(canonical))
        expect(decoded == canonical, "cache Codable round trip")
        expect(UsageWindow(usedPercent: 33.001, windowDurationMins: 300, resetsAt: nil).displayPercent == 66, "fractional remaining never rounds upward")
        expect(UsageWindow(usedPercent: nil, windowDurationMins: nil, resetsAt: nil).durationLabel == "当前周期", "missing duration uses neutral label")
        let partial = try parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":null,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":40,\"windowDurationMins\":10080}}}")
        expect(partial.chosenWindow(selection: .limiting)?.displayPercent == 60, "known allowance preferred to unknown")
        expect(UsageWindow(usedPercent: 0, windowDurationMins: 60, resetsAt: 0).resetDate == nil, "invalid epoch reset is unknown")
        let mixed = UsageSnapshot(primary: UsageWindow(usedPercent: 95, windowDurationMins: 300, resetsAt: fixed.addingTimeInterval(-1).timeIntervalSince1970), secondary: UsageWindow(usedPercent: 30, windowDurationMins: 10080, resetsAt: fixed.addingTimeInterval(3600).timeIntervalSince1970), fetchedAt: fixed)
        expect(mixed.chosenWindow(selection: .limiting, now: fixed)?.displayPercent == 70, "expired window cannot mask a valid current allowance")
        expect(mixed.chosenWindow(selection: .shortTerm, now: fixed)?.displayPercent == 5, "explicit expired window remains available to label awaiting confirmation")
        print("UsageModelsTests: 28 checks passed")
    }

    private static func parse(_ json: String, at date: Date = Date()) throws -> UsageSnapshot {
        let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return try UsageSnapshot.parse(result: result, fetchedAt: date)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAILED: \(label)") }
    }

    private static func expectThrows(_ label: String, body: () throws -> Void) {
        do { try body(); fatalError("FAILED (expected error): \(label)") }
        catch { }
    }
}
