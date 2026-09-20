import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let senseiModelDownloadDidUpdate = Notification.Name("sensei.modelDownloadDidUpdate")
    static let senseiModelDownloadDidFinish = Notification.Name("sensei.modelDownloadDidFinish")
}

struct ModelDownloadSnapshot: Sendable {
    let progress: Double
    let isDownloading: Bool
    let isReady: Bool
    let errorMessage: String?
}

final class BackgroundModelDownloadManager: NSObject, @unchecked Sendable {
    static let shared = BackgroundModelDownloadManager()
    static var sessionIdentifier: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.sensei.personal"
        return bundleID + ".model-downloads"
    }

    private struct RemoteFile: Codable, Sendable {
        let path: String
        let size: Int64
    }

    private struct Manifest: Codable, Sendable {
        let repositoryID: String
        let files: [RemoteFile]
    }

    private struct TreeItem: Decodable, Sendable {
        let type: String
        let path: String
        let size: Int64?
    }

    private struct TaskMetadata: Codable, Sendable {
        let modelRawValue: String
        let path: String
    }

    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SENSEI.ModelDownloads"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var backgroundSession: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60

        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }()

    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var handoffTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        _ = backgroundSession
    }

    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        delegateQueue.addOperation { [weak self] in
            self?.backgroundEventsCompletionHandler = handler
        }
    }

    func beginBackgroundHandoff() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handoffTaskIdentifier == .invalid else { return }

            self.handoffTaskIdentifier = UIApplication.shared.beginBackgroundTask(
                withName: "SENSEI Model Download Handoff"
            ) { [weak self] in
                self?.endBackgroundHandoff()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                self?.endBackgroundHandoff()
            }
        }
    }

    func endBackgroundHandoff() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handoffTaskIdentifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.handoffTaskIdentifier)
            self.handoffTaskIdentifier = .invalid
        }
    }

    func startDownload(for model: LocalModelOption) async throws {
        await requestNotificationAuthorization()

        if isModelReady(model) {
            postUpdate(model)
            return
        }

        let manifest = try await fetchManifest(for: model)
        try saveManifest(manifest, for: model)
        try fileManager.createDirectory(
            at: modelDirectory(for: model),
            withIntermediateDirectories: true
        )

        let tasks = await allTasks()
        let activePaths = Set(
            tasks.compactMap { task -> String? in
                guard
                    let metadata = metadata(for: task),
                    metadata.modelRawValue == model.rawValue
                else {
                    return nil
                }
                return metadata.path
            }
        )

        var scheduled = 0

        for file in manifest.files {
            if localFileIsComplete(file, model: model) || activePaths.contains(file.path) {
                continue
            }

            let task: URLSessionDownloadTask

            if let resumeData = try? Data(contentsOf: resumeDataURL(for: model, path: file.path)),
               !resumeData.isEmpty {
                task = backgroundSession.downloadTask(withResumeData: resumeData)
            } else {
                task = backgroundSession.downloadTask(
                    with: try downloadURL(repositoryID: manifest.repositoryID, path: file.path)
                )
            }

            task.taskDescription = try encodeMetadata(
                TaskMetadata(modelRawValue: model.rawValue, path: file.path)
            )
            task.countOfBytesClientExpectsToReceive = max(file.size, 1)
            task.priority = URLSessionTask.highPriority
            task.resume()
            scheduled += 1
        }

        defaults.set(nil, forKey: errorKey(for: model))

        if scheduled == 0, !isModelReady(model) {
            throw BackgroundModelDownloadError.noFilesScheduled
        }

        defaults.set(0, forKey: notificationMilestoneKey(for: model))
        notify(
            title: "SENSEI model download started",
            body: "\(model.name) is now assigned to iOS background downloading.",
            identifier: "sensei.model.\(model.rawValue).started"
        )
        postUpdate(model)
    }

    func snapshot(for model: LocalModelOption) async -> ModelDownloadSnapshot {
        guard let manifest = loadManifest(for: model) else {
            return ModelDownloadSnapshot(
                progress: 0,
                isDownloading: false,
                isReady: false,
                errorMessage: defaults.string(forKey: errorKey(for: model))
            )
        }

        if isModelReady(model) {
            return ModelDownloadSnapshot(
                progress: 1,
                isDownloading: false,
                isReady: true,
                errorMessage: nil
            )
        }

        let tasks = await allTasks()
        let modelTasks = tasks.filter {
            metadata(for: $0)?.modelRawValue == model.rawValue
        }

        let totalExpected = max(
            manifest.files.reduce(Int64(0)) { $0 + max(0, $1.size) },
            1
        )

        var completedBytes: Int64 = 0
        let activePaths = Set(modelTasks.compactMap { metadata(for: $0)?.path })

        for file in manifest.files where !activePaths.contains(file.path) {
            let url = localFileURL(for: model, path: file.path)
            if let size = try? fileSize(at: url) {
                completedBytes += min(size, max(file.size, 0))
            }
        }

        for task in modelTasks {
            completedBytes += max(0, task.countOfBytesReceived)
        }

        let progress = min(1, max(0, Double(completedBytes) / Double(totalExpected)))

        return ModelDownloadSnapshot(
            progress: progress,
            isDownloading: !modelTasks.isEmpty,
            isReady: false,
            errorMessage: defaults.string(forKey: errorKey(for: model))
        )
    }

    func isModelReady(_ model: LocalModelOption) -> Bool {
        guard let manifest = loadManifest(for: model), !manifest.files.isEmpty else {
            return false
        }

        for file in manifest.files {
            guard localFileIsComplete(file, model: model) else {
                return false
            }
        }

        return fileManager.fileExists(
            atPath: localFileURL(for: model, path: "config.json").path
        )
    }

    func readyModelDirectory(for model: LocalModelOption) -> URL? {
        isModelReady(model) ? modelDirectory(for: model) : nil
    }

    func modelDirectoryURL(for model: LocalModelOption) -> URL {
        modelDirectory(for: model)
    }

    private func fetchManifest(for model: LocalModelOption) async throws -> Manifest {
        let repo = model.repositoryID
        let urlString =
            "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true&expand=true"

        guard let url = URL(string: urlString) else {
            throw BackgroundModelDownloadError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw BackgroundModelDownloadError.manifestRequestFailed
        }

        let items = try JSONDecoder().decode([TreeItem].self, from: data)

        let files = items
            .filter { $0.type == "file" && shouldDownload(path: $0.path) }
            .map { RemoteFile(path: $0.path, size: max(0, $0.size ?? 0)) }

        guard !files.isEmpty else {
            throw BackgroundModelDownloadError.emptyManifest
        }

        return Manifest(repositoryID: repo, files: files)
    }

    private func shouldDownload(path: String) -> Bool {
        let lower = path.lowercased()

        return lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".json")
            || lower.hasSuffix(".jinja")
            || lower.hasSuffix(".txt")
            || lower.hasSuffix(".model")
            || lower.hasSuffix(".tiktoken")
    }

    private func downloadURL(repositoryID: String, path: String) throws -> URL {
        let encodedRepo = repositoryID
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        let encodedPath = path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        guard let url = URL(
            string: "https://huggingface.co/\(encodedRepo)/resolve/main/\(encodedPath)?download=true"
        ) else {
            throw BackgroundModelDownloadError.invalidURL
        }

        return url
    }

    private func modelDirectory(for model: LocalModelOption) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        return base
            .appendingPathComponent("SENSEI", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(model.rawValue, isDirectory: true)
    }

    private func localFileURL(for model: LocalModelOption, path: String) -> URL {
        path.split(separator: "/").reduce(modelDirectory(for: model)) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func resumeDataURL(for model: LocalModelOption, path: String) -> URL {
        let name = Data(path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")

        return modelDirectory(for: model)
            .appendingPathComponent(".resume", isDirectory: true)
            .appendingPathComponent(name + ".resume")
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func localFileIsComplete(_ file: RemoteFile, model: LocalModelOption) -> Bool {
        let url = localFileURL(for: model, path: file.path)

        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        guard file.size > 0 else {
            return true
        }

        guard let size = try? fileSize(at: url) else {
            return false
        }

        return size == file.size
    }

    private func manifestKey(for model: LocalModelOption) -> String {
        "sensei.backgroundModel.manifest.\(model.rawValue)"
    }

    private func errorKey(for model: LocalModelOption) -> String {
        "sensei.backgroundModel.error.\(model.rawValue)"
    }

    private func notificationMilestoneKey(for model: LocalModelOption) -> String {
        "sensei.backgroundModel.notificationMilestone.\(model.rawValue)"
    }

    private func manifestFileURL(for model: LocalModelOption) -> URL {
        modelDirectory(for: model)
            .appendingPathComponent(".sensei-manifest.json")
    }

    private func saveManifest(_ manifest: Manifest, for model: LocalModelOption) throws {
        let data = try JSONEncoder().encode(manifest)

        defaults.set(
            data,
            forKey: manifestKey(for: model)
        )

        let directory = modelDirectory(for: model)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: manifestFileURL(for: model),
            options: .atomic
        )
    }

    private func loadManifest(for model: LocalModelOption) -> Manifest? {
        let persistentURL = manifestFileURL(for: model)

        if let data = try? Data(contentsOf: persistentURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            return manifest
        }

        guard let data = defaults.data(forKey: manifestKey(for: model)) else {
            return nil
        }

        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func encodeMetadata(_ metadata: TaskMetadata) throws -> String {
        let data = try JSONEncoder().encode(metadata)
        guard let value = String(data: data, encoding: .utf8) else {
            throw BackgroundModelDownloadError.metadataEncodingFailed
        }
        return value
    }

    private func metadata(for task: URLSessionTask) -> TaskMetadata? {
        guard
            let description = task.taskDescription,
            let data = description.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(TaskMetadata.self, from: data)
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            backgroundSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func postUpdate(_ model: LocalModelOption) {
        NotificationCenter.default.post(
            name: .senseiModelDownloadDidUpdate,
            object: nil,
            userInfo: ["model": model.rawValue]
        )

        Task { [weak self] in
            await self?.maybeNotifyProgress(for: model)
        }
    }

    private func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )
    }

    private func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
        )
    }

    private func maybeNotifyProgress(for model: LocalModelOption) async {
        let current = await snapshot(for: model)

        if current.isReady {
            let last = defaults.integer(forKey: notificationMilestoneKey(for: model))
            if last < 100 {
                defaults.set(100, forKey: notificationMilestoneKey(for: model))
                NotificationCenter.default.post(name: .senseiModelDownloadDidFinish, object: nil, userInfo: ["model": model.rawValue])
                notify(
                    title: "SENSEI model ready",
                    body: "\(model.name) finished downloading. Open SENSEI to load it.",
                    identifier: "sensei.model.\(model.rawValue).complete"
                )
            }
            return
        }

        guard current.isDownloading else { return }

        let percent = Int(current.progress * 100)
        let milestone: Int
        switch percent {
        case 75...:
            milestone = 75
        case 50...:
            milestone = 50
        case 25...:
            milestone = 25
        default:
            milestone = 0
        }

        let last = defaults.integer(forKey: notificationMilestoneKey(for: model))
        guard milestone > last else { return }

        defaults.set(milestone, forKey: notificationMilestoneKey(for: model))
        notify(
            title: "SENSEI download \(milestone)%",
            body: "\(model.name) is still downloading in the background.",
            identifier: "sensei.model.\(model.rawValue).\(milestone)"
        )
    }

    private func storeResumeData(
        _ data: Data,
        for model: LocalModelOption,
        path: String
    ) {
        let url = resumeDataURL(for: model, path: path)

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // Resume data is an optimization. A failed save can fall back to a fresh task.
        }
    }
}

extension BackgroundModelDownloadManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        guard
            let metadata = metadata(for: task),
            let model = LocalModelOption(rawValue: metadata.modelRawValue)
        else {
            return
        }

        notify(
            title: "SENSEI waiting for connectivity",
            body: "\(model.name) is queued by iOS and will continue automatically when connectivity is available.",
            identifier: "sensei.model.\(model.rawValue).connectivity"
        )

        postUpdate(model)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard
            let metadata = metadata(for: downloadTask),
            let model = LocalModelOption(rawValue: metadata.modelRawValue)
        else {
            return
        }

        postUpdate(model)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard
            let metadata = metadata(for: downloadTask),
            let model = LocalModelOption(rawValue: metadata.modelRawValue)
        else {
            return
        }

        let destination = localFileURL(for: model, path: metadata.path)

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.moveItem(at: location, to: destination)

            let resumeURL = resumeDataURL(for: model, path: metadata.path)
            try? fileManager.removeItem(at: resumeURL)

            defaults.set(nil, forKey: errorKey(for: model))
            if isModelReady(model) {
                defaults.set(100, forKey: notificationMilestoneKey(for: model))
                notify(
                    title: "SENSEI model ready",
                    body: "\(model.name) finished downloading. Open SENSEI to load it.",
                    identifier: "sensei.model.\(model.rawValue).complete"
                )
            }
            postUpdate(model)
        } catch {
            defaults.set(error.localizedDescription, forKey: errorKey(for: model))
            postUpdate(model)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard
            let metadata = metadata(for: task),
            let model = LocalModelOption(rawValue: metadata.modelRawValue)
        else {
            return
        }

        if let error {
            let nsError = error as NSError

            let resumeData =
                nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

            if let resumeData {
                storeResumeData(
                    resumeData,
                    for: model,
                    path: metadata.path
                )
            }

            let transientCodes: Set<URLError.Code> = [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .dataNotAllowed,
                .internationalRoamingOff,
                .backgroundSessionWasDisconnected
            ]

            let urlCode = URLError.Code(rawValue: nsError.code)

            if nsError.domain == NSURLErrorDomain,
               transientCodes.contains(urlCode),
               let manifest = loadManifest(for: model) {
                let retryTask: URLSessionDownloadTask

                if let resumeData, !resumeData.isEmpty {
                    retryTask = backgroundSession.downloadTask(withResumeData: resumeData)
                } else if let url = try? downloadURL(
                    repositoryID: manifest.repositoryID,
                    path: metadata.path
                ) {
                    retryTask = backgroundSession.downloadTask(with: url)
                } else {
                    defaults.set(error.localizedDescription, forKey: errorKey(for: model))
                    postUpdate(model)
                    return
                }

                retryTask.taskDescription = task.taskDescription

                if let remoteFile = manifest.files.first(where: { $0.path == metadata.path }) {
                    retryTask.countOfBytesClientExpectsToReceive = max(remoteFile.size, 1)
                }

                retryTask.priority = URLSessionTask.highPriority
                defaults.set(nil, forKey: errorKey(for: model))
                retryTask.resume()

                notify(
                    title: "SENSEI download reconnecting",
                    body: "\(model.name) was interrupted and is being resumed automatically.",
                    identifier: "sensei.model.\(model.rawValue).reconnecting"
                )

                postUpdate(model)
                return
            }

            defaults.set(error.localizedDescription, forKey: errorKey(for: model))
        }

        postUpdate(model)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil

        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }
}

enum BackgroundModelDownloadError: LocalizedError {
    case invalidURL
    case manifestRequestFailed
    case emptyManifest
    case metadataEncodingFailed
    case noFilesScheduled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "SENSEI could not create the model download URL."
        case .manifestRequestFailed:
            "SENSEI could not read the model file list from Hugging Face."
        case .emptyManifest:
            "No compatible model files were found."
        case .metadataEncodingFailed:
            "SENSEI could not prepare the background download."
        case .noFilesScheduled:
            "The model is incomplete, but no download task could be scheduled."
        }
    }
}
