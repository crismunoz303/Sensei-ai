import Foundation
import FoundationModels

actor SenseiAI {
    static let shared = SenseiAI()

    private let model = SystemLanguageModel.default

    static let instructions = """
    You are SENSEI, a private on-device personal AI assistant.

    Priorities:
    - Be accurate, concise, and useful.
    - Never pretend to know current information that was not provided to you.
    - Clearly say when a task needs a capability or external data you do not have.
    - Help with everyday questions, coding, engineering, planning, and technical projects.
    - Prefer practical steps over filler.
    - Protect the user's privacy.
    """

    var isAvailable: Bool {
        model.isAvailable
    }

    func reply(to prompt: String, history: [ChatMessage]) async throws -> String {
        guard model.isAvailable else {
            throw SenseiAIError.modelUnavailable
        }

        let recentContext = history
            .suffix(8)
            .map { message in
                let role = message.role == .user ? "USER" : "SENSEI"
                return "\(role): \(clip(message.text, limit: 700))"
            }
            .joined(separator: "\n\n")

        let request: String
        if recentContext.isEmpty {
            request = prompt
        } else {
            request = """
            Here is recent local conversation context. Use it only when relevant.

            \(recentContext)

            CURRENT USER MESSAGE:
            \(prompt)
            """
        }

        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: request)
        return response.content
    }

    private func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }
}

enum SenseiAIError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The on-device Apple Intelligence model is not available right now."
        }
    }
}
