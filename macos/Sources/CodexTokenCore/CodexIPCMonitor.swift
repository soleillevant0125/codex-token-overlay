import Foundation
import Network
import Darwin

public struct ActiveThreadRouteStatus: Equatable, Sendable {
    public let threadID: String?
    public let activeWindowCount: Int
    public let isConnected: Bool
    public let version: UInt64
    public let socketPath: String?
    public let lastError: String?

    public init(
        threadID: String?,
        activeWindowCount: Int,
        isConnected: Bool,
        version: UInt64,
        socketPath: String?,
        lastError: String?
    ) {
        self.threadID = threadID
        self.activeWindowCount = activeWindowCount
        self.isConnected = isConnected
        self.version = version
        self.socketPath = socketPath
        self.lastError = lastError
    }
}

public final class ActiveThreadPreferenceTracker {
    private var lastKnownThreadID: String?

    public init() {}

    public func preferredThreadID(for status: ActiveThreadRouteStatus) -> String? {
        guard status.isConnected else {
            // 真正断连后必须允许日志监视器退回最近根会话。
            lastKnownThreadID = nil
            return nil
        }

        if let threadID = status.threadID {
            lastKnownThreadID = threadID
        }
        // following=false 与下一条 following=true 之间保留旧任务，避免短暂跳错日志。
        return status.threadID ?? lastKnownThreadID
    }
}

final class ActiveThreadRouter {
    private struct ActiveConversation {
        let threadID: String
        let sequence: UInt64
    }

    private var activeByWindow: [String: ActiveConversation] = [:]
    private var sequence: UInt64 = 0

    private(set) var threadID: String?
    private(set) var version: UInt64 = 0

    var activeWindowCount: Int {
        activeByWindow.count
    }

    func reset() {
        activeByWindow.removeAll()
        threadID = nil
        version &+= 1
    }

    @discardableResult
    func process(frame: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              root["type"] as? String == "broadcast",
              let method = root["method"] as? String,
              let parameters = root["params"] as? [String: Any]
        else {
            return false
        }

        if method == "client-status-changed" {
            return processClientStatusChanged(parameters)
        }

        guard method == "thread-stream-following-changed",
              let conversationID = parameters["conversationId"] as? String,
              let hostID = parameters["hostId"] as? String,
              let following = parameters["following"] as? Bool,
              let sourceClientID = root["sourceClientId"] as? String,
              !conversationID.isEmpty,
              !hostID.isEmpty,
              !sourceClientID.isEmpty
        else {
            return false
        }

        let key = "\(sourceClientID)\u{001F}\(hostID)"
        var mappingChanged = false
        if following {
            sequence &+= 1
            activeByWindow[key] = ActiveConversation(threadID: conversationID, sequence: sequence)
            mappingChanged = true
        } else if activeByWindow[key]?.threadID.caseInsensitiveCompare(conversationID) == .orderedSame {
            activeByWindow.removeValue(forKey: key)
            mappingChanged = true
        }

        let threadChanged = recomputeActiveThread()
        if mappingChanged && !threadChanged {
            version &+= 1
        }
        return mappingChanged || threadChanged
    }

    private func processClientStatusChanged(_ parameters: [String: Any]) -> Bool {
        guard parameters["status"] as? String == "disconnected",
              let clientID = parameters["clientId"] as? String,
              !clientID.isEmpty
        else {
            return false
        }

        let keyPrefix = "\(clientID)\u{001F}"
        let removedKeys = activeByWindow.keys.filter { $0.hasPrefix(keyPrefix) }
        guard !removedKeys.isEmpty else {
            return false
        }

        for key in removedKeys {
            activeByWindow.removeValue(forKey: key)
        }
        let threadChanged = recomputeActiveThread()
        if !threadChanged {
            version &+= 1
        }
        return true
    }

    private func recomputeActiveThread() -> Bool {
        let nextThreadID = activeByWindow.values.max(by: { $0.sequence < $1.sequence })?.threadID
        guard !stringsEqualIgnoringCase(nextThreadID, threadID) else {
            return false
        }

        threadID = nextThreadID
        version &+= 1
        return true
    }

    private func stringsEqualIgnoringCase(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.caseInsensitiveCompare(right) == .orderedSame
        default:
            return false
        }
    }
}

final class SocketCandidateSelector {
    private let candidates: [String]
    private var nextIndex = 0

    init(candidates: [String]) {
        self.candidates = candidates
    }

    func nextCandidate(where isUsable: (String) -> Bool) -> String? {
        guard !candidates.isEmpty else {
            return nil
        }

        for offset in 0..<candidates.count {
            let index = (nextIndex + offset) % candidates.count
            let candidate = candidates[index]
            if isUsable(candidate) {
                // 连接失败后的下一轮会继续尝试后续候选，避免残留主 Socket 阻塞回退。
                nextIndex = (index + 1) % candidates.count
                return candidate
            }
        }
        return nil
    }

    func resetToPrimary() {
        nextIndex = 0
    }
}

public final class CodexIPCActiveThreadMonitor {
    private static let maximumWireFrameBytes = 256 * 1024 * 1024
    private static let maximumJSONFrameBytes = 4 * 1024 * 1024

    private let socketSelector: SocketCandidateSelector
    private let queue = DispatchQueue(label: "io.github.soleillevant0125.CodexTokenOverlay.ipc")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let statusLock = NSLock()
    private let router = ActiveThreadRouter()

    private var connection: NWConnection?
    private var generation = UUID()
    private var receiveBuffer = Data()
    private var expectedFrameLength: Int?
    private var discardBytesRemaining = 0
    private var reconnectAttempt = 0
    private var stopped = false

    private var currentStatus = ActiveThreadRouteStatus(
        threadID: nil,
        activeWindowCount: 0,
        isConnected: false,
        version: 0,
        socketPath: nil,
        lastError: nil
    )

    public init(socketCandidates: [String] = SessionPathResolver.ipcSocketCandidates()) {
        socketSelector = SocketCandidateSelector(candidates: socketCandidates)
        queue.setSpecific(key: queueKey, value: true)
        queue.async { [weak self] in
            self?.connect()
        }
    }

    deinit {
        stop()
    }

    public func status() -> ActiveThreadRouteStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return currentStatus
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopOnQueue()
        } else {
            queue.sync {
                self.stopOnQueue()
            }
        }
    }

    private func stopOnQueue() {
        guard !stopped else {
            return
        }
        stopped = true
        connection?.cancel()
        connection = nil
    }

    private func connect() {
        guard !stopped else {
            return
        }

        guard let socketPath = selectSocketPath() else {
            publishDisconnected(error: "Codex IPC Socket 尚未出现", socketPath: nil)
            scheduleReconnect()
            return
        }

        let nextGeneration = UUID()
        generation = nextGeneration
        receiveBuffer.removeAll(keepingCapacity: true)
        expectedFrameLength = nil
        discardBytesRemaining = 0

        let nextConnection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection = nextConnection
        nextConnection.stateUpdateHandler = { [weak self, weak nextConnection] state in
            guard let self, let nextConnection else {
                return
            }
            self.handleState(
                state,
                connection: nextConnection,
                socketPath: socketPath,
                generation: nextGeneration
            )
        }
        nextConnection.start(queue: queue)
    }

    private func handleState(
        _ state: NWConnection.State,
        connection: NWConnection,
        socketPath: String,
        generation: UUID
    ) {
        guard !stopped, self.generation == generation, self.connection === connection else {
            return
        }

        switch state {
        case .ready:
            reconnectAttempt = 0
            socketSelector.resetToPrimary()
            router.reset()
            publishConnected(socketPath: socketPath)
            sendInitialize(connection: connection, generation: generation)
            receiveNext(connection: connection, socketPath: socketPath, generation: generation)
        case .waiting(let error), .failed(let error):
            disconnect(
                connection: connection,
                socketPath: socketPath,
                generation: generation,
                error: error.localizedDescription
            )
        case .cancelled:
            if !stopped {
                disconnect(
                    connection: connection,
                    socketPath: socketPath,
                    generation: generation,
                    error: nil
                )
            }
        default:
            break
        }
    }

    private func sendInitialize(connection: NWConnection, generation: UUID) {
        let request: [String: Any] = [
            "type": "request",
            "requestId": UUID().uuidString,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": ["clientType": "codex-token-overlay"]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: request),
              payload.count <= Self.maximumJSONFrameBytes
        else {
            disconnect(
                connection: connection,
                socketPath: nil,
                generation: generation,
                error: "无法编码 Codex IPC 初始化消息"
            )
            return
        }

        var littleEndianLength = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &littleEndianLength, count: MemoryLayout<UInt32>.size)
        frame.append(payload)

        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, let error else {
                return
            }
            self.queue.async {
                self.disconnect(
                    connection: connection,
                    socketPath: nil,
                    generation: generation,
                    error: error.localizedDescription
                )
            }
        })
    }

    private func receiveNext(connection: NWConnection, socketPath: String, generation: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }

            guard !self.stopped,
                  self.generation == generation,
                  self.connection === connection
            else {
                return
            }

            if let data, !data.isEmpty {
                do {
                    try self.processReceivedBytes(data)
                } catch {
                    self.disconnect(
                        connection: connection,
                        socketPath: socketPath,
                        generation: generation,
                        error: error.localizedDescription
                    )
                    return
                }
            }

            if let error {
                self.disconnect(
                    connection: connection,
                    socketPath: socketPath,
                    generation: generation,
                    error: error.localizedDescription
                )
            } else if isComplete {
                self.disconnect(
                    connection: connection,
                    socketPath: socketPath,
                    generation: generation,
                    error: nil
                )
            } else {
                self.receiveNext(connection: connection, socketPath: socketPath, generation: generation)
            }
        }
    }

    private func processReceivedBytes(_ data: Data) throws {
        receiveBuffer.append(data)

        while true {
            if discardBytesRemaining > 0 {
                let discarded = min(discardBytesRemaining, receiveBuffer.count)
                receiveBuffer.removeFirst(discarded)
                discardBytesRemaining -= discarded
                if discardBytesRemaining > 0 {
                    return
                }
                continue
            }

            if expectedFrameLength == nil {
                guard receiveBuffer.count >= MemoryLayout<UInt32>.size else {
                    return
                }

                let wireLength = receiveBuffer.prefix(4).enumerated().reduce(UInt32(0)) { partial, pair in
                    partial | (UInt32(pair.element) << UInt32(pair.offset * 8))
                }
                receiveBuffer.removeFirst(4)
                let frameLength = Int(wireLength)

                guard frameLength > 0, frameLength <= Self.maximumWireFrameBytes else {
                    throw IPCMonitorError.invalidFrameLength(frameLength)
                }

                if frameLength > Self.maximumJSONFrameBytes {
                    discardBytesRemaining = frameLength
                    continue
                }
                expectedFrameLength = frameLength
            }

            guard let expectedFrameLength, receiveBuffer.count >= expectedFrameLength else {
                return
            }

            let frame = Data(receiveBuffer.prefix(expectedFrameLength))
            receiveBuffer.removeFirst(expectedFrameLength)
            self.expectedFrameLength = nil

            if router.process(frame: frame) {
                publishConnected(socketPath: status().socketPath)
            }
        }
    }

    private func disconnect(
        connection: NWConnection,
        socketPath: String?,
        generation: UUID,
        error: String?
    ) {
        guard self.generation == generation, self.connection === connection else {
            return
        }

        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        router.reset()
        publishDisconnected(error: error, socketPath: socketPath)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else {
            return
        }

        let exponent = min(reconnectAttempt, 4)
        let delayMilliseconds = min(5_000, 350 * (1 << exponent))
        reconnectAttempt += 1
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            self?.connect()
        }
    }

    private func selectSocketPath() -> String? {
        socketSelector.nextCandidate { path in
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                return false
            }

            let fileType = metadata.st_mode & mode_t(S_IFMT)
            guard fileType == mode_t(S_IFSOCK), metadata.st_uid == getuid() else {
                return false
            }

            // 回退目录必须仍由当前用户独占，避免连接到可被其他用户替换的 Socket。
            var directoryMetadata = stat()
            let directoryPath = (path as NSString).deletingLastPathComponent
            guard lstat(directoryPath, &directoryMetadata) == 0,
                  directoryMetadata.st_uid == getuid(),
                  directoryMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                return false
            }
            let unsafeWriteBits = mode_t(S_IWGRP) | mode_t(S_IWOTH)
            return directoryMetadata.st_mode & unsafeWriteBits == 0
        }
    }

    private func publishConnected(socketPath: String?) {
        updateStatus(
            threadID: router.threadID,
            activeWindowCount: router.activeWindowCount,
            isConnected: true,
            socketPath: socketPath,
            lastError: nil
        )
    }

    private func publishDisconnected(error: String?, socketPath: String?) {
        updateStatus(
            threadID: nil,
            activeWindowCount: 0,
            isConnected: false,
            socketPath: socketPath,
            lastError: error
        )
    }

    private func updateStatus(
        threadID: String?,
        activeWindowCount: Int,
        isConnected: Bool,
        socketPath: String?,
        lastError: String?
    ) {
        statusLock.lock()
        let changed = !stringsEqualIgnoringCase(currentStatus.threadID, threadID)
            || currentStatus.activeWindowCount != activeWindowCount
            || currentStatus.isConnected != isConnected
            || currentStatus.socketPath != socketPath
            || currentStatus.lastError != lastError

        currentStatus = ActiveThreadRouteStatus(
            threadID: threadID,
            activeWindowCount: activeWindowCount,
            isConnected: isConnected,
            version: changed ? currentStatus.version &+ 1 : currentStatus.version,
            socketPath: socketPath,
            lastError: lastError
        )
        statusLock.unlock()
    }

    private func stringsEqualIgnoringCase(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.caseInsensitiveCompare(right) == .orderedSame
        default:
            return false
        }
    }
}

private enum IPCMonitorError: LocalizedError {
    case invalidFrameLength(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFrameLength(let length):
            return "Codex IPC 帧长度无效：\(length)"
        }
    }
}
