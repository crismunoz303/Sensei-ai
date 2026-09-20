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
        return messages
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
