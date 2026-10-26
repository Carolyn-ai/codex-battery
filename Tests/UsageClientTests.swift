import Foundation

@main
struct UsageClientTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBatteryClientTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = """
        import json, os, sys, time, signal
        def emit(obj):
            print(json.dumps(obj), flush=True)
        first = json.loads(sys.stdin.readline())
        assert first['id'] == 1 and first['method'] == 'initialize'
        assert not any(k.startswith('CODEX_') or k.startswith('OPENAI_') for k in os.environ)
        emit({'id':1, 'result':{'userAgent':'test'}})
        initialized = json.loads(sys.stdin.readline())
        assert initialized['method'] == 'initialized'
        request = json.loads(sys.stdin.readline())
        assert request['id'] == 2 and request['method'] == 'account/rateLimits/read'
        """
        let result = """
        {'id':2,'result':{'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':33,'windowDurationMins':10080,'resetsAt':1793517196},'secondary':None}}}}
        """
        var passed = 0
        func executable(_ name: String, body: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try ("#!/usr/bin/python3\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            passed += 1
        }
        func expectError(_ expected: UsageClientError, _ name: String, body: String, timeout: TimeInterval = 2, limit: Int = 2_097_152) throws {
            let url = try executable(name, body: body)
            do {
                _ = try UsageClient(executableURL: url, timeout: timeout, maximumOutputBytes: limit).fetch()
                fatalError("Expected \(expected): \(name)")
            } catch let error as UsageClientError { check(error == expected, "Wrong error for \(name): \(error)") }
        }

        let success = try executable("success", body: fixture + "\nemit(" + result + ")\nassert sys.stdin.read() == ''")
        let snapshot = try UsageClient(executableURL: success, timeout: 2).fetch()
        check(snapshot.primary?.displayPercent == 67, "Expected 67% remaining")
        check(snapshot.primary?.windowDurationMins == 10080, "Preserve actual duration")
        check(snapshot.secondary == nil, "Preserve absent secondary")

        let split = try executable("split", body: fixture + "\nemit({'method':'account/updated','params':{}})\ns=json.dumps(" + result + ")+ '\\n'\nfor c in [s[:4],s[4:29],s[29:]]:\n sys.stdout.write(c);sys.stdout.flush();time.sleep(0.02)")
        let splitSnapshot = try UsageClient(executableURL: split, timeout: 2).fetch()
        check(splitSnapshot.primary?.displayPercent == 67, "Reassemble partial lines and ignore notifications")

        try expectError(.authenticationRequired, "auth", body: fixture + "\nemit({'id':2,'error':{'code':401,'message':'Unauthorized private-example-token'}})")
        check(!(UsageClientError.authenticationRequired.localizedDescription.contains("private-example-token")), "Do not expose server messages")
        try expectError(.serviceUnavailable, "service", body: fixture + "\nemit({'id':2,'error':{'code':-32000,'message':'private-example-token'}})")
        try expectError(.invalidResponse, "bad-json", body: fixture + "\nprint('broken',flush=True)")
        try expectError(.invalidResponse, "missing-result", body: fixture + "\nemit({'id':2,'result':None})")
        try expectError(.connectionClosed, "closed", body: "import sys\nsys.exit(0)")
        try expectError(.responseTooLarge, "large", body: fixture + "\nprint('x'*4096,flush=True)", limit: 1024)
        let start = ProcessInfo.processInfo.systemUptime
        try expectError(.timedOut, "timeout", body: fixture + "\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nwhile True: time.sleep(1)", timeout: 0.15)
        check(ProcessInfo.processInfo.systemUptime - start < 2.5, "Timeout must bound cleanup, including stubborn child")

        do {
            _ = try UsageClient(executableURL: directory.appendingPathComponent("missing")).fetch()
            fatalError("Expected missing executable")
        } catch let error as UsageClientError { check(error == .executableNotFound, "Missing executable error") }
        print("UsageClientTests: \(passed) checks passed")
    }
}
