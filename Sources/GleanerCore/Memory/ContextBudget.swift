import Foundation

/// How much text a conversation with the model may carry, from the model's context length.
/// Counted in characters at about one token each, which is close for Chinese and generous for
/// English, leaving room for instructions and the answer.
public struct ContextBudget: Equatable, Sendable {
    /// Characters of file text sent with one question, shared among its files.
    public var attachments: Int
    /// Characters a whole request may reach before older turns' attachments are left out.
    public var conversation: Int

    public init(attachments: Int, conversation: Int) {
        self.attachments = attachments
        self.conversation = conversation
    }

    public init(contextTokens: Int) {
        self.init(attachments: min(60_000, contextTokens * 3 / 10), conversation: contextTokens * 3 / 4)
    }

    /// Shares `total` characters among texts of `lengths`: each gets an even share at most, and
    /// what shorter texts leave unused goes to the longer ones.
    public static func allocate(_ lengths: [Int], total: Int) -> [Int] {
        var result = Array(repeating: 0, count: lengths.count)
        var remaining = max(0, total)
        var open = lengths.indices.sorted { lengths[$0] < lengths[$1] }
        while !open.isEmpty {
            let share = remaining / open.count
            let index = open.removeFirst()
            let amount = min(lengths[index], share)
            result[index] = amount
            remaining -= amount
        }
        return result
    }
}

extension ProviderConfiguration {
    /// The model's context length in tokens: as set, or estimated conservatively.
    public var contextTokens: Int {
        if let contextK, contextK > 0 { return contextK * 1_000 }
        return estimatedContextK * 1_000
    }

    /// A guess at the context length in thousands of tokens, used unless the user sets one.
    public var estimatedContextK: Int {
        if isLocal { return 32 }
        if apiProtocol == .anthropic { return 200 }
        if secretAccount.lowercased().hasSuffix("deepseek.com") { return 256 }
        return 128
    }

    public var contextBudget: ContextBudget { ContextBudget(contextTokens: contextTokens) }
}
