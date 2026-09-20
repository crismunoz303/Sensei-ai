import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage]
    @Published var draft = ""
    @Published var isThinking = false

    @Published var selectedModel: LocalModelOption
    @Published var loadedModel: LocalModelOption?
    @Published var statusText = "NO MODEL"
    @Published var modelStatusDetail = "Open Model Lab and download a local model."
    @Published var isLoadingModel = false
    @Published var isDownloadingModel = false
    @Published var modelDownloadReady = false
    @Published var modelProgress: Double = 0
    @Published var benchmarkResult: ModelBenchmarkSnapshot?
    @Published var benchmarkError: String?

    private let ai = SenseiAI.shared
    private let downloads = BackgroundModelDownloadManager.shared
    private let store = ConversationStore()
    private let defaults = UserDefaults.standard
    private var lastLoadSeconds: Double = 0
    private var downloadObserver: NSObjectProtocol?
    private var downloadFinishObserver: NSObjectProtocol?

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
                    text: "SENSEI is ready for its independent local model. Open MODEL LAB and download the model you want. Completed model files stay saved inside SENSEI across normal app restarts."
                )
            ]
        } else {
            messages = saved
        }

        downloadObserver = NotificationCenter.default.addObserver(
            forName: .senseiModelDownloadDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let raw = notification.userInfo?["model"] as? String,
                let model = LocalModelOption(rawValue: raw)
            else {
                return
            }

            Task { @MainActor [weak self] in
                guard self?.selectedModel == model else { return }
                self?.refreshDownloadState()
            }
        }

        downloadFinishObserver = NotificationCenter.default.addObserver(
            forName: .senseiModelDownloadDidFinish,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let raw = notification.userInfo?["model"] as? String,
                let model = LocalModelOption(rawValue: raw)
            else { return }

            Task { @MainActor in
                let drive = GoogleDriveBackupManager.shared
                guard drive.isSignedIn,
                      let directory = BackgroundModelDownloadManager.shared.readyModelDirectory(for: model)
                else { return }
                try? await drive.backUpModel(model, directory: directory)
            }
        }

        refreshDownloadState()
    }

    func selectModel(_ model: LocalModelOption) {
        selectedModel = model
        defaults.set(model.rawValue, forKey: "sensei.selectedModel")
        benchmarkResult = nil
        benchmarkError = nil
        refreshDownloadState()
    }

    func refreshDownloadState() {
        let model = selectedModel

        Task {
            let snapshot = await downloads.snapshot(for: model)

            guard selectedModel == model else { return }

            modelProgress = snapshot.progress
            isDownloadingModel = snapshot.isDownloading
            modelDownloadReady = snapshot.isReady

            if loadedModel == model {
                statusText = "LOCAL"
                modelStatusDetail = "\(model.name) is loaded locally."
                return
            }

            if snapshot.isReady {
                statusText = "READY"
                modelStatusDetail = "\(model.name) finished downloading. Tap LOAD LOCAL MODEL."
            } else if snapshot.isDownloading {
                statusText = "DOWNLOADING"
                modelStatusDetail = "Downloading \(model.name) in the background. You can leave SENSEI or lock the phone."
            } else if let error = snapshot.errorMessage {
                statusText = "PAUSED"
                modelStatusDetail = "\(error) Tap DOWNLOAD MODEL to resume."
            } else {
                statusText = "NO MODEL"
                modelStatusDetail = "\(model.name) is not downloaded yet."
            }
        }
    }

    func loadSelectedModel() {
        guard !isLoadingModel else { return }

        let model = selectedModel

        if downloads.isModelReady(model) {
            loadModelFromDisk(model)
            return
        }

        isDownloadingModel = true
        modelDownloadReady = false
        statusText = "DOWNLOADING"
        modelStatusDetail = "Preparing \(model.name) for background download…"
        benchmarkError = nil

        Task {
            do {
                try await downloads.startDownload(for: model)
                refreshDownloadState()
            } catch {
                isDownloadingModel = false
                statusText = "ERROR"
                modelStatusDetail = error.localizedDescription
                benchmarkError = error.localizedDescription
            }
        }
    }

    private func loadModelFromDisk(_ model: LocalModelOption) {
        isLoadingModel = true
        isDownloadingModel = false
        modelProgress = 1
        statusText = "LOADING"
        modelStatusDetail = "Loading \(model.name) into memory…"
        benchmarkError = nil

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
                modelDownloadReady = true
                statusText = "LOCAL"
                modelStatusDetail = "\(model.name) is loaded locally."
            } catch {
                loadedModel = nil
                statusText = "ERROR"
                modelStatusDetail = error.localizedDescription
                benchmarkError = error.localizedDescription
            }

            isLoadingModel = false
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
                    text: "No independent local model is loaded yet. Open MODEL LAB, download one, then load it locally."
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

        ai.resetConversation()

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
