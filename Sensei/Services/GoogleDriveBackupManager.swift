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

    private let scope = "https://www.googleapis.com/auth/drive.file"
    private let clientID = "934355792148-tlle93u7lt07l9vmj9kpttdfonk3lrer.apps.googleusercontent.com"

    private init() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        restore()
    }

    func restore() {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            Task { @MainActor in
                guard let self else { return }
                if let user {
                    self.apply(user)
                } else if let error {
                    self.status = "SIGN IN NEEDED"
                    self.detail = error.localizedDescription
                }
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
            throw DriveBackupError.notSignedIn
        }

        status = "BACKING UP"
        detail = "Uploading \(model.name) to Google Drive…"

        let refreshed = try await refresh(user)
        let token = refreshed.accessToken.tokenString
        let folderID = try await ensureFolder(accessToken: token)
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .map { directory.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }

        for file in files {
            let relative = file.path.replacingOccurrences(of: directory.path + "/", with: "")
            try await uploadResumable(file: file, name: model.rawValue + "/" + relative, parentID: folderID, accessToken: token)
        }

        status = "BACKED UP"
        detail = "\(model.name) is backed up to Google Drive."
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

    private func refresh(_ user: GIDGoogleUser) async throws -> GIDGoogleUser {
        try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshed, error in
                if let refreshed { continuation.resume(returning: refreshed) }
                else { continuation.resume(throwing: error ?? DriveBackupError.tokenRefreshFailed) }
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

    private func uploadResumable(file: URL, name: String, parentID: String, accessToken: String) async throws {
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parentID]])
        let (_, startResponse) = try await URLSession.shared.data(for: start)
        try Self.requireSuccess(startResponse)
        guard let http = startResponse as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location) else { throw DriveBackupError.invalidResponse }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "PUT"
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: upload, fromFile: file)
        try Self.requireSuccess(response)
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
    case noPresenter, notSignedIn, tokenRefreshFailed, invalidResponse, requestFailed
    var errorDescription: String? {
        switch self {
        case .noPresenter: "SENSEI could not open Google sign-in."
        case .notSignedIn: "Sign in to Google Drive first."
        case .tokenRefreshFailed: "Google sign-in needs to be refreshed."
        case .invalidResponse: "Google Drive returned an invalid response."
        case .requestFailed: "Google Drive request failed."
        }
    }
}
