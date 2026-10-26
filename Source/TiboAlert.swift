import Foundation

enum TiboAlertKind: String, Codable, Sendable {
    case pendingReset
    case pendingCredit
    case resetMessage
    case creditMessage
}

/// A verified public message that still needs the user's attention.
/// Publication of a reset message is not confirmation of this account's allowance.
struct TiboAlert: Sendable, Equatable {
    let id: String
    let kind: TiboAlertKind
    let title: String
    let sourceURL: URL
    let postedAt: Date
    /// Semantic content only: fetching again, countdown ticks and source freshness never change this.
    var revisionDetails: String? = nil

    var readKey: String {
        let content = revisionDetails ?? title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "tibo-v1|\(id)|\(kind.rawValue)|\(content)"
    }

    /// A verified publication remains a fact when a later verification attempt fails.
    /// Upcoming announcements and source freshness always come from the current fetch.
    static func preservingVerifiedLatest(
        in incoming: TiboResetSnapshot,
        previous: TiboResetSnapshot?
    ) -> TiboResetSnapshot {
        let latest: TiboResetAnnouncement?
        switch (incoming.latest, previous?.latest) {
        case let (current?, prior?): latest = current.postedAt >= prior.postedAt ? current : prior
        case let (current?, nil): latest = current
        case let (nil, prior?): latest = prior
        case (nil, nil): latest = nil
        }
        var pending = incoming.pending
        if var current = pending, let prior = previous?.pending, current.id == prior.id,
           let knownEvidence = prior.timeEvidence,
           current.timeEvidence.map({ $0.postedAt < knownEvidence.postedAt }) ?? true {
            current.timeEvidence = knownEvidence
            current.timeWithdrawn = prior.timeWithdrawn
            if !current.relatedPosts.contains(where: { $0.postID == knownEvidence.postID }) {
                current.relatedPosts.append(knownEvidence)
            }
            pending = current
        }
        return TiboResetSnapshot(
            fetchedAt: incoming.fetchedAt,
            sourceGeneratedAt: incoming.sourceGeneratedAt,
            latest: latest,
            pending: pending,
            hasUnverifiedPending: incoming.hasUnverifiedPending,
            hasExpiredPending: incoming.hasExpiredPending,
            hasUnverifiedLatest: incoming.hasUnverifiedLatest,
            supplementalScannedAt: incoming.supplementalScannedAt,
            supplementalDiscoveryAvailable: incoming.supplementalDiscoveryAvailable
        )
    }

    static func select(
        from snapshot: TiboResetSnapshot?,
        acknowledgedIDs: Set<String>,
        acknowledgedRevisions: Set<String> = [],
        now: Date = Date(),
        sourceStale: Bool = false
    ) -> TiboAlert? {
        guard let snapshot, now.timeIntervalSinceReferenceDate.isFinite else { return nil }

        let trustedPending = snapshot.pending.flatMap { isValid($0, now: now) ? $0 : nil }
        let pending = trustedPending.flatMap { announcement -> TiboResetAnnouncement? in
            if announcement.timeWithdrawn {
                let updateAge = now.timeIntervalSince(announcement.timeEvidence?.postedAt ?? announcement.postedAt)
                guard updateAge.isFinite, updateAge >= -300, updateAge <= 86_400 else { return nil }
                return announcement
            }
            if let reference = announcement.announcedResetTime?.date ?? announcement.referenceResetAt {
                guard reference.timeIntervalSinceReferenceDate.isFinite, reference > now else { return nil }
            } else {
                guard now.timeIntervalSince(announcement.postedAt) <= 86_400 else { return nil }
            }
            return announcement
        }

        if let pending, !sourceStale {
            let candidate = alert(for: pending, pending: true)
            if !isAcknowledged(candidate, ids: acknowledgedIDs, revisions: acknowledgedRevisions) { return candidate }
        }

        guard let latest = snapshot.latest,
              isValid(latest, now: now) else { return nil }
        let latestAlert = alert(for: latest, pending: false)
        guard !isAcknowledged(latestAlert, ids: acknowledgedIDs, revisions: acknowledgedRevisions) else { return nil }

        // Acknowledging a newer preview must not reveal an older completion as a new alert.
        if let pending = trustedPending, latest.postedAt <= pending.postedAt {
            let pendingAlert = alert(for: pending, pending: true)
            if isAcknowledged(pendingAlert, ids: acknowledgedIDs, revisions: acknowledgedRevisions),
               latest.id != pending.id || acknowledgedIDs.contains(pending.id) { return nil }
        }
        return latestAlert
    }

    /// The neutral message summary remains available after its red unread reminder is cleared.
    static func latestDisplay(
        from snapshot: TiboResetSnapshot?,
        now: Date = Date(),
        sourceStale: Bool = false
    ) -> TiboAlert? {
        select(from: snapshot, acknowledgedIDs: [], now: now, sourceStale: sourceStale)
    }

    /// Marking a newer announcement read must not make a previously known older completion appear new.
    static func revisionKeysToAcknowledge(
        alert: TiboAlert,
        snapshot: TiboResetSnapshot?,
        now: Date = Date()
    ) -> Set<String> {
        var keys: Set<String> = [alert.readKey]
        if alert.kind == .pendingReset || alert.kind == .pendingCredit {
            let baseline = TiboAlert(id: alert.id, kind: alert.kind, title: alert.title,
                sourceURL: alert.sourceURL, postedAt: alert.postedAt, revisionDetails: "message")
            keys.insert(baseline.readKey)
        }
        if let latest = snapshot?.latest, isValid(latest, now: now), latest.postedAt <= alert.postedAt {
            let latestAlert = self.alert(for: latest, pending: false)
            // A different stage on the same source can be a new meaningful update.
            if latest.id != alert.id || latestAlert.readKey == alert.readKey { keys.insert(latestAlert.readKey) }
        }
        return keys
    }

    private static func isAcknowledged(_ alert: TiboAlert, ids: Set<String>, revisions: Set<String>) -> Bool {
        ids.contains(alert.id) || revisions.contains(alert.readKey)
    }

    private static func alert(for announcement: TiboResetAnnouncement, pending: Bool) -> TiboAlert {
        let banked = announcement.resetType == "banked"
        let kind: TiboAlertKind = pending ? (banked ? .pendingCredit : .pendingReset) : (banked ? .creditMessage : .resetMessage)
        var title: String
        switch kind {
        case .pendingReset: title = "Tibo重置预告"
        case .pendingCredit: title = "Tibo重置券预告"
        case .resetMessage: title = "Tibo有重置消息"
        case .creditMessage: title = "Tibo有重置券消息"
        }
        if pending, announcement.timeWithdrawn {
            title = banked ? "Tibo重置券时间待定（有更新）" : "Tibo重置时间待定（有更新）"
        } else if pending, let announcedTime = announcement.announcedResetTime {
            title = "Tibo \(announcedTime.compact())\(banked ? "发重置券" : "重置")"
        }
        let revision: String
        if pending, announcement.timeWithdrawn {
            revision = "time-withdrawn|\(announcement.timeEvidence?.postID ?? "unknown")"
        } else if pending, let time = announcement.announcedResetTime {
            let evidence = announcement.timeEvidence.map { "|evidence:\($0.postID)" } ?? ""
            revision = "time:\(time.date.timeIntervalSince1970)|\(time.qualifier.rawValue)\(evidence)"
        } else {
            revision = "message"
        }
        return TiboAlert(id: announcement.id, kind: kind, title: title, sourceURL: announcement.url,
            postedAt: announcement.postedAt, revisionDetails: revision)
    }

    private static func isValid(_ announcement: TiboResetAnnouncement, now: Date) -> Bool {
        let age = now.timeIntervalSince(announcement.postedAt)
        guard age.isFinite, age >= -300, age <= 172_800,
              (10...25).contains(announcement.id.count),
              announcement.id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let url = URLComponents(url: announcement.url, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "x.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath == "/thsottiaux/status/\(announcement.id)" else { return false }
        return true
    }
}
