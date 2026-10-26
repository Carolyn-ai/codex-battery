import Foundation

@main
enum TiboAlertTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pendingID = "2115000000000000001"
        let latestID = "2114000000000000001"
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        func message(_ id: String = latestID, age: TimeInterval = 3_600, resetType: String = "regular", reference: Date? = nil, url: String? = nil) -> TiboResetAnnouncement {
            TiboResetAnnouncement(id: id, text: "fixture", postedAt: now.addingTimeInterval(-age), url: URL(string: url ?? "https://x.com/thsottiaux/status/\(id)")!, referenceResetAt: reference, resetType: resetType)
        }
        func snapshot(pending: TiboResetAnnouncement? = nil, latest: TiboResetAnnouncement? = nil, unverified: Bool = false, expired: Bool = false) -> TiboResetSnapshot {
            TiboResetSnapshot(fetchedAt: now, sourceGeneratedAt: now, latest: latest, pending: pending, hasUnverifiedPending: unverified, hasExpiredPending: expired, hasUnverifiedLatest: unverified)
        }
        func select(_ data: TiboResetSnapshot?, ack: Set<String> = [], read: Set<String> = [], stale: Bool = false) -> TiboAlert? {
            TiboAlert.select(from: data, acknowledgedIDs: ack, acknowledgedRevisions: read, now: now, sourceStale: stale)
        }

        expect(select(nil) == nil, "No snapshot is not a reset alert")
        expect(select(snapshot()) == nil, "No announcement has no alert")
        expect(select(snapshot(unverified: true)) == nil, "Unverified source candidates never become red alerts")
        expect(select(snapshot(expired: true)) == nil, "Expired source metadata alone never becomes a red alert")

        let pending = message(pendingID, age: 600, reference: now.addingTimeInterval(3_600))
        let pendingAlert = select(snapshot(pending: pending))
        expect(pendingAlert?.kind == .pendingReset && pendingAlert?.title == "Tibo重置预告", "Upcoming reset gets a distinct alert")
        expect(pendingAlert?.id == pendingID && pendingAlert?.sourceURL == pending.url && pendingAlert?.postedAt == pending.postedAt, "Alert preserves primary source identity")
        expect(select(snapshot(pending: message(pendingID, resetType: "banked")))?.kind == .pendingCredit, "Coupon preview stays distinct")
        expect(select(snapshot(pending: message(pendingID, resetType: "banked")))?.title == "Tibo重置券预告", "Coupon preview title")
        expect(select(snapshot(pending: pending), stale: true) == nil, "Stale discovery cannot assert a future preview")
        expect(select(snapshot(pending: pending), ack: [pendingID]) == nil, "Acknowledged preview stays dismissed")
        expect(select(snapshot(pending: pending), ack: [latestID])?.id == pendingID, "Old acknowledgement cannot dismiss a new ID")

        let latest = message()
        expect(select(snapshot(latest: latest))?.kind == .resetMessage, "Recent completion publication gets a message alert")
        expect(select(snapshot(latest: latest))?.title == "Tibo有重置消息", "Title does not claim personal account arrival")
        expect(select(snapshot(latest: message(resetType: "banked")))?.kind == .creditMessage, "Coupon publication stays distinct")
        expect(select(snapshot(latest: message(resetType: "banked")))?.title == "Tibo有重置券消息", "Coupon message title")
        expect(select(snapshot(latest: message(resetType: "unknown")))?.title == "Tibo有重置消息", "Unknown category remains a generic publication")
        expect(select(snapshot(latest: latest), stale: true)?.id == latestID, "Verified published fact can remain unread during an outage")
        expect(select(snapshot(latest: latest), ack: [latestID]) == nil, "Acknowledgement dismisses a completion")
        expect(select(snapshot(latest: latest), ack: [pendingID])?.id == latestID, "Different IDs are independently acknowledged")
        expect(select(snapshot(pending: pending, latest: latest))?.id == pendingID, "Preview takes priority over completion")
        expect(select(snapshot(pending: pending, latest: latest), ack: [pendingID]) == nil, "Dismissing preview must not reveal older completion")
        expect(select(snapshot(pending: pending, latest: latest), ack: [pendingID], stale: true) == nil, "Same suppression holds during source outage")
        let expiredAcknowledged = message(pendingID, age: 600, reference: now.addingTimeInterval(-1))
        expect(select(snapshot(pending: expiredAcknowledged, latest: latest), ack: [pendingID]) == nil, "Expiry of acknowledged preview does not reveal an older completion")
        let newer = message("2116000000000000001", age: 60)
        expect(select(snapshot(pending: pending, latest: newer), ack: [pendingID])?.id == newer.id, "A newer completion still appears after preview acknowledgement")
        expect(select(snapshot(pending: pending, latest: message(pendingID, age: 600)), ack: [pendingID]) == nil, "Same ID cannot reappear with a new classification")

        expect(select(snapshot(latest: message(age: 172_800))) != nil, "48-hour boundary is included")
        expect(select(snapshot(latest: message(age: 172_801))) == nil, "Older completed publications stop alerting")
        expect(select(snapshot(pending: message(pendingID, age: 86_400))) != nil, "Undated preview includes 24-hour boundary")
        expect(select(snapshot(pending: message(pendingID, age: 86_401))) == nil, "Undated old previews expire")
        expect(select(snapshot(pending: message(pendingID, age: 90_000, reference: now.addingTimeInterval(60)))) != nil, "Dated valid preview may last more than 24 hours")
        expect(select(snapshot(pending: message(pendingID, age: 172_801, reference: now.addingTimeInterval(60)))) == nil, "All previews still have a 48-hour age cap")
        expect(select(snapshot(pending: message(pendingID, reference: now))) == nil, "Elapsed deadline is not an upcoming alert")
        expect(select(snapshot(pending: message(pendingID, reference: now.addingTimeInterval(-1)))) == nil, "Past reference never means reset happened")
        expect(select(snapshot(latest: message(age: -300))) != nil, "Five minutes of clock skew allowed")
        expect(select(snapshot(latest: message(age: -301))) == nil, "Future publication outside clock skew rejected")
        expect(select(snapshot(pending: message(pendingID, reference: Date(timeIntervalSinceReferenceDate: .infinity)))) == nil, "Malformed reference date rejected")
        expect(select(snapshot(latest: message(age: .infinity))) == nil, "Malformed publication date rejected")

        let unsafeURLs = [
            "http://x.com/thsottiaux/status/\(latestID)",
            "https://evil.example/thsottiaux/status/\(latestID)",
            "https://x.com/other/status/\(latestID)",
            "https://x.com/thsottiaux/status/9999999999999999999",
            "https://x.com/thsottiaux/status/\(latestID)?next=evil",
            "https://x.com/thsottiaux/status/\(latestID)#fragment",
            "https://user@x.com/thsottiaux/status/\(latestID)",
            "https://x.com:444/thsottiaux/status/\(latestID)"
        ]
        for url in unsafeURLs { expect(select(snapshot(latest: message(url: url))) == nil, "Reject noncanonical source URL: \(url)") }
        expect(select(snapshot(latest: message("not-numeric-id"))) == nil, "Non-numeric identity is rejected")

        let earlierSnapshot = snapshot(pending: pending, latest: latest)
        let failedVerification = TiboResetSnapshot(fetchedAt: now.addingTimeInterval(60), sourceGeneratedAt: now.addingTimeInterval(30), latest: nil, pending: nil, hasUnverifiedPending: true, hasExpiredPending: true, hasUnverifiedLatest: true,
            supplementalScannedAt: now.addingTimeInterval(40), supplementalDiscoveryAvailable: true)
        let preserved = TiboAlert.preservingVerifiedLatest(in: failedVerification, previous: earlierSnapshot)
        expect(preserved.latest == latest, "Verification failure preserves previous verified publication")
        expect(preserved.latest?.postedAt == latest.postedAt, "Preservation never renews original publication age")
        expect(preserved.pending == nil, "Previous pending is never restored from cache")
        expect(preserved.fetchedAt == failedVerification.fetchedAt && preserved.sourceGeneratedAt == failedVerification.sourceGeneratedAt, "Current source freshness retained")
        expect(preserved.hasUnverifiedPending && preserved.hasExpiredPending && preserved.hasUnverifiedLatest, "Incoming verification flags retained exactly")
        expect(preserved.supplementalScannedAt == failedVerification.supplementalScannedAt && preserved.supplementalDiscoveryAvailable,
            "Current follow-up scan metadata is preserved with a retained publication")
        let emptyAfterScan = TiboAlert.preservingVerifiedLatest(in: snapshot(), previous: preserved)
        expect(emptyAfterScan.supplementalScannedAt == nil && !emptyAfterScan.supplementalDiscoveryAvailable,
            "Previous successful follow-up scan cannot masquerade as the current scan")
        expect(select(preserved, stale: true)?.id == latestID, "Preserved verified fact remains available during a source outage")
        expect(TiboAlert.preservingVerifiedLatest(in: snapshot(), previous: earlierSnapshot).latest == latest, "Empty current result preserves verified publication")
        expect(TiboAlert.preservingVerifiedLatest(in: snapshot(latest: newer), previous: earlierSnapshot).latest == newer, "Newer incoming publication wins")
        expect(TiboAlert.preservingVerifiedLatest(in: snapshot(latest: latest), previous: snapshot(latest: newer)).latest == newer, "Older incoming publication cannot replace newer verified one")
        expect(TiboAlert.preservingVerifiedLatest(in: snapshot(latest: newer), previous: nil).latest == newer, "Incoming publication accepted without previous cache")
        expect(TiboAlert.preservingVerifiedLatest(in: snapshot(), previous: nil).latest == nil, "No evidence remains empty")
        let newPending = message("2117000000000000001", age: 60, reference: now.addingTimeInterval(7_200))
        expect(TiboAlert.preservingVerifiedLatest(in: snapshot(pending: newPending), previous: earlierSnapshot).pending == newPending, "Only incoming pending is retained")
        let expiredLatest = message(age: 172_801)
        let preservedExpired = TiboAlert.preservingVerifiedLatest(in: snapshot(), previous: snapshot(latest: expiredLatest))
        expect(preservedExpired.latest?.postedAt == expiredLatest.postedAt && select(preservedExpired) == nil, "Preservation cannot extend the 48-hour alert lifetime")
        let explicitTime = TiboResetAnnouncement(id: pendingID, text: "We will reset usage on January 16, 2027 at 10am UTC.",
            postedAt: now.addingTimeInterval(-600), url: pending.url, referenceResetAt: nil, resetType: "regular")
        let explicitAlert = select(snapshot(pending: explicitTime))
        expect(explicitAlert?.title == "Tibo 01/16 18:00重置", "Verified explicit time appears in Beijing time directly in alert")
        let deadline = TiboResetAnnouncement(id: pendingID, text: "We will reset usage tomorrow before 10am UTC.",
            postedAt: now.addingTimeInterval(-600), url: pending.url, referenceResetAt: nil, resetType: "regular")
        expect(select(snapshot(pending: deadline))?.title == "Tibo 01/16 18:00前重置", "Deadline qualifier is preserved in visible title")
        let vague = TiboResetAnnouncement(id: pendingID, text: "Usage reset landing in the next hour or so.",
            postedAt: now.addingTimeInterval(-600), url: pending.url, referenceResetAt: now.addingTimeInterval(3600), resetType: "regular")
        expect(select(snapshot(pending: vague))?.title == "Tibo重置预告", "Community reference does not become an exact title time")
        expect(select(snapshot(latest: explicitTime))?.title == "Tibo有重置消息", "Completed publication never displays a future reset time")
        let conflictingReference = TiboResetAnnouncement(id: pendingID, text: explicitTime.text, postedAt: explicitTime.postedAt,
            url: pending.url, referenceResetAt: now.addingTimeInterval(-60), resetType: "regular")
        expect(select(snapshot(pending: conflictingReference))?.title == explicitAlert?.title, "Verified original time takes precedence over elapsed community reference")

        let latestAlert = select(snapshot(latest: latest))!
        expect(latestAlert.readKey == select(snapshot(latest: latest))?.readKey, "Repeated fetches retain a stable read revision")
        let refreshedSnapshot = TiboResetSnapshot(fetchedAt: now.addingTimeInterval(300), sourceGeneratedAt: now.addingTimeInterval(299),
            latest: latest, pending: nil, hasUnverifiedPending: false, hasExpiredPending: false, hasUnverifiedLatest: false)
        expect(select(refreshedSnapshot)?.readKey == latestAlert.readKey, "Source timestamps never change message revision")
        expect(select(snapshot(latest: latest), read: [latestAlert.readKey]) == nil, "Viewing a message dismisses its exact revision")
        expect(select(snapshot(latest: latest), read: [latestAlert.readKey], stale: true) == nil, "Viewed publication does not return during an outage")
        expect(TiboAlert.latestDisplay(from: snapshot(latest: latest), now: now)?.readKey == latestAlert.readKey, "Read message stays available as a neutral summary")
        expect(TiboAlert.latestDisplay(from: snapshot(pending: pending), now: now)?.id == pendingID, "Neutral display prioritizes current pending announcement")
        expect(TiboAlert.latestDisplay(from: snapshot(pending: pending, latest: latest), now: now, sourceStale: true)?.id == latestID, "Neutral display does not assert stale future information")

        let pendingKey = pendingAlert!.readKey
        expect(select(snapshot(pending: pending), read: [pendingKey]) == nil, "Viewed pending revision stays dismissed")
        expect(select(snapshot(pending: pending, latest: latest), read: [pendingKey]) == nil, "Read pending revision does not reveal an older completion")
        expect(select(snapshot(pending: pending, latest: latest), read: [pendingKey], stale: true) == nil, "Pending revision suppression holds when source becomes stale")
        expect(select(snapshot(pending: expiredAcknowledged, latest: latest), read: [pendingKey]) == nil, "Expired read pending revision does not reveal older completion")
        expect(select(snapshot(pending: pending, latest: newer), read: [pendingKey])?.id == newer.id, "Later completion remains a meaningful unread update")
        expect(select(snapshot(pending: explicitTime), read: [pendingKey])?.id == pendingID, "Supplemented original time re-alerts the same post ID")
        expect(explicitAlert!.readKey != pendingKey, "Known time has a different semantic revision from unknown time")
        expect(select(snapshot(pending: explicitTime), read: [explicitAlert!.readKey]) == nil, "Supplemented time clears after viewing")

        let revisedTime = TiboResetAnnouncement(id: pendingID, text: "We will reset usage on January 16, 2027 at 11am UTC.",
            postedAt: explicitTime.postedAt, url: pending.url, referenceResetAt: nil, resetType: "regular")
        expect(select(snapshot(pending: revisedTime), read: [explicitAlert!.readKey])?.title == "Tibo 01/16 19:00重置", "Changed reset time re-alerts a previously read original post")
        let deadlineAlert = select(snapshot(pending: deadline))!
        expect(deadlineAlert.readKey != explicitAlert!.readKey, "Exact instant and no-later-than deadline are different revisions")
        let changedReference = message(pendingID, age: 600, reference: now.addingTimeInterval(7_200))
        expect(select(snapshot(pending: changedReference))?.readKey == pendingKey, "Unverified community time changes cannot invent a meaningful revision")

        let samePostCompletion = message(pendingID, age: 600)
        let changedStage = select(snapshot(pending: pending, latest: samePostCompletion), read: [pendingKey])
        expect(changedStage?.kind == .resetMessage, "Completion stage can re-alert the same ID under revision-based reading")
        expect(changedStage?.readKey != pendingKey, "Completion stage has a distinct revision")
        expect(select(snapshot(latest: newer), read: [latestAlert.readKey])?.id == newer.id, "New post ID is unread even after previous revision was read")

        let readKeys = TiboAlert.revisionKeysToAcknowledge(alert: pendingAlert!, snapshot: snapshot(pending: pending, latest: latest), now: now)
        expect(readKeys == [pendingKey, latestAlert.readKey], "Viewing current preview also dismisses already-known older completion")
        expect(select(snapshot(latest: latest), read: readKeys) == nil, "Older completion stays read when preview disappears upstream")
        let newerKeys = TiboAlert.revisionKeysToAcknowledge(alert: pendingAlert!, snapshot: snapshot(pending: pending, latest: newer), now: now)
        expect(newerKeys == [pendingKey], "Viewing a preview cannot acknowledge a newer completion")
        let noSnapshotKeys = TiboAlert.revisionKeysToAcknowledge(alert: latestAlert, snapshot: nil, now: now)
        expect(noSnapshotKeys == [latestAlert.readKey], "Visible message can be acknowledged without a current snapshot")
        let sameIDStageKeys = TiboAlert.revisionKeysToAcknowledge(alert: pendingAlert!, snapshot: snapshot(pending: pending, latest: samePostCompletion), now: now)
        expect(sameIDStageKeys == [pendingKey], "Viewing preview cannot pre-read a different stage on the same post")
        let invalidOlder = message(url: "https://evil.example/thsottiaux/status/\(latestID)")
        expect(TiboAlert.revisionKeysToAcknowledge(alert: pendingAlert!, snapshot: snapshot(pending: pending, latest: invalidOlder), now: now) == [pendingKey], "Invalid older source cannot become an acknowledged revision")

        let manualRevisionOne = TiboAlert(id: pendingID, kind: .pendingReset, title: "same compact title", sourceURL: pending.url,
            postedAt: pending.postedAt, revisionDetails: "time:1800000000.0|exact")
        let manualRevisionTwo = TiboAlert(id: pendingID, kind: .pendingReset, title: "same compact title", sourceURL: pending.url,
            postedAt: pending.postedAt, revisionDetails: "time:1831536000.0|exact")
        expect(manualRevisionOne.readKey != manualRevisionTwo.readKey, "Full timestamp preserves meaningful year changes even if compact title is identical")
        let preciseKeys = TiboAlert.revisionKeysToAcknowledge(alert: explicitAlert!, snapshot: snapshot(pending: explicitTime), now: now)
        expect(preciseKeys.contains(explicitAlert!.readKey) && preciseKeys.contains(pendingKey), "Viewing a timed preview also reads its less-specific baseline")
        expect(select(snapshot(pending: pending), read: preciseKeys) == nil, "Temporary loss of supplemental time is not a new unread change")
        expect(select(snapshot(pending: revisedTime), read: preciseKeys)?.title == "Tibo 01/16 19:00重置", "A genuinely changed time remains unread after a precise message was viewed")
        expect(select(snapshot(latest: samePostCompletion), read: preciseKeys)?.kind == .resetMessage, "Reading a time baseline does not pre-read completion")
        let spaced = TiboAlert(id: latestID, kind: .resetMessage, title: " Tibo  有重置消息\n", sourceURL: latest.url, postedAt: latest.postedAt)
        let unspaced = TiboAlert(id: latestID, kind: .resetMessage, title: "Tibo 有重置消息", sourceURL: latest.url, postedAt: latest.postedAt)
        expect(spaced.readKey == unspaced.readKey, "Fallback title revisions normalize whitespace only")

        let withdrawalID = "2118000000000000001"
        let withdrawalEvidence = TiboTimeEvidence(postID: withdrawalID, text: "Reset timing is now TBD.", postedAt: now.addingTimeInterval(-300),
            url: URL(string: "https://x.com/thsottiaux/status/\(withdrawalID)")!)
        var withdrawn = conflictingReference
        withdrawn.timeWithdrawn = true
        withdrawn.timeEvidence = withdrawalEvidence
        let withdrawnAlert = select(snapshot(pending: withdrawn), read: preciseKeys)
        expect(withdrawnAlert?.title == "Tibo重置时间待定（有更新）", "Official withdrawal is a new visible update after timed preview was viewed")
        expect(withdrawnAlert?.readKey.contains("time-withdrawn|\(withdrawalID)") == true, "Withdrawal revision binds its verified source post")
        expect(withdrawn.announcedResetTime == nil, "Withdrawal cannot retain an original exact time")
        let withdrawalKeys = TiboAlert.revisionKeysToAcknowledge(alert: withdrawnAlert!, snapshot: snapshot(pending: withdrawn), now: now)
        expect(select(snapshot(pending: withdrawn), read: withdrawalKeys) == nil, "Viewed withdrawal stays read")
        expect(select(snapshot(pending: withdrawn), stale: true) == nil, "Stale source cannot claim a fresh pending withdrawal")

        let restorationID = "2119000000000000001"
        let restorationEvidence = TiboTimeEvidence(postID: restorationID, text: explicitTime.text, postedAt: now.addingTimeInterval(-60),
            url: URL(string: "https://x.com/thsottiaux/status/\(restorationID)")!)
        var restored = explicitTime
        restored.timeEvidence = restorationEvidence
        let restorationAlert = select(snapshot(pending: restored), read: preciseKeys.union(withdrawalKeys))
        expect(restorationAlert?.title == explicitAlert?.title, "Official restoration can keep the previously announced clock")
        expect(restorationAlert?.readKey != explicitAlert?.readKey, "Restoration binds its new source even when its clock matches a read version")
        expect(restorationAlert?.readKey.contains("evidence:\(restorationID)") == true, "Known supplemental time revision includes evidence post ID")
        let restorationKeys = TiboAlert.revisionKeysToAcknowledge(alert: restorationAlert!, snapshot: snapshot(pending: restored), now: now)
        expect(select(snapshot(pending: restored), read: restorationKeys) == nil, "Viewed restored clock stays read on repeated fetch")
        var withdrawnCredit = TiboResetAnnouncement(id: withdrawn.id, text: withdrawn.text, postedAt: withdrawn.postedAt, url: withdrawn.url,
            referenceResetAt: withdrawn.referenceResetAt, resetType: "banked")
        withdrawnCredit.timeEvidence = withdrawalEvidence
        withdrawnCredit.timeWithdrawn = true
        expect(select(snapshot(pending: withdrawnCredit))?.title == "Tibo重置券时间待定（有更新）", "Coupon withdrawal wording stays distinct")

        let lostSupplement = TiboAlert.preservingVerifiedLatest(in: snapshot(pending: explicitTime), previous: snapshot(pending: withdrawn))
        expect(lostSupplement.pending?.timeWithdrawn == true && lostSupplement.pending?.announcedResetTime == nil,
            "Temporary supplement failure cannot restore a withdrawn original clock")
        expect(lostSupplement.pending?.timeEvidence?.postID == withdrawalID, "Previous verified withdrawal evidence is retained for the same pending base")
        expect(lostSupplement.pending?.relatedPosts.contains(where: { $0.postID == withdrawalID }) == true,
            "Retained withdrawal keeps a visible provenance link")
        expect(select(lostSupplement)?.readKey == withdrawnAlert?.readKey, "Preserving known withdrawal does not invent a new revision")
        let laterRestoration = TiboAlert.preservingVerifiedLatest(in: snapshot(pending: restored), previous: snapshot(pending: withdrawn))
        expect(laterRestoration.pending?.timeWithdrawn == false && laterRestoration.pending?.timeEvidence?.postID == restorationID,
            "A newer verified restoration replaces preserved withdrawal")
        expect(laterRestoration.pending?.announcedResetTime?.date == explicitTime.announcedResetTime?.date,
            "A later restoration may legitimately return to the old clock")
        let missingPending = TiboAlert.preservingVerifiedLatest(in: snapshot(), previous: snapshot(pending: withdrawn))
        expect(missingPending.pending == nil, "Supplement preservation never restores a pending entry removed by the current source")
        let otherPending = TiboAlert.preservingVerifiedLatest(in: snapshot(pending: newPending), previous: snapshot(pending: withdrawn))
        expect(otherPending.pending?.id == newPending.id && otherPending.pending?.timeEvidence == nil,
            "Supplement facts cannot transfer to a different pending base")
        let olderSupplement = TiboAlert.preservingVerifiedLatest(in: snapshot(pending: withdrawn), previous: snapshot(pending: restored))
        expect(olderSupplement.pending?.timeEvidence?.postID == restorationID && olderSupplement.pending?.timeWithdrawn == false,
            "An older current supplement cannot overwrite a newer verified fact")
        print("TiboAlertTests: \(checks) checks passed")
    }
}
