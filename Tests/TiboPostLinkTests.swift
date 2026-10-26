import Foundation

@main
enum TiboPostLinkTests {
    static func main() {
        let id = "2114200291319124163"
        let good = ["https://x.com/thsottiaux/status/\(id)", "https://x.com/thsottiaux/status/\(id)?s=20", " https://twitter.com/thsottiaux/status/\(id)/ "]
        let bad = ["http://x.com/thsottiaux/status/\(id)", "https://x.com.evil.example/thsottiaux/status/\(id)", "https://x.com/other/status/\(id)", "https://person@x.com/thsottiaux/status/\(id)", "https://x.com:8443/thsottiaux/status/\(id)", "https://x.com/thsottiaux/status/not-a-number", "https://x.com/thsottiaux/status/\(id)/photo/1", "https://x.com/thsottiaux%2Fstatus%2F\(id)", "arbitrary text", "https://x.com/thsottiaux/status/1"]
        for url in good { precondition(TiboPostLink.postID(from: url) == id) }
        for url in bad { precondition(TiboPostLink.postID(from: url) == nil) }
        print("TiboPostLinkTests: \(good.count + bad.count) checks passed")
    }
}
