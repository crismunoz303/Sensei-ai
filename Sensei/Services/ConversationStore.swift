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
        let sanitized = messages.map(Self.sanitized)
        if sanitized != messages {
            save(sanitized)
        }
        return sanitized
    }

    private static func sanitized(_ message: ChatMessage) -> ChatMessage {
        guard message.role == .assistant else { return message }

        var text = message.text
        if let close = text.range(of: "</think>", options: .caseInsensitive) {
            text = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let open = text.range(of: "<think>", options: .caseInsensitive) {
            text = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for marker in ["Answer:", "Final Answer:", "Final:"] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let candidate = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { text = String(candidate) }
                break
            }
        }

        return ChatMessage(id: message.id, role: message.role, text: text, createdAt: message.createdAt)
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
