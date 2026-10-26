import Foundation

@main
enum TiboResetMonitorTests {
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T16:00:00Z")!
        let latestID = "2114237083652882932"
        let pendingID = "2114200291319124163"
        let parentID = "2114200152701575656"
        var count = 0
        func expect(_ value: @autoclosure () -> Bool, _ description: String) {
            guard value() else { fatalError(description) }; count += 1
        }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func candidate(_ id: String, text: String, pending: Bool = false) -> [String: Any] {
            var value: [String: Any] = [
                "id": id, "reset_type": "regular", "announced_at": "2026-10-25T06:06:16.000Z", "text": text,
                "source": ["type": "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/\(id)"]
            ]
            if pending { value["status"] = "scheduled"; value["scheduled_for"] = "2026-10-25T17:00:00.000Z" }
            return value
        }
        func tweet(_ id: String, text: String, author: String = "thsottiaux", parent: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["id_str": id, "text": text, "created_at": "2026-10-25T06:06:16.000Z", "user": ["screen_name": author]]
            if let parent { value["in_reply_to_status_id_str"] = parent }
            return value
        }
        func feed(latest: Any = NSNull(), pending: Any = NSNull(), watch: Any = NSNull(), generated: String = "2026-10-25T15:59:00.000Z") -> [String: Any] {
            ["data": ["latest_reset": latest, "scheduled_reset": pending, "active_watch": watch], "meta": ["generated_at": generated]]
        }
        func run(_ feed: [String: Any], tweets: [String: [String: Any]], supplemental: [String: Any]? = nil, additional: [String] = []) throws -> TiboResetSnapshot {
            let feedData = try json(feed)
            let supplementalData = try supplemental.map(json)
            let tweetData = try tweets.mapValues(json)
            return try TiboResetMonitor(fetchData: { url in
                if url.host == "codex-resets.com" { return feedData }
                if url.host == "will-codex-reset.com" {
                    guard let supplementalData else { throw TiboResetMonitorError.unavailable }
                    return supplementalData
                }
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
                guard let id, let data = tweetData[id] else { throw TiboResetMonitorError.unavailable }
                return data
            }, now: { now }, additionalPostIDs: additional).fetch()
        }
        let completed = "It is all propagated. Enjoy some mad codexing tomorrow."
        let latest = candidate(latestID, text: completed + " https://t.co/first https://t.co/quote")
        let actual = tweet(latestID, text: completed + " https://t.co/first")
        let verified = try run(feed(latest: latest), tweets: [latestID: actual])
        expect(verified.latest?.id == latestID, "Official author and numeric post ID match")
        expect(verified.latest?.text == completed, "Display primary text without URL noise")
        expect(verified.latest?.url.absoluteString == "https://x.com/thsottiaux/status/\(latestID)", "Canonical source link")
        expect(verified.latest?.referenceResetAt == nil && verified.pending == nil, "Completed reset does not invent next time")
        expect(!verified.hasUnverifiedLatest && !verified.hasUnverifiedPending, "Known verification state")
        expect(verified.fetchedAt == now && verified.sourceGeneratedAt != nil, "Preserve check time and community generation time")

        let pending = candidate(pendingID, text: "By midnight PST", pending: true)
        let pendingTweet = tweet(pendingID, text: "By midnight PST", parent: parentID)
        let parent = tweet(parentID, text: "Day 20/ Rest and reset")
        let scheduled = try run(feed(pending: pending), tweets: [pendingID: pendingTweet, parentID: parent])
        expect(scheduled.pending?.text == "By midnight PST", "Deadline-only reply verifies reset parent")
        expect(scheduled.pending?.referenceResetAt == ISO8601DateFormatter().date(from: "2026-10-25T17:00:00Z"), "Community time is a separate reference field")
        expect(scheduled.pending != nil && scheduled.latest == nil, "Future reference remains separately marked")
        expect(scheduled.pending?.resetType == "unknown", "Unspecified reset kind is not invented from metadata")

        var elapsedPending = pending
        elapsedPending["scheduled_for"] = "2026-10-25T07:00:00.000Z"
        let elapsed = try run(feed(pending: elapsedPending), tweets: [pendingID: pendingTweet, parentID: parent])
        expect(elapsed.pending == nil && elapsed.latest == nil, "Passed community deadline never implies completion")
        expect(elapsed.hasExpiredPending && !elapsed.hasUnverifiedPending, "Expired reference does not keep an active alert")

        let exactText = "We will reset usage on October 25, 2026 at 6pm UTC."
        var originalTimeCandidate = candidate(pendingID, text: exactText, pending: true)
        originalTimeCandidate["scheduled_for"] = "2026-10-25T07:00:00.000Z"
        let originalTime = try run(feed(pending: originalTimeCandidate), tweets: [pendingID: tweet(pendingID, text: exactText)])
        expect(originalTime.pending?.announcedResetTime?.date == ISO8601DateFormatter().date(from: "2026-10-25T18:00:00Z"), "Verified original deadline overrides community interpretation")
        expect(!originalTime.hasExpiredPending && originalTime.pending != nil, "Elapsed community time cannot discard a future explicit original deadline")
        var laterCommunity = originalTimeCandidate
        laterCommunity["text"] = "We will reset usage on October 25, 2026 at 3pm UTC."
        laterCommunity["scheduled_for"] = "2026-10-25T18:00:00.000Z"
        let originalElapsed = try run(feed(pending: laterCommunity), tweets: [pendingID: tweet(pendingID, text: laterCommunity["text"] as! String)])
        expect(originalElapsed.pending == nil && originalElapsed.hasExpiredPending, "Passed original deadline expires despite later community estimate")

        var laterCompletion = actual
        laterCompletion["created_at"] = "2026-10-25T08:00:00.000Z"
        laterCompletion["quoted_tweet"] = pendingTweet
        let superseded = try run(feed(latest: latest, pending: pending), tweets: [latestID: laterCompletion, pendingID: pendingTweet, parentID: parent])
        expect(superseded.pending == nil && superseded.latest != nil, "Later linked completion suppresses older pending")
        expect(!superseded.hasUnverifiedPending && !superseded.hasExpiredPending, "Superseded announcement is not unresolved")

        let noResetText = "We will not reset Codex today."
        let noReset = try run(feed(pending: candidate(pendingID, text: noResetText, pending: true)), tweets: [pendingID: tweet(pendingID, text: noResetText)])
        expect(noReset.pending == nil && noReset.hasUnverifiedPending, "Negated reset wording is not a promise")
        let negatedParent = try run(feed(pending: pending), tweets: [pendingID: pendingTweet, parentID: tweet(parentID, text: noResetText)])
        expect(negatedParent.pending == nil, "Negated parent context is not a reset promise")

        let bankedText = "We have added a banked reset to every Codex account."
        let banked = try run(feed(latest: candidate(latestID, text: bankedText)), tweets: [latestID: tweet(latestID, text: bankedText)])
        expect(banked.latest?.resetType == "banked", "Banked kind derives from primary body even if metadata says regular")
        let pendingBankedText = "Tomorrow we will add a banked reset to every account."
        let latestRegularText = "We have reset the usage limits for everyone."
        var laterRegularTweet = tweet(latestID, text: latestRegularText)
        laterRegularTweet["created_at"] = "2026-10-25T08:00:00Z"
        let separateKinds = try run(feed(latest: candidate(latestID, text: latestRegularText), pending: candidate(pendingID, text: pendingBankedText, pending: true)), tweets: [latestID: laterRegularTweet, pendingID: tweet(pendingID, text: pendingBankedText)])
        expect(separateKinds.pending?.resetType == "banked" && separateKinds.latest?.resetType == "regular", "A later regular completion does not suppress an unrelated banked announcement")

        var oldUndated = pending
        oldUndated.removeValue(forKey: "scheduled_for")
        oldUndated["announced_at"] = "2026-10-23T06:00:00Z"
        var oldTweet = pendingTweet
        oldTweet["created_at"] = "2026-10-23T06:00:00Z"
        let oldPending = try run(feed(pending: oldUndated), tweets: [pendingID: oldTweet, parentID: parent])
        expect(oldPending.pending == nil && oldPending.hasExpiredPending && !oldPending.hasUnverifiedPending, "Undated old announcements expire without implying completion")

        let unrelated = try run(feed(pending: pending), tweets: [pendingID: pendingTweet, parentID: tweet(parentID, text: "See you tomorrow")])
        expect(unrelated.pending == nil && unrelated.hasUnverifiedPending, "Unrelated deadline must not be called a reset")
        let unavailable = try run(feed(pending: pending), tweets: [:])
        expect(unavailable.pending == nil && unavailable.hasUnverifiedPending, "Unavailable X never becomes verified")
        let mismatchAuthor = try run(feed(latest: latest), tweets: [latestID: tweet(latestID, text: completed, author: "imposter")])
        expect(mismatchAuthor.latest == nil && mismatchAuthor.hasUnverifiedLatest, "Reject different author")
        let mismatchID = try run(feed(latest: latest), tweets: [latestID: tweet(parentID, text: completed)])
        expect(mismatchID.latest == nil, "Reject different official post ID")
        let mismatchBody = try run(feed(latest: latest), tweets: [latestID: tweet(latestID, text: "We have reset usage limits for Codex")])
        expect(mismatchBody.latest == nil, "Community body must match official primary body")

        var malicious = latest
        malicious["source"] = ["type": "x_post", "author": "thsottiaux", "url": "https://evil.example/thsottiaux/status/\(latestID)"]
        let blocked = try run(feed(latest: malicious), tweets: [latestID: actual])
        expect(blocked.latest == nil && blocked.hasUnverifiedLatest, "Reject arbitrary discovery host")
        malicious["id"] = "observed-123"
        let observed = try run(feed(latest: malicious), tweets: [:])
        expect(observed.latest == nil, "Observed synthetic IDs are not primary X evidence")

        var completedAsPending = candidate(latestID, text: completed, pending: true)
        completedAsPending["scheduled_for"] = "2026-10-26T07:00:00Z"
        let invalidPending = try run(feed(pending: completedAsPending), tweets: [latestID: actual])
        expect(invalidPending.pending == nil && invalidPending.hasUnverifiedPending, "Completed wording is not an upcoming promise")

        let watch = try run(feed(watch: ["level": "strong", "reset_chance_percent": 99, "forecast_window": "next hour"]), tweets: [:])
        expect(watch.pending == nil && !watch.hasUnverifiedPending, "AI watch prediction never becomes an announcement")
        let old = try run(feed(generated: "2026-10-20T00:00:00Z"), tweets: [:])
        expect(old.sourceGeneratedAt! < now.addingTimeInterval(-86_400), "Stale feed age remains available for UI to disclose")
        do {
            _ = try run(feed(generated: "2026-10-26T00:00:00Z"), tweets: [:])
            fatalError("Future feed timestamp must fail")
        } catch TiboResetMonitorError.unsupportedData { count += 1 }
        do {
            _ = try TiboResetMonitor(fetchData: { _ in Data(repeating: 0x20, count: 1_048_577) }, now: { now }).fetch()
            fatalError("Oversize discovery response must fail")
        } catch TiboResetMonitorError.unsupportedData { count += 1 }
        let rootID = "2115000000000000001"
        let replyID = "2115000000000000002"
        let correctionID = "2115000000000000003"
        let rootText = "We will reset usage limits."
        let timeText = "Tomorrow before 10am UTC"
        let correctionText = "Tomorrow before 11am UTC"
        let rootCandidate = candidate(rootID, text: rootText, pending: true)
        var rootTweet = tweet(rootID, text: rootText)
        rootTweet["created_at"] = "2026-10-25T06:00:00Z"
        var timeReply = tweet(replyID, text: timeText, parent: rootID)
        timeReply["created_at"] = "2026-10-25T07:00:00Z"
        var correctedReply = tweet(correctionID, text: correctionText, parent: replyID)
        correctedReply["created_at"] = "2026-10-25T08:00:00Z"
        func supplemental(_ posts: [[String: Any]], scanned: String = "2026-10-25T12:00:00Z") -> [String: Any] {
            ["schema_version": 1, "updated_at": "2026-10-25T16:00:00Z", "source": ["account": "thsottiaux", "last_success_at": scanned], "posts": posts]
        }
        func publicPost(_ id: String, _ text: String, parent: String? = nil, at: String = "2026-10-25T07:00:00Z") -> [String: Any] {
            var value: [String: Any] = ["id": id, "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/\(id)", "text": text, "at": at]
            if let parent { value["references"] = [["id": parent, "type": "replied_to"]] }
            return value
        }
        let discovered = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, replyID: timeReply],
            supplemental: supplemental([publicPost(replyID, timeText, parent: rootID)]))
        expect(discovered.pending?.id == rootID, "A time reply refines the original event rather than replacing its identity")
        expect(discovered.pending?.timeEvidence?.postID == replyID, "Time evidence retains the independently verified reply identity")
        expect(discovered.pending?.announcedResetTime?.date == ISO8601DateFormatter().date(from: "2026-10-26T10:00:00Z"), "Self-authored related reply supplies the explicit reset deadline")
        expect(discovered.pending?.announcedResetTime?.qualifier == .noLaterThan, "Reply deadline qualifier stays intact")
        expect(discovered.pending?.relatedPosts.contains(where: { $0.postID == replyID }) == true, "Related source chain remains available to the UI")
        expect(discovered.supplementalDiscoveryAvailable && discovered.supplementalScannedAt == ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z"), "Actual collector scan time is preserved, not wrapper update time")
        let corrected = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, replyID: timeReply, correctionID: correctedReply],
            supplemental: supplemental([publicPost(correctionID, correctionText, parent: replyID, at: "2026-10-25T08:00:00Z"), publicPost(replyID, timeText, parent: rootID)]))
        expect(corrected.pending?.timeEvidence?.postID == correctionID, "Newest verified time correction wins across a reply chain")
        expect(corrected.pending?.announcedResetTime?.date == ISO8601DateFormatter().date(from: "2026-10-26T11:00:00Z"), "Older replies cannot overwrite a newer correction")
        let imposter = tweet(replyID, text: timeText, author: "other_user", parent: rootID)
        let otherAuthor = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, replyID: imposter],
            supplemental: supplemental([publicPost(replyID, timeText, parent: rootID)]))
        expect(otherAuthor.pending?.timeEvidence == nil, "A comment from another user is never official time evidence")
        var unrelatedReply = tweet(replyID, text: timeText)
        unrelatedReply["created_at"] = "2026-10-25T07:00:00Z"
        let unrelatedTime = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, replyID: unrelatedReply],
            supplemental: supplemental([publicPost(replyID, timeText, parent: rootID)]))
        expect(unrelatedTime.pending?.timeEvidence == nil && unrelatedTime.pending?.id == rootID, "Community claimed relation is insufficient when X does not show it")
        let unverifiedCommunity = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet],
            supplemental: supplemental([publicPost(replyID, timeText, parent: rootID)]))
        expect(unverifiedCommunity.pending?.announcedResetTime == nil, "Community reply text alone never becomes an official timestamp")
        let manual = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, replyID: timeReply], additional: [replyID])
        expect(manual.pending?.timeEvidence?.postID == replyID && !manual.supplementalDiscoveryAvailable, "A manually supplied verified self-reply works when discovery is unavailable")
        let standaloneText = "We will reset usage tomorrow before 10am UTC."
        var standaloneTweet = tweet(replyID, text: standaloneText)
        standaloneTweet["created_at"] = "2026-10-25T07:00:00Z"
        let standalone = try run(feed(), tweets: [replyID: standaloneTweet], additional: [replyID])
        expect(standalone.pending?.id == replyID && standalone.pending?.announcedResetTime != nil, "An explicit standalone later reset post may be its own verified event")
        let quoteTweet: [String: Any] = ["id_str": replyID, "text": timeText, "created_at": "2026-10-25T07:00:00Z", "user": ["screen_name": "thsottiaux"], "quoted_tweet": rootTweet]
        let quoteRefinement = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, replyID: quoteTweet], additional: [replyID])
        expect(quoteRefinement.pending?.timeEvidence?.postID == replyID, "An explicit self-quote relation can refine the original reset")
        var completionTweet = tweet(correctionID, text: "We have reset usage limits for everyone.", parent: rootID)
        completionTweet["created_at"] = "2026-10-25T09:00:00Z"
        let completionUpdate = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, correctionID: completionTweet], additional: [correctionID])
        expect(completionUpdate.pending == nil && completionUpdate.latest?.id == correctionID, "A verified linked completion supersedes its original preview")
        expect(completionUpdate.latest?.timeEvidence == nil, "A completion does not invent a new future reset deadline")
        let coreWithoutSupplement = try run(feed(latest: latest), tweets: [latestID: actual])
        expect(coreWithoutSupplement.latest != nil && !coreWithoutSupplement.supplementalDiscoveryAvailable, "Supplemental failure does not break the core verified status")
        let staleSupplement = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, replyID: timeReply],
            supplemental: supplemental([publicPost(replyID, timeText, parent: rootID)], scanned: "2026-10-24T01:00:00Z"))
        expect(staleSupplement.supplementalScannedAt! < now.addingTimeInterval(-86_400), "Collector lag is exposed instead of being relabeled as continuous monitoring")
        let chainCompletion = try run(feed(latest: latest), tweets: [latestID: laterCompletion, pendingID: pendingTweet, parentID: parent])
        expect(chainCompletion.latest?.relatedPosts.contains(where: { $0.postID == pendingID }) == true && chainCompletion.latest?.relatedPosts.contains(where: { $0.postID == parentID }) == true, "Known completion quote and parent chain are available even without a timeline API")
        let withdrawalID = "2115000000000000004"
        var withdrawalTweet = tweet(withdrawalID, text: "The reset time has been postponed.", parent: rootID)
        withdrawalTweet["created_at"] = "2026-10-25T10:00:00Z"
        let withdrawn = try run(feed(pending: originalTimeCandidate), tweets: [pendingID: tweet(pendingID, text: exactText), withdrawalID: ["id_str": withdrawalID, "text": "The reset time has been postponed.", "created_at": "2026-10-25T10:00:00Z", "user": ["screen_name": "thsottiaux"], "in_reply_to_status_id_str": pendingID]], additional: [withdrawalID])
        expect(withdrawn.pending?.timeWithdrawn == true && withdrawn.pending?.announcedResetTime == nil, "Verified related postponement clears the previous definite time")
        expect(withdrawn.pending?.timeEvidence?.postID == withdrawalID, "Withdrawal source remains available for viewing")
        expect(!withdrawn.hasExpiredPending && withdrawn.pending != nil, "Old community reference cannot instantly expire a later withdrawal update")
        var unrelatedCancellation = tweet(withdrawalID, text: "The livestream has been cancelled.", parent: pendingID)
        unrelatedCancellation["created_at"] = "2026-10-25T10:00:00Z"
        let unaffected = try run(feed(pending: originalTimeCandidate), tweets: [pendingID: tweet(pendingID, text: exactText), withdrawalID: unrelatedCancellation], additional: [withdrawalID])
        expect(unaffected.pending?.timeWithdrawn == false && unaffected.pending?.announcedResetTime != nil, "An unrelated cancellation does not withdraw a reset deadline")
        let foreignCancellation = tweet(withdrawalID, text: "The reset time has been postponed.", author: "other_user", parent: pendingID)
        let foreignWithdraw = try run(feed(pending: originalTimeCandidate), tweets: [pendingID: tweet(pendingID, text: exactText), withdrawalID: foreignCancellation], additional: [withdrawalID])
        expect(foreignWithdraw.pending?.timeWithdrawn == false && foreignWithdraw.pending?.announcedResetTime != nil, "Other people's cancellation claims never override the author's time")
        let unlinkedWithdrawal = tweet(withdrawalID, text: "The reset time has been postponed.")
        let unlinked = try run(feed(pending: originalTimeCandidate), tweets: [pendingID: tweet(pendingID, text: exactText), withdrawalID: unlinkedWithdrawal], additional: [withdrawalID])
        expect(unlinked.pending?.id == pendingID && unlinked.pending?.timeWithdrawn == false, "An unlinked postponement does not modify the original event")
        let restorationID = "2115000000000000005"
        var restoration = tweet(restorationID, text: "We will reset usage tomorrow before 12pm UTC.", parent: withdrawalID)
        restoration["created_at"] = "2026-10-25T11:00:00Z"
        let restored = try run(feed(pending: originalTimeCandidate), tweets: [pendingID: tweet(pendingID, text: exactText), withdrawalID: ["id_str": withdrawalID, "text": "The reset time has been postponed.", "created_at": "2026-10-25T10:00:00Z", "user": ["screen_name": "thsottiaux"], "in_reply_to_status_id_str": pendingID], restorationID: restoration], additional: [restorationID, withdrawalID])
        expect(restored.pending?.timeWithdrawn == false && restored.pending?.timeEvidence?.postID == restorationID, "A newer explicit plan can restore a time after withdrawal")
        expect(restored.pending?.announcedResetTime?.date == ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z"), "Older withdrawal cannot overwrite the newer confirmed time")
        var vagueReply = tweet(replyID, text: "Tomorrow before 10am PST", parent: pendingID)
        vagueReply["created_at"] = "2026-10-25T10:00:00Z"
        let vagueTime = try run(feed(pending: originalTimeCandidate), tweets: [pendingID: tweet(pendingID, text: exactText), replyID: vagueReply], additional: [replyID])
        expect(vagueTime.pending?.timeEvidence == nil && vagueTime.pending?.announcedResetTime?.date == ISO8601DateFormatter().date(from: "2026-10-25T18:00:00Z"), "Ambiguous follow-up never replaces a clear original time")
        var separateCompletion = tweet(correctionID, text: "We have reset usage limits for everyone.")
        separateCompletion["created_at"] = "2026-10-25T09:00:00Z"
        let separate = try run(feed(pending: rootCandidate), tweets: [rootID: rootTweet, correctionID: separateCompletion], additional: [correctionID])
        expect(separate.pending?.id == rootID && separate.latest?.id == correctionID, "Unrelated same-kind completion cannot cancel a different preview")
        print("TiboResetMonitorTests: \(count) checks passed")
        if CommandLine.arguments.contains("--live") {
            let live = try TiboResetMonitor().fetch()
            print("Live: latest=\(live.latest?.id ?? "unverified-or-none"), pending=\(live.pending?.id ?? "none"), unverifiedPending=\(live.hasUnverifiedPending), expiredPending=\(live.hasExpiredPending)")
            print("Live supplemental: available=\(live.supplementalDiscoveryAvailable), actualScan=\(live.supplementalScannedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"), relatedPosts=\(live.latest?.relatedPosts.count ?? live.pending?.relatedPosts.count ?? 0)")
        }
    }
}
