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
    private var generationTask: Task<Void, Never>?

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
        guard loadedModel == selectedModel else {
            benchmarkError = "The selected model is not loaded. Load it first."
            return
        }
        guard !isLoadingModel else {
            benchmarkError = "The model is still loading."
            return
        }
        guard !isThinking else {
            benchmarkError = "A chat generation is still running. Check Errors / Diagnostics for its last checkpoint."
            return
        }

        isThinking = true
        benchmarkError = nil
        benchmarkResult = nil

        generationTask = Task {
            let operationID = UUID().uuidString
            SenseiDiagnostics.shared.record(
                operationID: operationID,
                model: loadedModel?.name,
                stage: "BENCHMARK_STARTED",
                message: "On-device benchmark generation started."
            )
            let stallWatch = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self.isThinking else { return }
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: self.loadedModel?.name,
                    stage: "BENCHMARK_STILL_RUNNING",
                    message: "Benchmark has not returned after 20 seconds.",
                    level: "WARNING"
                )
            }
            defer { stallWatch.cancel() }
            do {
                benchmarkResult = try await ai.benchmarkCurrent(loadSeconds: lastLoadSeconds)
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: loadedModel?.name,
                    stage: "BENCHMARK_COMPLETE",
                    message: "Benchmark returned a response.",
                    level: "SUCCESS"
                )
            } catch {
                benchmarkError = error.localizedDescription
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: loadedModel?.name,
                    stage: "BENCHMARK_ERROR",
                    message: error.localizedDescription,
                    level: "ERROR"
                )
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

    private static func compactStreamDisplay(_ raw: String) -> String {
        // Never render model scratch work. Qwen variants may emit reasoning
        // before a final-answer marker even when instructed not to.
        let answerMarkers = ["Answer:", "Final Answer:", "Final:"]
        for marker in answerMarkers {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                let answer = raw[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty ? "Thinking…" : answer
            }
        }

        // Common Qwen think-tag format: only reveal text after </think>.
        if let range = raw.range(of: "</think>", options: .caseInsensitive) {
            let answer = raw[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? "Thinking…" : answer
        }

        return "Thinking…"
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

        // Create the assistant bubble immediately and mutate it as MLX streams
        // chunks. The user sees output as soon as the first token arrives.
        let responseID = UUID()
        let responseCreatedAt = Date()
        messages.append(
            ChatMessage(
                id: responseID,
                role: .assistant,
                text: "",
                createdAt: responseCreatedAt
            )
        )

        generationTask = Task {
            let operationID = UUID().uuidString
            SenseiDiagnostics.shared.record(
                operationID: operationID,
                model: loadedModel?.name,
                stage: "GENERATION_STARTED",
                message: "ChatSession streaming generation started."
            )

            var streamedText = ""
            var receivedFirstChunk = false

            do {
                _ = try await ai.reply(to: prompt) { chunk in
                    guard !chunk.isEmpty, !Task.isCancelled else { return }

                    streamedText += chunk
                    let visibleText = Self.compactStreamDisplay(streamedText)
                    if let index = self.messages.firstIndex(where: { $0.id == responseID }) {
                        self.messages[index] = ChatMessage(
                            id: responseID,
                            role: .assistant,
                            text: visibleText,
                            createdAt: responseCreatedAt
                        )
                    }

                    if !receivedFirstChunk {
                        receivedFirstChunk = true
                        SenseiDiagnostics.shared.record(
                            operationID: operationID,
                            model: self.loadedModel?.name,
                            stage: "GENERATION_FIRST_CHUNK",
                            message: "First streamed text is visible in chat.",
                            level: "SUCCESS"
                        )
                    }
                }

                try Task.checkCancellation()
                store.save(messages)
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: loadedModel?.name,
                    stage: "GENERATION_COMPLETE",
                    message: "Streaming response completed and was saved.",
                    level: "SUCCESS"
                )
                statusText = "LOCAL"
            } catch is CancellationError {
                // Preserve whatever text was already streamed when STOP was used.
                if streamedText.isEmpty {
                    messages.removeAll { $0.id == responseID }
                } else {
                    store.save(messages)
                }
            } catch {
                if streamedText.isEmpty {
                    if let index = messages.firstIndex(where: { $0.id == responseID }) {
                        messages[index] = ChatMessage(
                            id: responseID,
                            role: .assistant,
                            text: "Local model error: \(error.localizedDescription)",
                            createdAt: responseCreatedAt
                        )
                    }
                }
                store.save(messages)
                SenseiDiagnostics.shared.record(
                    operationID: operationID,
                    model: loadedModel?.name,
                    stage: "GENERATION_ERROR",
                    message: error.localizedDescription,
                    level: "ERROR"
                )
                statusText = "ERROR"
            }

            isThinking = false
            generationTask = nil
        }
    }

    func stopThinking() {
        guard isThinking else { return }
        generationTask?.cancel()
        generationTask = nil
        ai.cancelGeneration()
        isThinking = false
        SenseiDiagnostics.shared.record(
            model: loadedModel?.name,
            stage: "GENERATION_CANCELLED",
            message: "User stopped local generation.",
            level: "INFO"
        )
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
