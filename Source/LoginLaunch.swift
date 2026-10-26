import Foundation

enum LoginLaunch {
    static let identifier = "local.codex-battery"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(identifier).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard let executable = Bundle.main.executableURL,
                  Bundle.main.bundleURL.pathExtension == "app" else { return }
            let plist: [String: Any] = [
                "Label": identifier,
                "ProgramArguments": [executable.path],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } else if isEnabled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
