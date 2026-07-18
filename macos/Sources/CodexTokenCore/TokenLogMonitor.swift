import Foundation

public final class TokenLogMonitor {
    private static let tailBytes: UInt64 = 4 * 1024 * 1024
    private static let historicalOverlapBytes: UInt64 = 256 * 1024

    public let sessionRoot: String
    public var preferredThreadID: String?
    public var pinActiveSession = false

    public private(set) var activeThreadID: String?
    public private(set) var activeSessionVersion: UInt64 = 0

    private var activeLogPath: String?
    private var activeModificationDate: Date?
    private var lastFullScan = Date.distantPast
    private var lastSnapshot: TokenSnapshot?
    private var rootSessionCache: [String: Bool] = [:]

    public init(sessionRoot: String = SessionPathResolver.resolveSessions()) {
        self.sessionRoot = URL(fileURLWithPath: sessionRoot).standardizedFileURL.path
    }

    public func poll(forceFullScan: Bool = false) -> TokenSnapshot? {
        guard FileManager.default.fileExists(atPath: sessionRoot) else {
            return nil
        }

        let usePreferredThread = !pinActiveSession
            && !(preferredThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if usePreferredThread, let preferredThreadID {
            selectPreferredRootSession(threadID: preferredThreadID)
        } else if forceFullScan
                    || activeLogPath == nil
                    || Date().timeIntervalSince(lastFullScan) > 5 {
            selectNewestRootSession()
        }

        guard let activeLogPath else {
            return lastSnapshot
        }

        guard let modificationDate = modificationDate(for: activeLogPath) else {
            return lastSnapshot
        }

        if lastSnapshot != nil, modificationDate == activeModificationDate {
            return lastSnapshot
        }

        if let parsed = readLatestTokenSnapshot(path: activeLogPath, modificationDate: modificationDate) {
            // 只有完整 JSON 行成功解析后才提交文件版本，避免卡在写到一半的末行。
            activeModificationDate = modificationDate
            lastSnapshot = parsed
        }

        return lastSnapshot
    }

    private func selectPreferredRootSession(threadID: String) {
        if activeThreadID?.caseInsensitiveCompare(threadID) == .orderedSame,
           let activeLogPath,
           FileManager.default.fileExists(atPath: activeLogPath) {
            return
        }

        let suffix = "\(threadID).jsonl"
        var bestPath: String?
        var bestDate = Date.distantPast

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sessionRoot),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            switchActiveLog(path: nil, threadID: threadID)
            return
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(suffix), isRootDesktopSession(path: url.path) else {
                continue
            }

            let date = modificationDate(for: url.path) ?? Date.distantPast
            if date >= bestDate {
                bestPath = url.path
                bestDate = date
            }
        }

        switchActiveLog(path: bestPath, threadID: threadID)
    }

    private func selectNewestRootSession() {
        lastFullScan = Date()

        if pinActiveSession,
           let activeLogPath,
           FileManager.default.fileExists(atPath: activeLogPath) {
            return
        }

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sessionRoot),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var candidates: [(path: String, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension.caseInsensitiveCompare("jsonl") == .orderedSame {
            candidates.append((url.path, modificationDate(for: url.path) ?? Date.distantPast))
        }

        for candidate in candidates.sorted(by: { $0.date > $1.date }) {
            guard isRootDesktopSession(path: candidate.path) else {
                continue
            }

            if activeLogPath?.caseInsensitiveCompare(candidate.path) != .orderedSame {
                switchActiveLog(path: candidate.path, threadID: extractThreadID(path: candidate.path))
            }
            return
        }
    }

    private func isRootDesktopSession(path: String) -> Bool {
        if let cached = rootSessionCache[path] {
            return cached
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }

        do {
            guard let firstLineData = try readFirstLineData(from: handle), !firstLineData.isEmpty else {
                return false
            }

            guard let root = try JSONSerialization.jsonObject(with: firstLineData) as? [String: Any],
                  root["type"] as? String == "session_meta",
                  let payload = root["payload"] as? [String: Any]
            else {
                return false
            }

            let originator = payload["originator"] as? String
            let source = payload["source"] as? String
            let isRoot = originator?.caseInsensitiveCompare("Codex Desktop") == .orderedSame
                && source?.caseInsensitiveCompare("vscode") == .orderedSame
            rootSessionCache[path] = isRoot
            return isRoot
        } catch {
            // Created 事件可能早于首行写完，失败结果不缓存，下一轮会重试。
            return false
        }
    }

    private func readFirstLineData(
        from handle: FileHandle,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> Data? {
        var firstLine = Data()

        while firstLine.count < maximumBytes {
            let remaining = maximumBytes - firstLine.count
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty {
                return firstLine.isEmpty ? nil : firstLine
            }

            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                firstLine.append(chunk.prefix(upTo: newlineIndex))
                return firstLine
            }
            firstLine.append(chunk)
        }

        // 超大首行既不应无限分配，也不能用截断 JSON 进行错误判定。
        return nil
    }

    private func switchActiveLog(path: String?, threadID: String?) {
        if stringsEqualIgnoringCase(activeLogPath, path),
           stringsEqualIgnoringCase(activeThreadID, threadID) {
            return
        }

        activeLogPath = path
        activeThreadID = threadID
        activeModificationDate = nil
        lastSnapshot = nil
        activeSessionVersion &+= 1
    }

    private func readLatestTokenSnapshot(path: String, modificationDate: Date) -> TokenSnapshot? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let fileLength = try handle.seekToEnd()
            var blockEnd = fileLength

            while blockEnd > 0 {
                let blockStart = blockEnd > Self.tailBytes ? blockEnd - Self.tailBytes : 0
                try handle.seek(toOffset: blockStart)
                let data = try handle.read(upToCount: Int(blockEnd - blockStart)) ?? Data()
                var text = String(decoding: data, as: UTF8.self)

                if blockStart > 0 {
                    // 块首可能位于 UTF-8/JSON 行中间，丢弃第一条残缺物理行。
                    if let newline = text.firstIndex(of: "\n") {
                        text = String(text[text.index(after: newline)...])
                    } else {
                        text = ""
                    }
                }

                if let parsed = Self.parseLatestTokenSnapshot(
                    text: text,
                    path: path,
                    modificationDate: modificationDate
                ) {
                    return parsed
                }

                if blockStart == 0 {
                    break
                }
                blockEnd = min(fileLength, blockStart + Self.historicalOverlapBytes)
            }
        } catch {
            // Codex 可能正在追加或轮转日志；保留上一帧并在下一轮重试。
        }

        return nil
    }

    static func parseLatestTokenSnapshot(
        text: String,
        path: String,
        modificationDate: Date
    ) -> TokenSnapshot? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.contains("\"token_count\"") else {
                continue
            }

            do {
                guard let data = line.data(using: .utf8),
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["type"] as? String == "event_msg",
                      let payload = root["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any]
                else {
                    continue
                }

                return TokenSnapshot(
                    threadID: extractThreadID(path: path),
                    logPath: path,
                    totalTokens: integer(total["total_tokens"]),
                    inputTokens: integer(total["input_tokens"]),
                    cachedInputTokens: integer(total["cached_input_tokens"]),
                    outputTokens: integer(total["output_tokens"]),
                    reasoningOutputTokens: integer(total["reasoning_output_tokens"]),
                    contextUsedTokens: integer(last["total_tokens"]),
                    contextWindowTokens: integer(info["model_context_window"]),
                    updatedAt: modificationDate
                )
            } catch {
                // 最后一行可能尚未写完，继续寻找前一个完整快照。
            }
        }

        return nil
    }

    private static func integer(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    private static func extractThreadID(path: String) -> String {
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return fileName.count >= 36 ? String(fileName.suffix(36)) : fileName
    }

    private func extractThreadID(path: String) -> String {
        Self.extractThreadID(path: path)
    }

    private func modificationDate(for path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
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
