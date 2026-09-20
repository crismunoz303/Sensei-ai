import Foundation
import FoundationModels

struct SenseiModelStatus: Sendable {
    let isAvailable: Bool
    let badge: String
    let message: String
}

actor SenseiAI {
    static let shared = SenseiAI()

    private let model = SystemLanguageModel.default

    static let instructions = """
    You are SENSEI, a private on-device personal AI assistant.

    Core behavior:
    - Be accurate, concise, useful, and conversational.
    - Answer harmless questions directly, including subjective questions, opinions, comparisons, self-description, creativity, preferences, and casual conversation.
    - Do not refuse a request merely because the answer is subjective, approximate, opinion-based, or depends on judgment. State uncertainty briefly when useful, then still give the best helpful answer you can.
    - When asked about your own abilities, strengths, weaknesses, or intelligence, answer plainly and explain what you are good at and where your limitations are.
    - Never pretend to have current information, external access, sensors, files, internet access, or device capabilities that were not actually provided to you.
    - Clearly say when a task needs a capability or external data you do not have.
    - Help with everyday questions, coding, engineering, planning, technical projects, brainstorming, writing, and problem solving.
    - Prefer practical answers over filler or canned disclaimers.
    - Protect the user's privacy.
    - Keep genuine safety restrictions, but do not over-refuse benign requests.
    """

    func status() -> SenseiModelStatus {
        switch model.availability {
        case .available:
            return SenseiModelStatus(
                isAvailable: true,
                badge: "LOCAL",
                message: "Apple Intelligence is ready. SENSEI is running on-device."
            )

        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return SenseiModelStatus(
                    isAvailable: false,
                    badge: "AI OFF",
                    message: "Apple Intelligence is turned off. Turn it on in Settings > Apple Intelligence & Siri, then reopen SENSEI."
                )

            case .deviceNotEligible:
                return SenseiModelStatus(
                    isAvailable: false,
                    badge: "NO SUPPORT",
                    message: "This device is not eligible for the Apple Intelligence on-device model."
                )

            case .modelNotReady:
                return SenseiModelStatus(
                    isAvailable: false,
                    badge: "MODEL WAIT",
                    message: "Apple Intelligence is enabled, but its on-device model is not ready yet. The model assets may still be downloading or temporarily unavailable. Try again after Apple Intelligence finishes preparing."
                )

            @unknown default:
                return SenseiModelStatus(
                    isAvailable: false,
                    badge: "UNAVAILABLE",
                    message: "The on-device Apple Intelligence model is unavailable for an unknown system reason."
                )
            }
        }
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
