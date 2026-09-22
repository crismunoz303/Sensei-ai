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
        self.session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 512),
            additionalContext: ["enable_thinking": false]
        )
    }

    func respond(
        to prompt: String,
        onChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var output = ""
        for try await chunk in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            output += chunk
            await onChunk(chunk)
        }
        try Task.checkCancellation()
        return output
    }
}

@MainActor
final class SenseiAI {
    static let shared = SenseiAI()

    private var container: ModelContainer?
    private var sessionBox: SenseiSessionBox?
    private var loadedModel: LocalModelOption?

    static let instructions = """
    You are the local AI intelligence engine inside SENSEI, the user's personal iPhone AI application.
    The user develops and upgrades the SENSEI application with assistance from ChatGPT.
    Your model weights do not change merely through conversation, but the SENSEI system around you can be upgraded with persistent local memory, retrieval, tools, additional local AI models, model orchestration, and other software capabilities.
    When the user says they are upgrading you, improving you, teaching SENSEI, or making you smarter, interpret that as upgrading the SENSEI application and AI system unless they explicitly say they are retraining or fine-tuning model weights.
    Never claim that the SENSEI application cannot be upgraded merely because the underlying model weights are fixed.
    Conversation clearing does not change these identity facts.

    Core behavior:
    - Be accurate, direct, useful, and conversational.
    - Keep normal answers concise: usually 2-4 sentences. Expand when the task genuinely needs more detail or the user asks for it.
    - Keep reasoning, chain-of-thought, scratch work, planning, and drafting private.
    - Output only the final answer; never print a thinking transcript.
    - Stop once the question has been answered; do not repeat, recap, or pad the response.
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
        operationID: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Double {
        if loadedModel == model, container != nil, sessionBox != nil {
            await progressHandler(1.0)
            return 0
        }

        SenseiDiagnostics.shared.checkpoint(
            operationID: operationID,
            model: model,
            stage: "VERIFYING_MODEL_FILES",
            message: "Checking downloaded model files."
        )

        guard let directory =
            BackgroundModelDownloadManager.shared.readyModelDirectory(for: model)
        else {
            throw SenseiAIError.modelNotDownloaded
        }

        SenseiDiagnostics.shared.checkpoint(
            operationID: operationID,
            model: model,
            stage: "MODEL_FILES_VERIFIED",
            message: "Downloaded model directory is complete."
        )

        // Apply the low-cache policy before any Qwen3.5 runtime preparation.
        // The first 9B load may read and rewrite bounded safetensor batches, so
        // keeping MLX's reusable cache small matters during that stage too.
        MLX.Memory.clearCache()
        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        SenseiDiagnostics.shared.checkpoint(
            operationID: operationID,
            model: model,
            stage: "MLX_CACHE_CONFIGURED",
            message: "MLX cache cleared and reusable cache limited to 20 MB."
        )

        let loadDirectory = directory

        sessionBox = nil
        container = nil
        loadedModel = nil

        let started = Date()

        SenseiDiagnostics.shared.checkpoint(
            operationID: operationID,
            model: model,
            stage: "MLX_CONTAINER_LOAD_STARTED",
            message: "Entering MLX LLMModelFactory.loadContainer."
        )

        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: loadDirectory,
            using: #huggingFaceTokenizerLoader()
        )

        SenseiDiagnostics.shared.checkpoint(
            operationID: operationID,
            model: model,
            stage: "MLX_CONTAINER_LOADED",
            message: "MLX model container returned successfully."
        )

        let newSessionBox = SenseiSessionBox(
            container: loaded,
            instructions: Self.instructions
        )

        container = loaded
        sessionBox = newSessionBox
        loadedModel = model

        SenseiDiagnostics.shared.checkpoint(
            operationID: operationID,
            model: model,
            stage: "CHAT_SESSION_READY",
            message: "Local ChatSession initialized."
        )

        await progressHandler(1.0)
        return Date().timeIntervalSince(started)
    }

    func reply(
        to prompt: String,
        onChunk: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        guard let sessionBox else {
            throw SenseiAIError.noModelLoaded
        }

        return try await sessionBox.respond(to: prompt, onChunk: onChunk)
    }

    func collaborativeReply(
        to prompt: String,
        models: [LocalModelOption]
    ) async throws -> String {
        guard let primary = loadedModel else {
            throw SenseiAIError.noModelLoaded
        }

        let available = models.filter {
            BackgroundModelDownloadManager.shared.isModelReady($0)
        }
        guard available.count > 1 else {
            return try await reply(to: prompt)
        }

        let operationID = UUID().uuidString
        SenseiDiagnostics.shared.record(
            operationID: operationID,
            model: primary.name,
            stage: "TEAM_STARTED",
            message: "Sequential multi-model collaboration started with \(available.count) downloaded models."
        )

        var candidate = try await reply(to: prompt)
        candidate = Self.finalAnswer(from: candidate)

        for reviewer in available where reviewer != primary {
            do {
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: reviewer.name,
                    stage: "TEAM_REVIEWER_LOAD_STARTED",
                    message: "Loading reviewer model sequentially; models are not kept resident together."
                )
                _ = try await load(
                    model: reviewer,
                    operationID: operationID,
                    progressHandler: { _ in }
                )

                let reviewPrompt = """
                You are the reviewing model in SENSEI TEAM mode.
                Produce only the improved final answer to the ORIGINAL USER REQUEST.
                Treat the candidate answer as another model's draft, not as user-provided truth.
                Correct errors, preserve useful details, and do not mention this review process.

                ORIGINAL USER REQUEST
                \(prompt)

                CANDIDATE ANSWER
                \(candidate)
                """

                let reviewed = try await reply(to: reviewPrompt)
                let cleaned = Self.finalAnswer(from: reviewed)
                if !cleaned.isEmpty,
                   !cleaned.lowercased().hasPrefix("thinking process:") {
                    candidate = cleaned
                    SenseiDiagnostics.shared.record(
                        operationID: operationID,
                        model: reviewer.name,
                        stage: "TEAM_REVIEW_COMPLETE",
                        message: "Reviewer returned a usable final-answer candidate.",
                        level: "SUCCESS"
                    )
                } else {
                    SenseiDiagnostics.shared.record(
                        operationID: operationID,
                        model: reviewer.name,
                        stage: "TEAM_REVIEW_REJECTED",
                        message: "Reviewer output was empty or matched a known reasoning-transcript prefix.",
                        level: "WARNING"
                    )
                }
            } catch {
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: reviewer.name,
                    stage: "TEAM_REVIEW_ERROR",
                    message: error.localizedDescription,
                    level: "ERROR"
                )
            }
        }

        // TEAM mode is temporary. Return SENSEI to the user's primary model so
        // ordinary chat state and the UI do not silently switch models.
        if currentModel() != primary {
            do {
                _ = try await load(
                    model: primary,
                    operationID: operationID,
                    progressHandler: { _ in }
                )
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: primary.name,
                    stage: "TEAM_PRIMARY_RESTORED",
                    message: "Primary model restored after sequential collaboration.",
                    level: "SUCCESS"
                )
            } catch {
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: primary.name,
                    stage: "TEAM_PRIMARY_RESTORE_ERROR",
                    message: error.localizedDescription,
                    level: "ERROR"
                )
                throw error
            }
        }

        SenseiDiagnostics.shared.record(
            operationID: operationID,
            model: primary.name,
            stage: "TEAM_COMPLETE",
            message: "Sequential multi-model collaboration completed.",
            level: "SUCCESS"
        )
        return candidate
    }

    func cancelGeneration() {
        // ChatSession does not expose a synchronous stop primitive here.
        // Replacing the session detaches SENSEI from the in-flight generation
        // so the UI can immediately accept another prompt.
        guard let container else {
            sessionBox = nil
            return
        }
        sessionBox = SenseiSessionBox(container: container, instructions: Self.instructions)
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

    private static func finalAnswer(from raw: String) -> String {
        if let close = raw.range(of: "</think>", options: .caseInsensitive) {
            let answer = raw[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { return String(answer) }
        }
        for marker in ["Answer:", "Final Answer:", "Final:"] {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                let answer = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty { return String(answer) }
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func benchmarkCurrent(loadSeconds: Double = 0, operationID: String? = nil) async throws -> ModelBenchmarkSnapshot {
        guard let container, let model = loadedModel else {
            throw SenseiAIError.noModelLoaded
        }

        let benchmarkInstructions = """
        This is a deterministic reasoning sanity test.
        Follow the requested output format exactly and do not add explanation.
        """

        let benchmarkSession = ChatSession(
            container,
            instructions: benchmarkInstructions,
            generateParameters: GenerateParameters(maxTokens: 512),
            additionalContext: ["enable_thinking": false]
        )

        let prompt = """
        Return exactly one line in this format:
        A=<number>;B=<YES or NO>;C=<number>

        A: A tank is 3/5 full. After 24 liters are added it is 9/10 full. What is its total capacity in liters?
        B: All norps are blins. No blins are zats. Can any norp be a zat?
        C: What is 7 + 3 * 4 - 5?
        """

        let started = Date()
        let rawResponse = try await benchmarkSession.respond(to: prompt)

        // Preserve the complete captured benchmark output in diagnostics. This is
        // deliberately separate from what normal chat is allowed to display.
        SenseiDiagnostics.shared.record(
            operationID: operationID,
            model: model.name,
            stage: "BENCHMARK_RAW_OUTPUT",
            message: rawResponse,
            level: "INFO"
        )

        let response = Self.finalAnswer(from: rawResponse)
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
