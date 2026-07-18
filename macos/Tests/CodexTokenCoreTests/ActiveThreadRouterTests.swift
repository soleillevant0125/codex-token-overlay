import XCTest
@testable import CodexTokenCore

final class ActiveThreadRouterTests: XCTestCase {
    func testLatestFollowingWindowBecomesActiveAndIdleSwitchIsImmediate() throws {
        let router = ActiveThreadRouter()

        XCTAssertTrue(router.process(frame: try followingFrame(
            clientID: "client-a",
            hostID: "host-a",
            threadID: "thread-old",
            following: true
        )))
        XCTAssertEqual(router.threadID, "thread-old")

        XCTAssertTrue(router.process(frame: try followingFrame(
            clientID: "client-a",
            hostID: "host-a",
            threadID: "thread-idle",
            following: true
        )))
        XCTAssertEqual(router.threadID, "thread-idle")
        XCTAssertEqual(router.activeWindowCount, 1)
    }

    func testDisconnectRemovesOnlyMatchingClientWindows() throws {
        let router = ActiveThreadRouter()
        _ = router.process(frame: try followingFrame(
            clientID: "client-a",
            hostID: "host-a",
            threadID: "thread-a",
            following: true
        ))
        _ = router.process(frame: try followingFrame(
            clientID: "client-b",
            hostID: "host-b",
            threadID: "thread-b",
            following: true
        ))

        let disconnected: [String: Any] = [
            "type": "broadcast",
            "method": "client-status-changed",
            "params": ["status": "disconnected", "clientId": "client-b"]
        ]
        let frame = try JSONSerialization.data(withJSONObject: disconnected)
        XCTAssertTrue(router.process(frame: frame))
        XCTAssertEqual(router.threadID, "thread-a")
        XCTAssertEqual(router.activeWindowCount, 1)
    }

    func testDisconnectOfNonActiveClientStillPublishesWindowCountChange() throws {
        let router = ActiveThreadRouter()
        _ = router.process(frame: try followingFrame(
            clientID: "client-a",
            hostID: "host-a",
            threadID: "thread-a",
            following: true
        ))
        _ = router.process(frame: try followingFrame(
            clientID: "client-b",
            hostID: "host-b",
            threadID: "thread-b",
            following: true
        ))
        _ = router.process(frame: try followingFrame(
            clientID: "client-a",
            hostID: "host-a",
            threadID: "thread-a",
            following: true
        ))
        XCTAssertEqual(router.threadID, "thread-a")

        let disconnected: [String: Any] = [
            "type": "broadcast",
            "method": "client-status-changed",
            "params": ["status": "disconnected", "clientId": "client-b"]
        ]
        let frame = try JSONSerialization.data(withJSONObject: disconnected)
        XCTAssertTrue(router.process(frame: frame))
        XCTAssertEqual(router.threadID, "thread-a")
        XCTAssertEqual(router.activeWindowCount, 1)
    }

    func testSocketCandidatesRotateAfterAStaleFirstChoice() {
        let selector = SocketCandidateSelector(candidates: ["primary.sock", "legacy.sock"])
        XCTAssertEqual(selector.nextCandidate(where: { _ in true }), "primary.sock")
        XCTAssertEqual(selector.nextCandidate(where: { _ in true }), "legacy.sock")
        selector.resetToPrimary()
        XCTAssertEqual(selector.nextCandidate(where: { _ in true }), "primary.sock")
    }

    func testPreferenceSurvivesTransientNilButClearsOnDisconnect() {
        let tracker = ActiveThreadPreferenceTracker()

        XCTAssertEqual(
            tracker.preferredThreadID(for: routeStatus(threadID: "thread-a", connected: true, version: 1)),
            "thread-a"
        )
        XCTAssertEqual(
            tracker.preferredThreadID(for: routeStatus(threadID: nil, connected: true, version: 2)),
            "thread-a"
        )
        XCTAssertNil(
            tracker.preferredThreadID(for: routeStatus(threadID: nil, connected: false, version: 3))
        )
        XCTAssertNil(
            tracker.preferredThreadID(for: routeStatus(threadID: nil, connected: true, version: 4))
        )
        XCTAssertEqual(
            tracker.preferredThreadID(for: routeStatus(threadID: "thread-b", connected: true, version: 5)),
            "thread-b"
        )
    }

    private func followingFrame(
        clientID: String,
        hostID: String,
        threadID: String,
        following: Bool
    ) throws -> Data {
        let message: [String: Any] = [
            "type": "broadcast",
            "sourceClientId": clientID,
            "method": "thread-stream-following-changed",
            "params": [
                "conversationId": threadID,
                "hostId": hostID,
                "following": following
            ]
        ]
        return try JSONSerialization.data(withJSONObject: message)
    }

    private func routeStatus(
        threadID: String?,
        connected: Bool,
        version: UInt64
    ) -> ActiveThreadRouteStatus {
        ActiveThreadRouteStatus(
            threadID: threadID,
            activeWindowCount: threadID == nil ? 0 : 1,
            isConnected: connected,
            version: version,
            socketPath: connected ? "/tmp/codex.sock" : nil,
            lastError: nil
        )
    }
}
