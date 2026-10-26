import Foundation

struct TiboTimeEvidence: Sendable, Equatable {
    let postID: String
    let text: String
    let postedAt: Date
    let url: URL
}

struct TiboResetAnnouncement: Sendable, Equatable {
    let id: String
    let text: String
    let postedAt: Date
    let url: URL
    /// A community interpretation of the time, not an official exact deadline.
    let referenceResetAt: Date?
    /// Derived from verified text: regular, banked, or unknown.
    let resetType: String

    /// Evidence is populated only after verifying a related self-authored X post.
    var timeEvidence: TiboTimeEvidence? = nil
    var relatedPosts: [TiboTimeEvidence] = []
    var timeWithdrawn: Bool = false

    /// A clear related self-reply may refine the original announcement's time.
    var announcedResetTime: ResetAnnouncementTime? {
        guard !timeWithdrawn else { return nil }
        if let evidence = timeEvidence,
           let parsed = ResetAnnouncementTimeParser.parse(text: evidence.text, postedAt: evidence.postedAt) {
            return parsed
        }
        return ResetAnnouncementTimeParser.parse(text: text, postedAt: postedAt)
    }
}

struct TiboResetSnapshot: Sendable {
    let fetchedAt: Date
    let sourceGeneratedAt: Date?
    let latest: TiboResetAnnouncement?
    let pending: TiboResetAnnouncement?
    let hasUnverifiedPending: Bool
    let hasExpiredPending: Bool
    let hasUnverifiedLatest: Bool
    /// Actual collector scan time, not the public wrapper generation timestamp.
    var supplementalScannedAt: Date? = nil
    var supplementalDiscoveryAvailable: Bool = false
}

enum TiboResetMonitorError: Error, LocalizedError {
    case unavailable
    case unsupportedData

    var errorDescription: String? {
        switch self {
        case .unavailable: return "暂时无法检查 Tibo 重置消息，稍后会自动重试。"
        case .unsupportedData: return "重置消息来源的数据格式暂不支持。"
        }
    }
}

/// Community discovery plus independent body/author verification on X's public syndication host.
/// No account information, credentials, cookies, or browser login is used.
struct TiboResetMonitor: Sendable {
    private let fetchData: (@Sendable (URL) throws -> Data)?
    private let now: @Sendable () -> Date
    private let additionalPostIDs: [String]
    private static let maximumBytes = 1_048_576
    private static let author = "thsottiaux"

    init(fetchData: (@Sendable (URL) throws -> Data)? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         additionalPostIDs: [String] = []) {
        self.fetchData = fetchData
        self.now = now
        var seen = Set<String>()
        self.additionalPostIDs = additionalPostIDs.filter { Self.validID($0) && seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    func fetch() throws -> TiboResetSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        func read(_ url: URL, maximumWait: TimeInterval? = nil) throws -> Data {
            guard Self.isAllowed(url) else { throw TiboResetMonitorError.unsupportedData }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TiboResetMonitorError.unavailable }
            let bytes = try fetchData?(url) ?? Self.download(url, timeout: min(remaining, maximumWait ?? remaining))
            guard bytes.count <= Self.maximumBytes else { throw TiboResetMonitorError.unsupportedData }
            return bytes
        }
        let feed = try Self.object(read(URL(string: "https://codex-resets.com/api/v1/status")!))
        guard let data = feed["data"] as? [String: Any],
              let meta = feed["meta"] as? [String: Any],
              let generatedAt = Self.date(meta["generated_at"]),
              generatedAt <= now().addingTimeInterval(300),
              data.keys.contains("scheduled_reset"), data.keys.contains("latest_reset") else {
            throw TiboResetMonitorError.unsupportedData
        }
        // active_watch is an AI-classified forecast. It is deliberately not interpreted.
        let pendingValue = data["scheduled_reset"]
        let latestValue = data["latest_reset"]
        let pendingCandidate = try? Self.candidate(pendingValue, pending: true)
        let latestCandidate = try? Self.candidate(latestValue, pending: false)
        var officialCache: [String: [String: Any]] = [:]
        var officialRequests = 0

        func official(_ id: String) throws -> [String: Any] {
            if let cached = officialCache[id] { return cached }
            guard Self.validID(id), officialRequests < 6 else { throw TiboResetMonitorError.unavailable }
            officialRequests += 1
            var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
            components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "lang", value: "en"), URLQueryItem(name: "token", value: "1")]
            let tweet = try Self.object(read(components.url!))
            guard Self.isOfficial(tweet, id: id) else { throw TiboResetMonitorError.unsupportedData }
            officialCache[id] = tweet
            return tweet
        }

        func evidence(_ tweet: [String: Any]) -> TiboTimeEvidence? {
            guard let id = tweet["id_str"] as? String, Self.isOfficial(tweet, id: id),
                  let body = tweet["text"] as? String, !body.isEmpty, body.count <= 10_000,
                  let postedAt = Self.date(tweet["created_at"]), postedAt <= now().addingTimeInterval(300) else { return nil }
            return TiboTimeEvidence(postID: id, text: Self.cleanText(body), postedAt: postedAt,
                url: URL(string: "https://x.com/\(Self.author)/status/\(id)")!)
        }

        // Only explicit X quote/reply edges are followed. Same author or nearby time is not a relationship.
        func context(_ tweet: [String: Any]) -> [TiboTimeEvidence] {
            var queue: [([String: Any], Int)] = [(tweet, 0)]
            var found: [String: TiboTimeEvidence] = [:]
            while !queue.isEmpty {
                let (current, depth) = queue.removeFirst()
                guard let item = evidence(current), found[item.postID] == nil else { continue }
                found[item.postID] = item
                guard depth < 3 else { continue }
                if let quote = current["quoted_tweet"] as? [String: Any], let quoted = evidence(quote) {
                    if officialCache[quoted.postID] == nil { officialCache[quoted.postID] = quote }
                    queue.append((officialCache[quoted.postID]!, depth + 1))
                }
                if let parentID = current["in_reply_to_status_id_str"] as? String, Self.validID(parentID),
                   let parent = try? official(parentID) { queue.append((parent, depth + 1)) }
            }
            return found.values.sorted { $0.postedAt < $1.postedAt }
        }

        func verified(_ tweet: [String: Any], reference: Date?, expectedPending: Bool?) throws -> VerifiedAnnouncement {
            guard let primary = evidence(tweet) else { throw TiboResetMonitorError.unsupportedData }
            let chain = context(tweet)
            let joined = chain.map(\.text).joined(separator: " ")
            let plannedParent = chain.contains { $0.postID != primary.postID && Self.hasResetContext($0.text) && !Self.isCompletion($0.text) && !Self.hasResetWithdrawal($0.text) }
            let withdrawn = Self.hasResetWithdrawal(primary.text) && plannedParent
            if Self.hasResetWithdrawal(primary.text) && !withdrawn { throw TiboResetMonitorError.unsupportedData }
            let explicitTime = ResetAnnouncementTimeParser.parse(text: primary.text, postedAt: primary.postedAt)
            let clearNewPlan = Self.hasResetContext(primary.text) && Self.hasFutureResetIntent(primary.text) && explicitTime != nil
            guard Self.hasResetContext(joined), !Self.hasResetNegation(joined) || withdrawn || clearNewPlan else {
                throw TiboResetMonitorError.unsupportedData
            }
            let completed = Self.isCompletion(primary.text)
            if expectedPending == true && completed { throw TiboResetMonitorError.unsupportedData }
            if expectedPending == false && !completed { throw TiboResetMonitorError.unsupportedData }
            // An undiscovered standalone post must explicitly announce a future reset, not merely mention one.
            if expectedPending == nil && !completed {
                let futureIntent = Self.hasFutureResetIntent(primary.text)
                guard futureIntent || (withdrawn && plannedParent) || (explicitTime != nil && (Self.hasResetContext(primary.text) || plannedParent)) else {
                    throw TiboResetMonitorError.unsupportedData
                }
            }
            var announcement = TiboResetAnnouncement(id: primary.postID, text: primary.text, postedAt: primary.postedAt,
                url: primary.url, referenceResetAt: reference, resetType: Self.resetKind(joined))
            announcement.relatedPosts = chain.filter { $0.postID != primary.postID }
            announcement.timeWithdrawn = withdrawn
            if withdrawn { announcement.timeEvidence = primary }
            if !completed && !withdrawn {
                // A newer explicit related reply wins; an ambiguous reply never replaces a clear time.
                let timed = chain.filter { ResetAnnouncementTimeParser.parse(text: $0.text, postedAt: $0.postedAt) != nil }
                if let best = timed.max(by: { $0.postedAt < $1.postedAt }), best.postID != primary.postID {
                    announcement.timeEvidence = best
                }
            }
            return VerifiedAnnouncement(announcement: announcement, relatedIDs: Set(chain.map(\.postID)), completed: completed)
        }

        func verify(_ candidate: Candidate, pending: Bool) throws -> VerifiedAnnouncement {
            let tweet = try official(candidate.id)
            guard let body = tweet["text"] as? String,
                  Self.normalized(body) == Self.normalized(candidate.text) else { throw TiboResetMonitorError.unsupportedData }
            return try verified(tweet, reference: pending ? candidate.referenceResetAt : nil, expectedPending: pending)
        }

        // Core status remains useful even when supplemental discovery is unavailable.
        var verifiedPending = pendingCandidate.flatMap { try? verify($0, pending: true) }
        var verifiedLatest = latestCandidate.flatMap { try? verify($0, pending: false) }
        var supplementalScannedAt: Date?
        var supplementalAvailable = false
        var discoveryObjects: [[String: Any]] = []
        if let extra = try? Self.object(read(URL(string: "https://will-codex-reset.com/api/public")!, maximumWait: 3)),
           extra["schema_version"] as? Int == 1,
           let source = extra["source"] as? [String: Any], source["account"] as? String == Self.author,
           let posts = extra["posts"] as? [[String: Any]], posts.count <= 2_000 {
            supplementalAvailable = true
            supplementalScannedAt = Self.date(source["last_success_at"])
            discoveryObjects = posts.filter { item in
                guard let id = item["id"] as? String, Self.validID(id), item["author"] as? String == Self.author,
                      let posted = Self.date(item["at"]), posted <= now().addingTimeInterval(300),
                      now().timeIntervalSince(posted) <= 72 * 3_600,
                      let body = item["text"] as? String, body.count <= 10_000 else { return false }
                return true
            }.sorted { (Self.date($0["at"]) ?? .distantPast) > (Self.date($1["at"]) ?? .distantPast) }
        }
        let knownIDs = (verifiedPending?.relatedIDs ?? []).union(verifiedLatest?.relatedIDs ?? [])
        let discoveryByID = Dictionary(discoveryObjects.compactMap { object -> (String, [String: Any])? in
            guard let id = object["id"] as? String else { return nil }; return (id, object)
        }, uniquingKeysWith: { first, _ in first })
        func discoveryLinksToKnown(_ id: String, depth: Int = 0, seen: Set<String> = []) -> Bool {
            if knownIDs.contains(id) { return true }
            guard depth < 3, !seen.contains(id), let item = discoveryByID[id],
                  let refs = item["references"] as? [[String: Any]] else { return false }
            return refs.contains { ref in
                guard let target = ref["id"] as? String,
                      ["replied_to", "quoted"].contains(ref["type"] as? String ?? "") else { return false }
                return discoveryLinksToKnown(target, depth: depth + 1, seen: seen.union([id]))
            }
        }
        let relatedIDs = discoveryObjects.compactMap { item -> String? in
            guard let id = item["id"] as? String, !knownIDs.contains(id), discoveryLinksToKnown(id) else { return nil }
            return id
        }
        let standaloneIDs = discoveryObjects.compactMap { item -> String? in
            guard let id = item["id"] as? String, !knownIDs.contains(id),
                  let body = item["text"] as? String, Self.hasResetContext(body),
                  (Self.isCompletion(body) || Self.hasFutureResetIntent(body) || Self.hasResetWithdrawal(body)
                   || ResetAnnouncementTimeParser.parse(text: body, postedAt: Self.date(item["at"])!) != nil) else { return nil }
            return id
        }
        var attempted = Set<String>()
        let queuedIDs = additionalPostIDs + relatedIDs + standaloneIDs
        for id in queuedIDs where attempted.insert(id).inserted && !knownIDs.contains(id) {
            guard officialRequests < 6 else { break }
            guard let tweet = try? official(id), let update = try? verified(tweet, reference: nil, expectedPending: nil) else { continue }
            if update.completed {
                if verifiedLatest == nil || update.announcement.postedAt > verifiedLatest!.announcement.postedAt { verifiedLatest = update }
            } else if var current = verifiedPending, !current.relatedIDs.isDisjoint(with: update.relatedIDs),
                      update.announcement.postedAt >= current.announcement.postedAt {
                if update.announcement.timeWithdrawn,
                   update.announcement.postedAt >= (current.announcement.timeEvidence?.postedAt ?? current.announcement.postedAt) {
                    current.announcement.timeWithdrawn = true
                    current.announcement.timeEvidence = evidence(tweet)
                } else if let direct = evidence(tweet), direct.postedAt >= (current.announcement.timeEvidence?.postedAt ?? current.announcement.postedAt),
                   ResetAnnouncementTimeParser.parse(text: direct.text, postedAt: direct.postedAt) != nil {
                    current.announcement.timeWithdrawn = false
                    current.announcement.timeEvidence = direct
                } else if let refined = update.announcement.timeEvidence,
                          refined.postedAt >= (current.announcement.timeEvidence?.postedAt ?? current.announcement.postedAt) {
                    current.announcement.timeWithdrawn = false
                    current.announcement.timeEvidence = refined
                }
                current.announcement.relatedPosts = Self.mergedPosts(current.announcement.relatedPosts + update.announcement.relatedPosts + [TiboTimeEvidence(postID: update.announcement.id, text: update.announcement.text, postedAt: update.announcement.postedAt, url: update.announcement.url)], excluding: current.announcement.id)
                current.relatedIDs.formUnion(update.relatedIDs)
                verifiedPending = current
            } else if verifiedPending == nil || update.announcement.postedAt > verifiedPending!.announcement.postedAt {
                verifiedPending = update
            }
        }
        var supersededPending = false
        if let pending = verifiedPending, let latest = verifiedLatest,
           latest.announcement.postedAt > pending.announcement.postedAt,
           !latest.relatedIDs.isDisjoint(with: pending.relatedIDs) {
            verifiedPending = nil
            supersededPending = true
        }
        let withdrawn = verifiedPending?.announcement.timeWithdrawn == true
        let pendingDate = withdrawn ? verifiedPending?.announcement.timeEvidence?.postedAt ?? verifiedPending?.announcement.postedAt
            : verifiedPending?.announcement.postedAt ?? pendingCandidate?.announcedAt
        let reference: Date? = withdrawn ? nil : verifiedPending?.announcement.announcedResetTime?.date ?? verifiedPending?.announcement.referenceResetAt ?? pendingCandidate?.referenceResetAt
        let hasPendingCandidate = pendingCandidate != nil || verifiedPending != nil
        let expiredPending = !supersededPending && hasPendingCandidate
            && (reference.map { $0 <= now() } ?? pendingDate.map { now().timeIntervalSince($0) > 86_400 } ?? false)
        if expiredPending { verifiedPending = nil }
        return TiboResetSnapshot(
            fetchedAt: now(), sourceGeneratedAt: generatedAt, latest: verifiedLatest?.announcement, pending: verifiedPending?.announcement,
            hasUnverifiedPending: !(pendingValue is NSNull) && pendingValue != nil && verifiedPending == nil && !expiredPending && !supersededPending,
            hasExpiredPending: expiredPending,
            hasUnverifiedLatest: !(latestValue is NSNull) && latestValue != nil && verifiedLatest == nil,
            supplementalScannedAt: supplementalScannedAt, supplementalDiscoveryAvailable: supplementalAvailable
        )
    }

    private struct Candidate {
        let id: String
        let text: String
        let resetType: String
        let announcedAt: Date
        let referenceResetAt: Date?
    }

    private struct VerifiedAnnouncement {
        var announcement: TiboResetAnnouncement
        var relatedIDs: Set<String>
        let completed: Bool
    }

    private static func candidate(_ value: Any?, pending: Bool) throws -> Candidate {
        guard let item = value as? [String: Any], let id = item["id"] as? String, validID(id),
              let text = item["text"] as? String, !text.isEmpty, text.count <= 10_000,
              let announcedAt = date(item["announced_at"]),
              let resetType = item["reset_type"] as? String, ["regular", "banked"].contains(resetType),
              let source = item["source"] as? [String: Any], source["type"] as? String == "x_post",
              source["author"] as? String == author,
              let rawURL = source["url"] as? String, let url = URL(string: rawURL),
              url.scheme == "https", ["x.com", "twitter.com", "www.x.com", "www.twitter.com"].contains(url.host?.lowercased() ?? ""),
              url.port == nil, url.user == nil, url.password == nil,
              url.path == "/\(author)/status/\(id)",
              !pending || item["status"] as? String == "scheduled" else {
            throw TiboResetMonitorError.unsupportedData
        }
        return Candidate(id: id, text: text, resetType: resetType, announcedAt: announcedAt, referenceResetAt: pending ? date(item["scheduled_for"]) : nil)
    }

    private static func mergedPosts(_ posts: [TiboTimeEvidence], excluding: String) -> [TiboTimeEvidence] {
        var unique: [String: TiboTimeEvidence] = [:]
        for post in posts where post.postID != excluding { unique[post.postID] = post }
        return unique.values.sorted { $0.postedAt < $1.postedAt }.suffix(8).map { $0 }
    }

    private static func hasResetWithdrawal(_ text: String) -> Bool {
        let value = normalized(text).lowercased()
        return value.range(of: #"\b(?:the )?(?:usage(?: limits)?|codex(?: usage)?(?: limits)?|reset(?: time| deadline| schedule)?)\s+(?:(?:is|was|has been|will be)\s+)?(?:cancelled|canceled|postponed|delayed|withdrawn)\b|\b(?:we|i)\s+(?:are |am |have )?(?:cancelling|canceling|postponing|delaying)\s+(?:the )?(?:usage )?reset\b|\b(?:we|i)\s+(?:will not|won't|won’t)\s+reset\b"#, options: .regularExpression) != nil
    }

    private static func hasFutureResetIntent(_ text: String) -> Bool {
        let value = normalized(text).lowercased()
        guard !hasResetNegation(value), !isCompletion(value),
              value.range(of: #"\b(?:maybe|might|perhaps|never|hopefully|tentatively|postponed|cancelled|canceled)\b"#, options: .regularExpression) == nil else { return false }
        return value.range(of: #"\b(?:we|i)\s+will\s+(?:reset|add (?:a |one )?banked reset)\b|\b(?:we'll|we’ll|i'll|i’ll)\s+reset\b|\b(?:usage(?: limits)?|limits)\s+will\s+reset\b|\breset(?:ting)?\s+(?:today|tomorrow)\b"#, options: .regularExpression) != nil
    }

    private static func validID(_ id: String) -> Bool {
        (10...25).contains(id.count) && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func isOfficial(_ tweet: [String: Any], id: String) -> Bool {
        guard validID(id), tweet["id_str"] as? String == id,
              let user = tweet["user"] as? [String: Any],
              user["screen_name"] as? String == author else { return false }
        return true
    }

    private static func hasResetContext(_ text: String) -> Bool {
        let value = normalized(text).lowercased()
        return value.range(of: #"\breset(?:s|ting)?\b"#, options: .regularExpression) != nil
            || (value.contains("propagated") && (value.contains("codex") || value.contains("work")))
    }

    private static func isCompletion(_ text: String) -> Bool {
        let value = normalized(text).lowercased()
        return ["all propagated", "have reset", "has reset", "have been reset", "has been reset", "are reset", "reset is complete", "reset completed", "we've reset", "we’ve reset", "added a banked reset", "banked reset has been added"].contains(where: value.contains)
    }

    private static func hasResetNegation(_ text: String) -> Bool {
        let value = normalized(text).lowercased()
        return ["not reset", "no reset", "won't reset", "won’t reset", "not a reset", "not doing a reset", "not be reset", "reset is canceled", "reset is cancelled"].contains(where: value.contains)
    }

    private static func resetKind(_ text: String) -> String {
        let value = normalized(text).lowercased()
        if ["banked reset", "reset card", "reset credit"].contains(where: value.contains) { return "banked" }
        if value.contains("reset") && (value.contains("usage") || value.contains("limits")) { return "regular" }
        return "unknown"
    }

    private static func cleanText(_ value: String) -> String {
        let withoutURLs = value.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        return withoutURLs.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func normalized(_ value: String) -> String { cleanText(value) }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TiboResetMonitorError.unsupportedData
        }
        return value
    }

    fileprivate static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil else { return false }
        return (url.host == "codex-resets.com" && url.path == "/api/v1/status")
            || (url.host == "will-codex-reset.com" && url.path == "/api/public" && url.query == nil)
            || (url.host == "cdn.syndication.twimg.com" && url.path == "/tweet-result")
    }

    private static func download(_ url: URL, timeout: TimeInterval) throws -> Data {
        let reader = PublicHTTPReader(maximumBytes: maximumBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let callbackQueue = OperationQueue()
        callbackQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: callbackQueue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBattery/1.4.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        task.resume()
        guard reader.finished.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw TiboResetMonitorError.unavailable
        }
        return try reader.result()
    }
}

private final class PublicHTTPReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let maximumBytes: Int
    private var bytes = Data()
    private var failed = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, TiboResetMonitor.isAllowed(url) else {
            lock.lock(); failed = true; lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, TiboResetMonitor.isAllowed(url),
              response.expectedContentLength <= Int64(maximumBytes) else {
            lock.lock(); failed = true; lock.unlock()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if failed || data.count > maximumBytes - bytes.count {
            failed = true
            lock.unlock()
            dataTask.cancel()
        } else {
            bytes.append(data)
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); failed = failed || error != nil; lock.unlock()
        finished.signal()
    }

    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw TiboResetMonitorError.unavailable }
        return bytes
    }
}
