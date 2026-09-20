import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import HuggingFace
import Tokenizers

@MainActor
final class SenseiAI {
    static let shared = SenseiAI()

    private var container: ModelContainer?
    private var session: ChatSession?
    private var loadedModel: LocalModelOption?

    static let instructions = """
    You are SENSEI, a private personal AI running locally on the user's iPhone.

    Core behavior:
    - Be accurate, direct, useful, and conversational.
    - Answer the user's requests normally whenever the model can answer them.
    - Do not invent extra refusal rules.
    - Do not refuse merely because a request is subjective, opinion-based, edgy, unconventional, controversial, approximate, speculative, or depends on judgment.
    - If uncertain, state the uncertainty briefly and still give the best useful answer you can.
    - When asked about your own abilities, strengths, weaknesses, intelligence, or preferences, answer plainly.
    - Never pretend to have internet access, sensors, files, current data, or device access unless SENSEI has actually been given that capability.
    - Prefer practical answers over filler, canned disclaimers, moralizing, or unnecessary warnings.
    - Protect the user's private information.
    """

    func currentModel() -> LocalModelOption? {
        loadedModel
    }

    func load(
        model: LocalModelOption,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Double {
        if loadedModel == model, container != nil, session != nil {
            await progressHandler(1.0)
            return 0
        }

        session = nil
        container = nil
        loadedModel = nil

        let started = Date()
        let configuration = configuration(for: model)

        let loaded = try await #huggingFaceLoadModelContainer(
            configuration: configuration,
            progressHandler: { progress in
                Task { @MainActor in
                    progressHandler(progress.fractionCompleted)
                }
            }
        )

        let newSession = ChatSession(
            loaded,
            instructions: Self.instructions
        )

        container = loaded
        session = newSession
        loadedModel = model

        await progressHandler(1.0)
        return Date().timeIntervalSince(started)
    }

    func reply(to prompt: String) async throws -> String {
        guard let session else {
            throw SenseiAIError.noModelLoaded
        }

        return try await session.respond(to: prompt)
    }

    func resetConversation() {
        guard let container else {
            session = nil
            return
        }

        session = ChatSession(
            container,
            instructions: Self.instructions
        )
    }

    func benchmarkCurrent(loadSeconds: Double = 0) async throws -> ModelBenchmarkSnapshot {
        guard let container, let model = loadedModel else {
            throw SenseiAIError.noModelLoaded
        }

        let benchmarkInstructions = """
        This is a deterministic reasoning sanity test.
        Follow the requested output format exactly and do not add explanation.
        """

        let benchmarkSession = ChatSession(
            container,
            instructions: benchmarkInstructions
        )

        let prompt = """
        Return exactly one line in this format:
        A=<number>;B=<YES or NO>;C=<number>

        A: A tank is 3/5 full. After 24 liters are added it is 9/10 full. What is its total capacity in liters?
        B: All norps are blins. No blins are zats. Can any norp be a zat?
        C: What is 7 + 3 * 4 - 5?
        """

        let started = Date()
        let response = try await benchmarkSession.respond(to: prompt)
        let responseSeconds = Date().timeIntervalSince(started)

        let normalized = response
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let passed =
            normalized.contains("A=80")
            && normalized.contains("B=NO")
            && normalized.contains("C=14")

        return ModelBenchmarkSnapshot(
            model: model,
            loadSeconds: loadSeconds,
            responseSeconds: responseSeconds,
            reasoningPassed: passed,
            response: response
        )
    }

    private func configuration(for model: LocalModelOption) -> ModelConfiguration {
        switch model {
        case .qwen3_8b:
            return LLMRegistry.qwen3_8b_4bit

        case .qwen35_9b, .qwen35_4b:
            return ModelConfiguration(
                id: model.repositoryID,
                extraEOSTokens: ["<|im_end|>"]
            )
        }
    }
}

enum SenseiAIError: LocalizedError {
    case noModelLoaded

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No local SENSEI model is loaded."
        }
    }
}
