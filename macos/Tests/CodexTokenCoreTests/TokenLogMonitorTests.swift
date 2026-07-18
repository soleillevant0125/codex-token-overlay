import XCTest
@testable import CodexTokenCore

final class TokenLogMonitorTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenOverlayMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot,
           temporaryRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path),
           temporaryRoot.lastPathComponent.hasPrefix("CodexTokenOverlayMacTests-") {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testParsesSyntheticTokenSnapshot() throws {
        let threadID = "11111111-2222-3333-4444-555555555555"
        let sessionURL = try makeSession(threadID: threadID, totalTokens: 12_345)
        let monitor = TokenLogMonitor(sessionRoot: temporaryRoot.path)

        let snapshot = monitor.poll(forceFullScan: true)

        XCTAssertEqual(snapshot?.threadID, threadID)
        XCTAssertEqual(snapshot?.totalTokens, 12_345)
        XCTAssertEqual(snapshot?.inputTokens, 10_000)
        XCTAssertEqual(snapshot?.cachedInputTokens, 7_000)
        XCTAssertEqual(snapshot?.uncachedInputTokens, 3_000)
        XCTAssertEqual(snapshot?.outputTokens, 2_345)
        XCTAssertEqual(snapshot?.reasoningOutputTokens, 345)
        XCTAssertEqual(snapshot?.contextUsedTokens, 2_048)
        XCTAssertEqual(snapshot?.contextWindowTokens, 128_000)
        XCTAssertEqual(snapshot?.logPath, sessionURL.path)
    }

    func testPreferredIdleThreadSwitchesWithoutLogUpdate() throws {
        let idleThread = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let newestThread = "11111111-2222-3333-4444-555555555555"
        let idleURL = try makeSession(threadID: idleThread, totalTokens: 1_000)
        let newestURL = try makeSession(threadID: newestThread, totalTokens: 9_000)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: idleURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: newestURL.path
        )

        let monitor = TokenLogMonitor(sessionRoot: temporaryRoot.path)
        XCTAssertEqual(monitor.poll(forceFullScan: true)?.threadID, newestThread)

        // 模拟 IPC 在界面切换到一个未继续写日志的旧任务。
        monitor.preferredThreadID = idleThread
        let idleSnapshot = monitor.poll(forceFullScan: true)
        XCTAssertEqual(idleSnapshot?.threadID, idleThread)
        XCTAssertEqual(idleSnapshot?.totalTokens, 1_000)

        // 模拟 IPC 真正断连：清除 preferred 后才退回最近根会话。
        monitor.preferredThreadID = nil
        XCTAssertEqual(monitor.poll(forceFullScan: true)?.threadID, newestThread)
    }

    func testPinnedTaskIgnoresPreferredSwitchUntilUnlocked() throws {
        let threadA = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let threadB = "11111111-2222-3333-4444-555555555555"
        let urlA = try makeSession(threadID: threadA, totalTokens: 1_000)
        let urlB = try makeSession(threadID: threadB, totalTokens: 2_000)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: urlA.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: urlB.path
        )

        let monitor = TokenLogMonitor(sessionRoot: temporaryRoot.path)
        XCTAssertEqual(monitor.poll(forceFullScan: true)?.threadID, threadA)

        monitor.pinActiveSession = true
        monitor.preferredThreadID = threadB
        XCTAssertEqual(monitor.poll(forceFullScan: true)?.threadID, threadA)

        monitor.pinActiveSession = false
        XCTAssertEqual(monitor.poll(forceFullScan: true)?.threadID, threadB)
    }

    func testSessionPathResolverHonorsCodexHomeAndExplicitSessions() {
        let home = temporaryRoot.appendingPathComponent("home").path
        let codexHome = temporaryRoot.appendingPathComponent("custom-codex").path

        XCTAssertEqual(
            SessionPathResolver.resolveSessions(
                arguments: ["app"],
                environment: ["CODEX_HOME": codexHome],
                homeDirectory: home
            ),
            URL(fileURLWithPath: codexHome).appendingPathComponent("sessions").path
        )

        let explicit = temporaryRoot.appendingPathComponent("explicit-sessions").path
        XCTAssertEqual(
            SessionPathResolver.resolveSessions(
                arguments: ["app", "--sessions", explicit],
                environment: [:],
                homeDirectory: home
            ),
            explicit
        )
    }

    func testRejectsNonDesktopRootSession() throws {
        let threadID = "99999999-8888-7777-6666-555555555555"
        let sessionURL = temporaryRoot
            .appendingPathComponent("rollout-2026-07-18T00-00-00-\(threadID).jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"originator":"Codex CLI","source":"exec"}}"#,
            tokenEvent(totalTokens: 100)
        ]
        try lines.joined(separator: "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        let monitor = TokenLogMonitor(sessionRoot: temporaryRoot.path)
        XCTAssertNil(monitor.poll(forceFullScan: true))
    }

    func testAcceptsSessionMetadataLongerThan64KiB() throws {
        let threadID = "12345678-1234-5678-9012-123456789012"
        let directory = temporaryRoot.appendingPathComponent("sessions/2026/07/18", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionURL = directory
            .appendingPathComponent("rollout-2026-07-18T00-00-00-\(threadID).jsonl")

        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "padding": String(repeating: "x", count: 80 * 1024),
                "originator": "Codex Desktop",
                "source": "vscode"
            ]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var sessionData = metadataData
        sessionData.append(0x0A)
        sessionData.append(tokenEvent(totalTokens: 88_000).data(using: .utf8)!)
        try sessionData.write(to: sessionURL)

        let monitor = TokenLogMonitor(sessionRoot: temporaryRoot.path)
        XCTAssertEqual(monitor.poll(forceFullScan: true)?.totalTokens, 88_000)
    }

    func testDamagedTailKeepsPreviousCompleteTokenSnapshot() throws {
        let threadID = "11111111-2222-3333-4444-555555555555"
        let sessionURL = try makeSession(threadID: threadID, totalTokens: 12_345)
        let damagedTail = "\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":"
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(damagedTail.utf8))
        try handle.close()

        let monitor = TokenLogMonitor(sessionRoot: temporaryRoot.path)
        XCTAssertEqual(monitor.poll(forceFullScan: true)?.totalTokens, 12_345)
    }

    func testDerivedMetricsAreClamped() {
        let snapshot = TokenSnapshot(
            threadID: "thread",
            logPath: "/tmp/log.jsonl",
            totalTokens: 10,
            inputTokens: 5,
            cachedInputTokens: 9,
            outputTokens: 1,
            reasoningOutputTokens: 0,
            contextUsedTokens: 200,
            contextWindowTokens: 100,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.uncachedInputTokens, 0)
        XCTAssertEqual(snapshot.contextPercent, 100)
    }

    @discardableResult
    private func makeSession(threadID: String, totalTokens: Int64) throws -> URL {
        let directory = temporaryRoot.appendingPathComponent("sessions/2026/07/18", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionURL = directory
            .appendingPathComponent("rollout-2026-07-18T00-00-00-\(threadID).jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode"}}"#,
            tokenEvent(totalTokens: totalTokens)
        ]
        try lines.joined(separator: "\n").write(to: sessionURL, atomically: true, encoding: .utf8)
        return sessionURL
    }

    private func tokenEvent(totalTokens: Int64) -> String {
        """
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(totalTokens),"input_tokens":10000,"cached_input_tokens":7000,"output_tokens":2345,"reasoning_output_tokens":345},"last_token_usage":{"total_tokens":2048},"model_context_window":128000}}}
        """
    }
}
