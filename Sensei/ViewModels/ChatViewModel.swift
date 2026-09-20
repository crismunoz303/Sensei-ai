import Foundation
import FoundationModels

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage]
    @Published var draft = ""
    @Published var isThinking = false
    @Published var statusText = "CHECKING"

    private let ai = SenseiAI.shared
    private let store = ConversationStore()

    init() {
        let saved = store.load()

        if saved.isEmpty {
            messages = [
                ChatMessage(
                    role: .assistant,
                    text: "SENSEI online. I run locally on your iPhone when Apple Intelligence is available."
                )
            ]
        } else {
            messages = saved
        }

        Task {
            await refreshStatus()
        }
    }

    func refreshStatus() async {
        let available = await ai.isAvailable
        statusText = available ? "LOCAL" : "UNAVAILABLE"
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }

        draft = ""
        let priorHistory = messages
        append(ChatMessage(role: .user, text: prompt))
        isThinking = true

        Task {
            let available = await ai.isAvailable

            guard available else {
                append(
                    ChatMessage(
                        role: .assistant,
                        text: "The Apple on-device model is unavailable. Make sure this iPhone supports Apple Intelligence and Apple Intelligence is enabled."
                    )
                )
                statusText = "UNAVAILABLE"
                isThinking = false
                return
            }

            do {
                let answer = try await ai.reply(to: prompt, history: priorHistory)
                append(ChatMessage(role: .assistant, text: answer))
                statusText = "LOCAL"
            } catch {
                append(
                    ChatMessage(
                        role: .assistant,
                        text: "Local AI error: \(error.localizedDescription)"
                    )
                )
            }

            isThinking = false
        }
    }

    func clearConversation() {
        messages.removeAll()
        store.clear()

        append(
            ChatMessage(
                role: .assistant,
                text: "Conversation cleared. SENSEI is ready."
            )
        )
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        store.save(messages)
    }
}
