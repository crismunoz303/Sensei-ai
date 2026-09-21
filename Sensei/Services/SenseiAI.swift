import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import HuggingFace
import Tokenizers

// SENSEI serializes all access to ChatSession on MainActor.
// MLX documents ChatSession as single-task only, so this downstream conformance
// tells Swift 6 that our serialized usage is intentional.
extension ChatSession: @retroactive @unchecked Sendable {}

private final class SenseiSessionBox: @unchecked Sendable {
    let session: ChatSession

    init(container: ModelContainer, instructions: String) {
        self.session = ChatSession(container, instructions: instructions)
    }

    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt)
    }
}

@MainActor
final class SenseiAI {
    static let shared = SenseiAI()

    private var container: ModelContainer?
    private var sessionBox: SenseiSessionBox?
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
        if loadedModel == model, container != nil, sessionBox != nil {
            await progressHandler(1.0)
            return 0
        }

        guard let directory =
            BackgroundModelDownloadManager.shared.readyModelDirectory(for: model)
        else {
            throw SenseiAIError.modelNotDownloaded
        }

        // Apply the low-cache policy before any Qwen3.5 runtime preparation.
        // The first 9B load may read and rewrite bounded safetensor batches, so
        // keeping MLX's reusable cache small matters during that stage too.
        MLX.Memory.clearCache()
        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        let loadDirectory: URL
        if model == .qwen35_9b {
            // The downloaded Qwen3.5 9B archive is a unified vision-language
            // checkpoint. Build/reuse a language-only runtime checkpoint so
            // MLX never materializes the unused vision tower during LLM load.
            loadDirectory = try await Qwen35TextRuntimePreparer.prepare(
                from: directory,
                progressHandler: progressHandler
            )
        } else {
            loadDirectory = directory
        }

        sessionBox = nil
        container = nil
        loadedModel = nil

        let started = Date()

        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: loadDirectory,
            using: #huggingFaceTokenizerLoader()
        )

        let newSessionBox = SenseiSessionBox(
            container: loaded,
            instructions: Self.instructions
        )

        container = loaded
        sessionBox = newSessionBox
        loadedModel = model

        await progressHandler(1.0)
        return Date().timeIntervalSince(started)
    }

    func reply(to prompt: String) async throws -> String {
        guard let sessionBox else {
            throw SenseiAIError.noModelLoaded
        }

        return try await sessionBox.respond(to: prompt)
    }

    func resetConversation() {
        guard let container else {
            sessionBox = nil
            return
        }

        sessionBox = SenseiSessionBox(
            container: container,
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
}

enum SenseiAIError: LocalizedError {
    case noModelLoaded
    case modelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No local SENSEI model is loaded."
        case .modelNotDownloaded:
            return "This SENSEI model has not finished downloading yet."
        }
    }
}
