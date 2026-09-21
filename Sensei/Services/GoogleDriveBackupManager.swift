import Foundation
import GoogleSignIn
import UIKit

@MainActor
final class GoogleDriveBackupManager: ObservableObject {
    static let shared = GoogleDriveBackupManager()

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var status = "NOT CONNECTED"
    @Published private(set) var detail = "Sign in once to let SENSEI back up completed models automatically."
    @Published private(set) var isBackingUp = false
    @Published private(set) var backupProgress: Double = 0
    @Published private(set) var backupETA: String?

    private let scope = "https://www.googleapis.com/auth/drive.file"
    private let clientID = "934355792148-tlle93u7lt07l9vmj9kpttdfonk3lrer.apps.googleusercontent.com"

    private init() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        restore()
    }

    func restore() {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            guard let self else { return }
            if user != nil {
                self.applyCurrentUserState()
            } else if let error {
                self.status = "SIGN IN NEEDED"
                self.detail = error.localizedDescription
            }
        }
    }

    func signIn() async throws {
        guard let presenter = Self.presentingViewController() else {
            throw DriveBackupError.noPresenter
        }

        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter,
            hint: nil,
            additionalScopes: [scope]
        )
        apply(result.user)
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        accountEmail = nil
        status = "NOT CONNECTED"
        detail = "Sign in once to let SENSEI back up completed models automatically."
    }

    func backUpModel(_ model: LocalModelOption, directory: URL) async throws {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            status = "SIGN IN NEEDED"
            detail = DriveBackupError.notSignedIn.localizedDescription
            throw DriveBackupError.notSignedIn
        }

        isBackingUp = true
        backupProgress = 0
        backupETA = "Calculating…"
        status = "BACKING UP"
        detail = "Preparing \(model.name) for Google Drive…"

        do {
        let token = try await refreshedAccessToken(for: user)
        let folderID = try await ensureFolder(accessToken: token)
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .map { directory.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }

        let totalBytes = max(files.reduce(Int64(0)) { partial, file in
            partial + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        }, 1)
        var uploadedBytes: Int64 = 0
        let backupStarted = Date()

        for file in files {
            let relative = file.path.replacingOccurrences(of: directory.path + "/", with: "")
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            try await uploadResumable(
                file: file,
                name: model.rawValue + "/" + relative,
                parentID: folderID,
                accessToken: token
            ) { [weak self] fileBytesSent in
                guard let self else { return }
                let currentBytes = uploadedBytes + fileBytesSent
                self.backupProgress = min(1, Double(currentBytes) / Double(totalBytes))
                let elapsed = Date().timeIntervalSince(backupStarted)
                if elapsed >= 2, currentBytes > 0 {
                    let bytesPerSecond = Double(currentBytes) / elapsed
                    let remaining = Double(max(totalBytes - currentBytes, 0)) / bytesPerSecond
                    self.backupETA = Self.formatETA(remaining)
                }
                self.detail = "Uploading \(model.name)… \(Int(self.backupProgress * 100))%"
            }
            uploadedBytes += size
            backupProgress = min(1, Double(uploadedBytes) / Double(totalBytes))
        }

        backupProgress = 1
        backupETA = nil
        isBackingUp = false
        status = "BACKED UP"
        detail = "\(model.name) is backed up to Google Drive."
        } catch {
            backupETA = nil
            isBackingUp = false
            status = "BACKUP FAILED"
            detail = error.localizedDescription
            throw error
        }
    }

    func retryBackup(_ model: LocalModelOption) async throws {
        guard let directory = BackgroundModelDownloadManager.shared.readyModelDirectory(for: model) else {
            throw DriveBackupError.modelNotAvailable
        }
        try await backUpModel(model, directory: directory)
    }

    private func apply(_ user: GIDGoogleUser) {
        isSignedIn = true
        accountEmail = user.profile?.email
        status = "CONNECTED"
        if let email = user.profile?.email {
            detail = "Drive connected as \(email)."
        } else {
            detail = "Google Drive connected."
        }
    }

    private func applyCurrentUserState() {
        isSignedIn = true
        accountEmail = GIDSignIn.sharedInstance.currentUser?.profile?.email
        status = "CONNECTED"
        if let email = accountEmail {
            detail = "Drive connected as \(email)."
        } else {
            detail = "Google Drive connected."
        }
    }

    private func refreshedAccessToken(for user: GIDGoogleUser) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshed, error in
                if let refreshed {
                    continuation.resume(returning: refreshed.accessToken.tokenString)
                } else {
                    continuation.resume(throwing: error ?? DriveBackupError.tokenRefreshFailed)
                }
            }
        }
    }

    private func ensureFolder(accessToken: String) async throws -> String {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "name='SENSEI Models' and mimeType='application/vnd.google-apps.folder' and trashed=false"),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.requireSuccess(response)
        if let listing = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = listing["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String { return id }

        var create = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        create.httpMethod = "POST"
        create.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "SENSEI Models",
            "mimeType": "application/vnd.google-apps.folder"
        ])
        let (created, createdResponse) = try await URLSession.shared.data(for: create)
        try Self.requireSuccess(createdResponse)
        guard let json = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = json["id"] as? String else { throw DriveBackupError.invalidResponse }
        return id
    }

    private func uploadResumable(
        file: URL,
        name: String,
        parentID: String,
        accessToken: String,
        progress: @escaping @MainActor (Int64) -> Void
    ) async throws {
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!)
        start.httpMethod = "POST"
        start.timeoutInterval = 45
        start.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parentID]])
        let (_, startResponse) = try await URLSession.shared.data(for: start)
        try Self.requireSuccess(startResponse)
        guard let http = startResponse as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location) else { throw DriveBackupError.invalidResponse }

        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values.fileSize ?? 0)
        let chunkSize: Int64 = 8 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var offset: Int64 = 0
        while offset < total {
            let length = Int(min(chunkSize, total - offset))
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else {
                throw DriveBackupError.fileReadFailed
            }

            let end = offset + Int64(chunk.count) - 1
            var upload = URLRequest(url: uploadURL)
            upload.httpMethod = "PUT"
            upload.timeoutInterval = 45
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            upload.setValue("bytes \(offset)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")

            let (_, response) = try await URLSession.shared.upload(for: upload, from: chunk)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 308 || (200..<300).contains(http.statusCode)
            else {
                throw DriveBackupError.requestFailed
            }

            offset = end + 1
            await progress(offset)
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

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw DriveBackupError.requestFailed
        }
    }

    private static func presentingViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = root?.presentedViewController { root = presented }
        return root
    }
}

enum DriveBackupError: LocalizedError {
    case noPresenter, notSignedIn, tokenRefreshFailed, invalidResponse, requestFailed, modelNotAvailable, fileReadFailed
    var errorDescription: String? {
        switch self {
        case .noPresenter: "SENSEI could not open Google sign-in."
        case .notSignedIn: "Sign in to Google Drive first."
        case .tokenRefreshFailed: "Google sign-in needs to be refreshed."
        case .invalidResponse: "Google Drive returned an invalid response."
        case .requestFailed: "Google Drive request failed."
        case .modelNotAvailable: "The completed local model could not be found on this iPhone."
        case .fileReadFailed: "SENSEI could not read a local model file for backup."
        }
    }
}
