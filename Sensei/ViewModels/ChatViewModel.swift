import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage]
    @Published var draft = ""
    @Published var isThinking = false

    @Published var selectedModel: LocalModelOption
    @Published var loadedModel: LocalModelOption?
    @Published var statusText = "NO MODEL"
    @Published var modelStatusDetail = "Open Model Lab and load a local model."
    @Published var isLoadingModel = false
    @Published var modelProgress: Double = 0
    @Published var benchmarkResult: ModelBenchmarkSnapshot?
    @Published var benchmarkError: String?

    private let ai = SenseiAI.shared
    private let store = ConversationStore()
    private let defaults = UserDefaults.standard
    private var lastLoadSeconds: Double = 0

    init() {
        if let raw = UserDefaults.standard.string(forKey: "sensei.selectedModel"),
           let storedModel = LocalModelOption(rawValue: raw) {
            selectedModel = storedModel
        } else {
            selectedModel = .qwen35_9b
        }

        let saved = store.load()
        if saved.isEmpty {
            messages = [
                ChatMessage(
                    role: .assistant,
                    text: "SENSEI is ready for its independent local model. Open MODEL LAB, choose a model, and load it once. After download, the AI runs locally on this iPhone."
                )
            ]
        } else {
            messages = saved
        }
    }

    func selectModel(_ model: LocalModelOption) {
        selectedModel = model
        defaults.set(model.rawValue, forKey: "sensei.selectedModel")

        if loadedModel != model {
            statusText = "NO MODEL"
            modelStatusDetail = "\(model.name) selected. Load it to use SENSEI."
        }
    }

    func loadSelectedModel() {
        guard !isLoadingModel else { return }

        isLoadingModel = true
        modelProgress = 0
        statusText = "LOADING"
        modelStatusDetail = "Downloading or loading \(selectedModel.name)…"
        benchmarkError = nil

        let model = selectedModel

        Task {
            do {
                let loadSeconds = try await ai.load(
                    model: model,
                    progressHandler: { [weak self] progress in
                        self?.modelProgress = progress
                    }
                )

                lastLoadSeconds = loadSeconds
                loadedModel = model
                statusText = "LOCAL"
                modelStatusDetail = "\(model.name) is loaded locally."
                isLoadingModel = false
            } catch {
                loadedModel = nil
                statusText = "ERROR"
                modelStatusDetail = error.localizedDescription
                benchmarkError = error.localizedDescription
                isLoadingModel = false
            }
        }
    }

    func runBenchmark() {
        guard loadedModel == selectedModel, !isLoadingModel, !isThinking else {
            benchmarkError = "Load the selected model first."
            return
        }

        isThinking = true
        benchmarkError = nil
        benchmarkResult = nil

        Task {
            do {
                benchmarkResult = try await ai.benchmarkCurrent(loadSeconds: lastLoadSeconds)
            } catch {
                benchmarkError = error.localizedDescription
            }

            isThinking = false
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }

        guard loadedModel != nil else {
            append(
                ChatMessage(
                    role: .assistant,
                    text: "No independent local model is loaded yet. Open MODEL LAB at the top, choose a model, and tap LOAD MODEL."
                )
            )
            return
        }

        draft = ""
        append(ChatMessage(role: .user, text: prompt))
        isThinking = true

        Task {
            do {
                let answer = try await ai.reply(to: prompt)
                append(ChatMessage(role: .assistant, text: answer))
                statusText = "LOCAL"
            } catch {
                append(
                    ChatMessage(
                        role: .assistant,
                        text: "Local model error: \(error.localizedDescription)"
                    )
                )
                statusText = "ERROR"
            }

            isThinking = false
        }
    }

    func clearConversation() {
        messages.removeAll()
        store.clear()

        Task {
            await ai.resetConversation()
        }

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
