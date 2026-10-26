import Foundation

enum TiboPostLink {
    static func postID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let path = url.percentEncodedPath.hasSuffix("/") ? String(url.percentEncodedPath.dropLast()) : url.percentEncodedPath
        let prefix = "/thsottiaux/status/"
        guard path.hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        guard (10...25).contains(id.count), id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return id
    }
}
