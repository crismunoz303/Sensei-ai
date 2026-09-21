import Foundation

final class ConversationStore {
    private let key = "sensei.chat.messages.v2"
    private let defaults = UserDefaults.standard

    func load() -> [ChatMessage] {
        guard
            let data = defaults.data(forKey: key),
            let messages = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else {
            return []
        }

        // Persisted assistant output from older builds may contain Qwen reasoning.
        // Only remove output when there is objective evidence that it is a reasoning
        // transcript. Normal assistant answers and every user message are preserved.
        let sanitized = messages.compactMap(Self.sanitized)
        if sanitized != messages {
            save(sanitized)
        }
        return sanitized
    }

    private static func sanitized(_ message: ChatMessage) -> ChatMessage? {
        guard message.role == .assistant else { return message }

        var text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let close = text.range(of: "</think>", options: .caseInsensitive) {
            text = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let open = text.range(of: "<think>", options: .caseInsensitive) {
            let beforeThink = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // An opening think tag without a closing tag has no trustworthy final
            // answer after it. Keep only genuine text that preceded the tag.
            guard !beforeThink.isEmpty else { return nil }
            text = beforeThink
        }

        if let final = reliableFinalAnswer(in: text) {
            text = final
        } else if isKnownReasoningTranscript(text) {
            // Do not guess where an untagged reasoning transcript ends. If an older
            // build did not provide a reliable final-answer boundary, remove that
            // assistant message instead of exposing private scratch work.
            return nil
        }

        guard !text.isEmpty else { return nil }
        return ChatMessage(id: message.id, role: message.role, text: text, createdAt: message.createdAt)
    }

    private static func reliableFinalAnswer(in text: String) -> String? {
        // Prefer the most explicit marker first so "Answer:" inside
        // "Final Answer:" cannot win accidentally.
        for marker in ["Final Answer:", "Final:", "Answer:"] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let candidate = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return String(candidate) }
            }
        }
        return nil
    }

    private static func isKnownReasoningTranscript(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("thinking process:")
    }

    func save(_ messages: [ChatMessage]) {
        let trimmed = Array(messages.suffix(100))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
