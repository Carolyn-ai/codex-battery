import Foundation
import Darwin

enum UsageClientError: Error, LocalizedError, Equatable {
    case executableNotFound
    case launchFailed
    case timedOut
    case connectionClosed
    case responseTooLarge
    case invalidResponse
    case authenticationRequired
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound: return "未找到本机 Codex，请先安装或打开 Codex。"
        case .launchFailed: return "暂时无法启动 Codex 用量查询。"
        case .timedOut: return "用量查询超时，稍后会自动重试。"
        case .connectionClosed: return "Codex 用量连接已中断，稍后会自动重试。"
        case .responseTooLarge, .invalidResponse: return "Codex 返回的数据格式暂不支持。"
        case .authenticationRequired: return "请先打开 Codex 并登录，再刷新用量。"
        case .serviceUnavailable: return "暂时无法获取用量，请检查网络或 Codex 登录状态。"
        }
    }
}

/// Each refresh uses only initialize and account/rateLimits/read; no thread or model is started.
struct UsageClient: Sendable {
    let executableURL: URL?
    let timeout: TimeInterval
    let maximumOutputBytes: Int

    init(executableURL: URL? = nil, timeout: TimeInterval = 25, maximumOutputBytes: Int = 2_097_152) {
        self.executableURL = executableURL
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    }

    static func discoverExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    func fetch() throws -> UsageSnapshot {
        guard let executable = executableURL ?? Self.discoverExecutable(),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UsageClientError.executableNotFound
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        // Let Codex manage its own existing login. Do not inherit task tokens or a task-specific home.
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CODEX_") && !$0.key.hasPrefix("OPENAI_")
        }
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw UsageClientError.launchFailed }
        // The child has its own copies. Closing parent copies is essential for EOF detection.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            Self.stopAndReap(process)
            try? output.fileHandleForReading.close()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try data.withUnsafeBytes { raw in
                guard let address = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    try Self.waitFor(writeFD, events: Int16(POLLOUT), deadline: deadline)
                    let count = Darwin.write(writeFD, address.advanced(by: offset), raw.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    else { throw UsageClientError.connectionClosed }
                }
            }
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "codex_battery", "title": "Codex Battery", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ])

        var buffer = Data()
        var totalBytes = 0
        var initialized = false
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Self.waitFor(readFD, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(readFD, &chunk, chunk.count)
            if count == 0 { throw UsageClientError.connectionClosed }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw UsageClientError.connectionClosed
            }
            totalBytes += count
            guard totalBytes <= maximumOutputBytes else { throw UsageClientError.responseTooLarge }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if line.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    throw UsageClientError.invalidResponse
                }
                guard let id = object["id"] as? Int, id == 1 || id == 2 else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw Self.sanitizedServerError(error)
                }
                guard let result = object["result"] as? [String: Any] else {
                    throw UsageClientError.invalidResponse
                }
                if id == 1 && !initialized {
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if id == 2 && initialized {
                    return try UsageSnapshot.parse(result: result)
                }
            }
        }
    }

    private static func sanitizedServerError(_ error: [String: Any]) -> UsageClientError {
        let message = (error["message"] as? String ?? "").lowercased()
        let code = error["code"] as? Int
        if code == 401 || message.contains("unauthorized") || message.contains("not logged") ||
            message.contains("not authenticated") || message.contains("authentication required") ||
            message.contains("requires chatgpt") {
            return .authenticationRequired
        }
        return .serviceUnavailable
    }

    private static func waitFor(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw UsageClientError.timedOut }
            var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = Int32(min(1_000, max(1, remaining * 1_000)))
            let status = poll(&descriptorState, 1, milliseconds)
            if status < 0 {
                if errno == EINTR { continue }
                throw UsageClientError.connectionClosed
            }
            if status == 0 { continue }
            if descriptorState.revents & events != 0 { return }
            // Read any final bytes delivered together with POLLHUP before reporting EOF.
            if events == Int16(POLLIN) && descriptorState.revents & Int16(POLLHUP) != 0 { return }
            if descriptorState.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw UsageClientError.connectionClosed
            }
        }
    }

    private static func stopAndReap(_ process: Process) {
        func waitBriefly(_ duration: TimeInterval) {
            let end = ProcessInfo.processInfo.systemUptime + duration
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
        }
        waitBriefly(0.25)
        if process.isRunning { process.terminate(); waitBriefly(0.5) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
