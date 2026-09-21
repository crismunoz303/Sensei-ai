import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage]
    @Published var draft = ""
    @Published var isThinking = false
    @Published var thinkingStatus = "Thinking…"

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
    @Published var isRunningBenchmark = false
    @Published var collaborationMode = false
    @Published var individualMode = false

    private let ai = SenseiAI.shared
    private let downloads = BackgroundModelDownloadManager.shared
    private let store = ConversationStore()
    private let defaults = UserDefaults.standard
    private var lastLoadSeconds: Double = 0
    private var lastProgressSample: (date: Date, progress: Double)?
    private var downloadObserver: NSObjectProtocol?
    private var downloadFinishObserver: NSObjectProtocol?
    private var generationTask: Task<Void, Never>?

    var downloadedModels: [LocalModelOption] {
        LocalModelOption.allCases.filter { downloads.isModelReady($0) }
    }

    var collaborationAvailable: Bool {
        downloadedModels.count > 1
    }

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

        // A downloaded model survives app restarts, but an MLX model in RAM does not.
        // Restore the selected model automatically whenever its files are complete.
        restoreSelectedModelIfNeeded()
    }

    func restoreSelectedModelIfNeeded() {
        guard loadedModel == nil, !isLoadingModel, !isDownloadingModel else { return }
        let model = selectedModel
        guard downloads.isModelReady(model) else {
            refreshDownloadState()
            return
        }
        SenseiDiagnostics.shared.record(
            model: model.name,
            stage: "AUTO_RESTORE_STARTED",
            message: "Selected model files are ready; automatic in-memory restore started."
        )
        loadModelFromDisk(model, isAutomaticRestore: true)
    }

    func selectModel(_ model: LocalModelOption) {
        selectedModel = model
        defaults.set(model.rawValue, forKey: "sensei.selectedModel")
        benchmarkResult = nil
        benchmarkError = nil
        refreshDownloadState()
    }

    func activateFastMode() {
        collaborationMode = false
        individualMode = false
    }

    func activateTeamMode() {
        guard collaborationAvailable else { return }
        collaborationMode = true
        individualMode = false
    }

    func activateIndividualMode(_ model: LocalModelOption) {
        guard downloads.isModelReady(model), !isThinking, !isLoadingModel else { return }
        collaborationMode = false
        individualMode = true
        selectModel(model)
        guard loadedModel != model else { return }
        loadModelFromDisk(model)
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

    private func loadModelFromDisk(_ model: LocalModelOption, isAutomaticRestore: Bool = false) {
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
                if isAutomaticRestore {
                    SenseiDiagnostics.shared.record(
                        operationID: operationID,
                        model: model.name,
                        stage: "AUTO_RESTORE_COMPLETE",
                        message: "Selected model was restored into memory automatically.",
                        level: "SUCCESS"
                    )
                }
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
                if isAutomaticRestore {
                    SenseiDiagnostics.shared.record(
                        operationID: operationID,
                        model: model.name,
                        stage: "AUTO_RESTORE_ERROR",
                        message: error.localizedDescription,
                        level: "ERROR"
                    )
                }
            }

            isLoadingModel = false
        }
    }

    func runBenchmark() {
        guard !isRunningBenchmark else { return }
        guard loadedModel == selectedModel else {
            benchmarkError = "The selected model is not loaded. Load it first."
            return
        }
        guard !isLoadingModel else {
            benchmarkError = "The model is still loading."
            return
        }
        guard !isThinking else {
            benchmarkError = "A chat response is still generating. Stop it or wait for it to finish before running the test."
            return
        }

        isRunningBenchmark = true
        benchmarkError = nil
        benchmarkResult = nil

        Task {
            let operationID = UUID().uuidString
            SenseiDiagnostics.shared.record(
                operationID: operationID,
                model: loadedModel?.name,
                stage: "BENCHMARK_STARTED",
                message: "On-device benchmark generation started."
            )
            let stallWatch = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self.isRunningBenchmark else { return }
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
                benchmarkResult = try await ai.benchmarkCurrent(loadSeconds: lastLoadSeconds, operationID: operationID)
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

            isRunningBenchmark = false
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

    private static func liveAnswerText(_ raw: String) -> String? {
        if let close = raw.range(of: "</think>", options: .caseInsensitive) {
            let answer = raw[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : String(answer)
        }

        // While an explicit thinking block is open, never expose its contents.
        if raw.range(of: "<think>", options: .caseInsensitive) != nil {
            return nil
        }

        let answerMarkers = ["Answer:", "Final Answer:", "Final:"]
        for marker in answerMarkers {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                let answer = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty ? nil : String(answer)
            }
        }

        // No reliable boundary yet. Keep the stream private until completion.
        return nil
    }

    private static func completedAnswerText(_ raw: String) -> String? {
        if let close = raw.range(of: "</think>", options: .caseInsensitive) {
            let answer = raw[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { return String(answer) }
        }

        // Prefer the explicit final-answer markers before the generic one.
        for marker in ["Final Answer:", "Final:", "Answer:"] {
            if let range = raw.range(of: marker, options: .caseInsensitive) {
                let answer = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty { return String(answer) }
            }
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // This exact prefix has already been observed in leaked Qwen output.
        // Never turn a known reasoning transcript into a visible assistant answer.
        if trimmed.lowercased().hasPrefix("thinking process:") {
            return nil
        }

        // With Qwen thinking disabled at the chat template, a normal delimiter-free
        // completion is the final answer.
        return trimmed
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

        if let teaching = SenseiMemoryStore.shared.explicitTeaching(from: prompt),
           let memory = SenseiMemoryStore.shared.remember(teaching.text, kind: teaching.kind) {
            SenseiDiagnostics.shared.record(
                model: loadedModel?.name,
                stage: "MEMORY_SAVED",
                message: "User explicitly saved a \(memory.kind.rawValue) memory.",
                level: "SUCCESS"
            )
            append(ChatMessage(role: .assistant, text: "Remembered. I’ll keep that in SENSEI’s local memory across conversations."))
            return
        }

        isThinking = true
        thinkingStatus = "Starting local generation…"

        // Progress is rendered separately. Do not create a fake "Thinking…" chat
        // message; the assistant bubble appears only when a real answer is available.
        let responseID = UUID()
        let responseCreatedAt = Date()
        var responseInserted = false

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
                let memoryContext = SenseiMemoryStore.shared.context(for: prompt)
                let modelPrompt: String
                if let memoryContext {
                    modelPrompt = """
                    \(memoryContext)

                    CURRENT USER REQUEST
                    \(prompt)
                    """
                    SenseiDiagnostics.shared.record(
                        operationID: operationID,
                        model: loadedModel?.name,
                        stage: "MEMORY_CONTEXT_ATTACHED",
                        message: "Relevant persistent local memories were attached to this generation."
                    )
                } else {
                    modelPrompt = prompt
                }

                if collaborationMode && collaborationAvailable {
                    thinkingStatus = "SENSEI TEAM is collaborating…"
                    let teamAnswer = try await ai.collaborativeReply(
                        to: modelPrompt,
                        models: downloadedModels
                    )
                    streamedText = teamAnswer
                    receivedFirstChunk = true
                    thinkingStatus = "Writing response…"
                    SenseiDiagnostics.shared.record(
                        operationID: operationID,
                        model: loadedModel?.name,
                        stage: "TEAM_CHAT_RESULT_READY",
                        message: "TEAM mode returned a final-answer candidate to chat.",
                        level: "SUCCESS"
                    )
                } else {
                    _ = try await ai.reply(to: modelPrompt) { chunk in
                    guard !chunk.isEmpty, !Task.isCancelled else { return }

                    streamedText += chunk
                    // Report only observable runtime state. Do not invent a
                    // semantic description of the model's private reasoning.
                    self.thinkingStatus = "Generating locally…"
                    if streamedText.range(of: "</think>", options: .caseInsensitive) != nil {
                        self.thinkingStatus = "Writing response…"
                    }

                    if let visibleText = Self.liveAnswerText(streamedText) {
                        self.thinkingStatus = "Writing response…"
                        if let index = self.messages.firstIndex(where: { $0.id == responseID }) {
                            self.messages[index] = ChatMessage(
                                id: responseID,
                                role: .assistant,
                                text: visibleText,
                                createdAt: responseCreatedAt
                            )
                        } else {
                            self.messages.append(
                                ChatMessage(id: responseID, role: .assistant, text: visibleText, createdAt: responseCreatedAt)
                            )
                            responseInserted = true
                        }
                    }

                    if !receivedFirstChunk {
                        receivedFirstChunk = true
                        SenseiDiagnostics.shared.record(
                            operationID: operationID,
                            model: self.loadedModel?.name,
                            stage: "GENERATION_FIRST_CHUNK",
                            message: "First generation chunk received. It may remain private until a safe final-answer boundary is available.",
                            level: "SUCCESS"
                        )
                    }
                    }
                }

                try Task.checkCancellation()
                let finalVisibleText = Self.completedAnswerText(streamedText)
                let completedText: String
                if let finalVisibleText {
                    if finalVisibleText.isEmpty {
                        completedText = "SENSEI completed generation but returned no answer."
                        SenseiDiagnostics.shared.record(
                            operationID: operationID,
                            model: loadedModel?.name,
                            stage: "EMPTY_FINAL_ANSWER",
                            message: "Generation completed without a visible final answer.",
                            level: "WARNING"
                        )
                    } else {
                        completedText = finalVisibleText
                    }
                } else {
                    completedText = "SENSEI blocked an internal reasoning transcript. Please retry."
                    SenseiDiagnostics.shared.record(
                        operationID: operationID,
                        model: loadedModel?.name,
                        stage: "REASONING_OUTPUT_BLOCKED",
                        message: streamedText,
                        level: "ERROR"
                    )
                }
                if let index = messages.firstIndex(where: { $0.id == responseID }) {
                    messages[index] = ChatMessage(
                        id: responseID,
                        role: .assistant,
                        text: completedText,
                        createdAt: responseCreatedAt
                    )
                } else {
                    messages.append(
                        ChatMessage(id: responseID, role: .assistant, text: completedText, createdAt: responseCreatedAt)
                    )
                    responseInserted = true
                }
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
                // Preserve only a real answer bubble; private reasoning is discarded.
                if responseInserted {
                    store.save(messages)
                }
            } catch {
                if let index = messages.firstIndex(where: { $0.id == responseID }) {
                    messages[index] = ChatMessage(
                        id: responseID,
                        role: .assistant,
                        text: "Local model error: \(error.localizedDescription)",
                        createdAt: responseCreatedAt
                    )
                } else {
                    messages.append(
                        ChatMessage(id: responseID, role: .assistant, text: "Local model error: \(error.localizedDescription)", createdAt: responseCreatedAt)
                    )
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
