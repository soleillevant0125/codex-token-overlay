import Foundation

public struct TokenSnapshot: Codable, Equatable, Sendable {
    public let threadID: String
    public let logPath: String
    public let totalTokens: Int64
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let contextUsedTokens: Int64
    public let contextWindowTokens: Int64
    public let updatedAt: Date

    public init(
        threadID: String,
        logPath: String,
        totalTokens: Int64,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        contextUsedTokens: Int64,
        contextWindowTokens: Int64,
        updatedAt: Date
    ) {
        self.threadID = threadID
        self.logPath = logPath
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.contextUsedTokens = contextUsedTokens
        self.contextWindowTokens = contextWindowTokens
        self.updatedAt = updatedAt
    }

    public var uncachedInputTokens: Int64 {
        max(0, inputTokens - cachedInputTokens)
    }

    public var contextPercent: Double {
        guard contextWindowTokens > 0 else {
            return 0
        }
        return min(100, max(0, Double(contextUsedTokens) * 100 / Double(contextWindowTokens)))
    }
}
