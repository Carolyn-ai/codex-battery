import Foundation

@main
enum ResetAnnouncementTimeTests {
    static func main() {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError(label) }
            passed += 1
        }
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let posted = date("2026-10-26T03:00:00Z") // Oct25 evening in California.
        func parse(_ text: String, at: Date? = nil) -> ResetAnnouncementTime? {
            ResetAnnouncementTimeParser.parse(text: text, postedAt: at ?? posted)
        }
        let explicit = parse("Usage will reset Oct 27, 2026 at 10am PT")
        check(explicit?.date == date("2026-10-27T17:00:00Z"), "PT daylight time converts to UTC")
        check(explicit?.qualifier == .exact && explicit?.sourceTimeZone == "PT", "Exact qualifier and source preserved")
        check(explicit?.compact() == "10/28 01:00", "Beijing compact clock crosses day")
        check(explicit?.detail().contains("2026-10-28 01:00") == true && explicit?.detail().contains("UTC+08:00") == true, "Full local clock and offset")
        check(parse("Reset 2026-10-27 17:00 UTC")?.date == date("2026-10-27T17:00:00Z"), "ISO date with UTC")
        check(parse("Reset 2026-10-27T17:00Z")?.date == date("2026-10-27T17:00:00Z"), "ISO combined Z")
        check(parse("Reset 2026-10-27T17:00+08:00")?.date == date("2026-10-27T09:00:00Z"), "Explicit numeric offset")
        check(parse("Reset 2026-10-27 17:00 GMT+5:30")?.date == date("2026-10-27T11:30:00Z"), "Half-hour GMT offset")
        check(parse("Reset October 27 at 10:30am PDT")?.date == date("2026-10-27T17:30:00Z"), "Implicit year named date")
        let tomorrow = parse("Landing tomorrow before10am PT together with a small ship.")
        check(tomorrow?.date == date("2026-10-26T17:00:00Z"), "Tomorrow is relative to source timezone, not UTC date")
        check(tomorrow?.qualifier == .noLaterThan && tomorrow?.compact() == "10/27 01:00前", "Before remains a deadline")
        check(parse("Reset today at 5pm UTC")?.date == date("2026-10-26T17:00:00Z"), "Today uses source date")
        check(parse("Reset today at noon PT")?.date == date("2026-10-25T19:00:00Z"), "Explicitly past today can be returned without claiming completion")
        check(parse("Reset by 2026-10-27 17:00 UTC")?.qualifier == .noLaterThan, "By is a deadline")
        check(parse("Reset no later than Oct 27 at 10am PT")?.qualifier == .noLaterThan, "No-later-than retained")
        check(parse("Reset Jan 1 at 1am PT", at: date("2026-12-31T20:00:00Z"))?.date == date("2027-01-01T09:00:00Z"), "Close new-year rollover")
        check(parse("Reset January 1, 2027 at 10am PST")?.date == date("2027-01-01T18:00:00Z"), "PST valid in standard season")
        check(parse("Reset 2026-10-27 at 5:00pm UTC+0800")?.date == date("2026-10-27T09:00:00Z"), "Compact UTC numeric offset")
        check(parse("We will reset usage on January 16, 2027 at 10am UTC.")?.date == date("2027-01-16T10:00:00Z"), "Full explicit sentence")
        check(parse("We will reset usage tomorrow before 10am UTC.")?.qualifier == .noLaterThan, "Full relative deadline sentence")
        check(parse("By the way, usage resets Oct 27 at 10am PT.")?.qualifier == .exact, "Unrelated by does not change qualifier")
        check(parse("Reset 2026-10-27 00:00 UTC")?.date == date("2026-10-27T00:00:00Z"), "ISO midnight is unambiguous")
        check(parse("We will reset usage on October 25, 2026 at6pm UTC")?.date == date("2026-10-25T18:00:00Z"), "Direct reset clause with adjacent at clock")
        check(parse("Usage limits reset tomorrow at 10am PT")?.date == date("2026-10-26T17:00:00Z"), "Direct usage-limits predicate")
        check(parse("We will add a banked reset on October 27 at 10am PT")?.date == date("2026-10-27T17:00:00Z"), "Direct reset-credit predicate")

        let rejected = [
            "By midnight PST", "Day20 Rest and reset", "Reset tomorrow before10am", "Reset Oct 27 PT",
            "Reset in the next hour", "Reset in an hour", "Reset Oct 27 at 10am PST", "Reset Jan 1, 2027 at 10am PDT",
            "Reset Oct 27 at 10am PT or 11am PT", "Reset Oct 27 at 10am or 11am PT",
            "Reset Oct 27 or Oct 28 at 10am PT", "Reset 2026-02-30 17:00 UTC", "Reset 2026-10-27 24:00 UTC",
            "Reset 2026-10-27 17:60 UTC", "Reset Oct 27 at 13am PT", "Reset 2026-10-27 17:00:30 UTC",
            "We will not reset Oct 27 at 10am PT", "Reset cancelled Oct 27 at 10am PT", "Maybe reset Oct 27 at 10am PT",
            "Reset around Oct 27 at 10am PT", "Reset 2026-03-08 02:30 PT", "Reset 2026-11-01 01:30 PT",
            "Reset 2026-10-27 17:00 UTC+15:00", "Reset 2026-10-27 17:00 UTC+8:99",
            "Reset Oct 27 at 10am PT and UTC", "Reset Oct 27 at 10am. UTC clocks are nice",
            "Reset tomorrow and today at 10am PT", "Reset May 1 at 10am PT",
            "We will reset usage soon. The livestream is October 27 at 10am PT.",
            "We will reset usage soon, and the livestream is October 27 at 10am PT.",
            "The livestream is October 27 at 10am PT.", "Reset tomorrow by midnight PT",
            "Reset tomorrow not before 10am PT", "Reset no earlier than Oct 27 at 10am PT"
            , "We will reset usage soon, and the new model ships tomorrow at 10am PT."
            , "The model launched Oct 27. Usage will reset at 10am PT."
            , "We will reset usage soon. The new model ships October 27 at 10am PT."
            , "We will reset usage on October 27, and the new model ships at 10am PT."
            , "The new model ships tomorrow at 10am PT."
            , "Reset tomorrow. The new model ships at 10am PT."
        ]
        for text in rejected { check(parse(text) == nil, "Ambiguous/invalid input must fall back: \(text)") }
        check(parse("Reset 2026-03-08 03:30 PT")?.date == date("2026-03-08T10:30:00Z"), "Valid clock after spring gap")
        check(parse("Reset 2026-11-01 02:30 PT")?.date == date("2026-11-01T10:30:00Z"), "Valid clock after autumn fold")
        check(parse("Reset 2026-10-27 17:00 UTC https://example.com/10:00")?.date == date("2026-10-27T17:00:00Z"), "URLs cannot inject a second clock")
        check(ResetAnnouncementTimeParser.parse(text: "Reset Oct27 at 10am PT", postedAt: Date(timeIntervalSinceReferenceDate: .infinity)) == nil, "Nonfinite source time rejected")
        print("ResetAnnouncementTimeTests: \(passed) checks passed")
    }
}
