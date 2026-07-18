import Foundation
import CodexTokenCore

struct DisplayField: OptionSet, Hashable {
    let rawValue: Int

    static let total = DisplayField(rawValue: 1 << 0)
    static let input = DisplayField(rawValue: 1 << 1)
    static let output = DisplayField(rawValue: 1 << 2)
    static let cacheHit = DisplayField(rawValue: 1 << 3)
    static let cacheMiss = DisplayField(rawValue: 1 << 4)
    static let context = DisplayField(rawValue: 1 << 5)
    static let contextPercent = DisplayField(rawValue: 1 << 6)
    static let reasoning = DisplayField(rawValue: 1 << 7)
    static let thread = DisplayField(rawValue: 1 << 8)

    static let ordered: [DisplayField] = [
        .total,
        .input,
        .output,
        .cacheHit,
        .cacheMiss,
        .context,
        .contextPercent,
        .reasoning,
        .thread
    ]

    static let allFields: DisplayField = DisplayField.ordered.reduce([]) { $0.union($1) }

    static let defaultFields: DisplayField = [
        .total,
        .input,
        .output,
        .cacheHit,
        .cacheMiss,
        .context,
        .contextPercent
    ]
}

enum TokenFormatter {
    static func compact(_ value: Int64) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.2fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
        }
    }

    static func shortThreadID(_ threadID: String) -> String {
        guard threadID.count > 12 else {
            return threadID
        }
        return "\(threadID.prefix(4))…\(threadID.suffix(6))"
    }

    static func statusTitle(snapshot: TokenSnapshot, fields: DisplayField) -> String {
        var values: [String] = []

        append(.total, L10n.fieldValue(.total, compact(snapshot.totalTokens)))
        append(.input, L10n.fieldValue(.input, compact(snapshot.inputTokens)))
        append(.output, L10n.fieldValue(.output, compact(snapshot.outputTokens)))
        append(.cacheHit, L10n.fieldValue(.cacheHit, compact(snapshot.cachedInputTokens)))
        append(.cacheMiss, L10n.fieldValue(.cacheMiss, compact(snapshot.uncachedInputTokens)))
        append(
            .context,
            L10n.fieldValue(
                .context,
                "\(compact(snapshot.contextUsedTokens))/\(compact(snapshot.contextWindowTokens))"
            )
        )
        append(.contextPercent, String(format: "%.0f%%", snapshot.contextPercent))
        append(.reasoning, L10n.fieldValue(.reasoning, compact(snapshot.reasoningOutputTokens)))
        append(.thread, L10n.fieldValue(.thread, shortThreadID(snapshot.threadID)))

        return values.joined(separator: " · ")

        func append(_ field: DisplayField, _ value: String) {
            if fields.contains(field) {
                values.append(value)
            }
        }
    }

    static func fullSummary(snapshot: TokenSnapshot) -> String {
        [
            L10n.fieldValue(.total, compact(snapshot.totalTokens)),
            L10n.fieldValue(.input, compact(snapshot.inputTokens)),
            L10n.fieldValue(.output, compact(snapshot.outputTokens)),
            L10n.fieldValue(.cacheHit, compact(snapshot.cachedInputTokens)),
            L10n.fieldValue(.cacheMiss, compact(snapshot.uncachedInputTokens)),
            L10n.fieldValue(
                .context,
                "\(compact(snapshot.contextUsedTokens))/\(compact(snapshot.contextWindowTokens))"
            ),
            String(format: "%.0f%%", snapshot.contextPercent),
            L10n.fieldValue(.reasoning, compact(snapshot.reasoningOutputTokens))
        ].joined(separator: " · ")
    }
}
