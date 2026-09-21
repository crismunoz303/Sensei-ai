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
    @Published var downloadETA: String?
    @Published var benchmarkResult: ModelBenchmarkSnapshot?
    @Published var benchmarkError: String?

    private let ai = SenseiAI.shared
    private let downloads = BackgroundModelDownloadManager.shared
    private let store = ConversationStore()
    private let defaults = UserDefaults.standard
    private var lastLoadSeconds: Double = 0
    private var lastProgressSample: (date: Date, progress: Double)?
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
                do {
                    try await drive.backUpModel(model, directory: directory)
                } catch {
                    SenseiDiagnostics.shared.record(
                        model: model.name,
                        stage: "DRIVE_BACKUP_ERROR",
                        message: error.localizedDescription,
                        level: "ERROR"
                    )
                }
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

            let now = Date()
            if snapshot.isDownloading, let previous = lastProgressSample {
                let elapsed = now.timeIntervalSince(previous.date)
                let delta = snapshot.progress - previous.progress
                if elapsed >= 1, delta > 0.0001 {
                    let rate = delta / elapsed
                    let seconds = (1 - snapshot.progress) / rate
                    downloadETA = Self.formatETA(seconds)
                    lastProgressSample = (now, snapshot.progress)
                } else if downloadETA == nil {
                    downloadETA = "Calculating…"
                }
            } else if snapshot.isDownloading {
                downloadETA = "Calculating…"
                lastProgressSample = (now, snapshot.progress)
            } else {
                downloadETA = nil
                lastProgressSample = nil
            }
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

        let operationID = SenseiDiagnostics.shared.beginModelLoad(model: model)

        Task {
            do {
                let loadSeconds = try await ai.load(
                    model: model,
                    operationID: operationID,
                    progressHandler: { [weak self] progress in
                        self?.modelProgress = progress
                    }
                )

                lastLoadSeconds = loadSeconds
                loadedModel = model
                modelDownloadReady = true
                SenseiDiagnostics.shared.completeModelLoad(
                    operationID: operationID,
                    model: model
                )
                statusText = "LOCAL"
                modelStatusDetail = "\(model.name) is loaded locally."
            } catch {
                SenseiDiagnostics.shared.failModelLoad(
                    operationID: operationID,
                    model: model,
                    error: error
                )
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

    private static func formatETA(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Calculating…" }
        let value = Int(seconds.rounded())
        if value < 60 { return "~\(max(value, 1)) sec remaining" }
        if value < 3600 { return "~\(max(value / 60, 1)) min remaining" }
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        return minutes > 0 ? "~\(hours)h \(minutes)m remaining" : "~\(hours)h remaining"
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
            let operationID = UUID().uuidString
            SenseiDiagnostics.shared.record(
                operationID: operationID,
                model: loadedModel?.name,
                stage: "GENERATION_STARTED",
                message: "ChatSession generation started."
            )
            do {
                let answer = try await ai.reply(to: prompt)
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: loadedModel?.name,
                    stage: "GENERATION_COMPLETE",
                    message: "ChatSession returned a response.",
                    level: "SUCCESS"
                )
                append(ChatMessage(role: .assistant, text: answer))
                statusText = "LOCAL"
            } catch {
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: loadedModel?.name,
                    stage: "GENERATION_ERROR",
                    message: error.localizedDescription,
                    level: "ERROR"
                )
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
