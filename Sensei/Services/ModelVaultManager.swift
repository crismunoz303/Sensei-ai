import Foundation

final class ModelVaultManager: @unchecked Sendable {
    static let shared = ModelVaultManager()

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private let bookmarkKey = "sensei.modelVault.bookmark.v2"
    private let nameKey = "sensei.modelVault.name.v2"

    private var activeURL: URL?
    private var activeScopeStarted = false

    private init() {
        restoreAccess()
    }

    deinit {
        lock.lock()
        let url = activeURL
        let shouldStop = activeScopeStarted
        activeURL = nil
        activeScopeStarted = false
        lock.unlock()

        if shouldStop {
            url?.stopAccessingSecurityScopedResource()
        }
    }

    var vaultRootURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return activeURL
    }

    var displayName: String? {
        defaults.string(forKey: nameKey)
    }

    var isConfigured: Bool {
        guard let url = vaultRootURL else { return false }
        return isSenseiVault(url)
    }

    func makeTemporaryVaultPackage() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SENSEI Model Vault.bundle", isDirectory: true)

        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(
            at: root.appendingPathComponent("Models", isDirectory: true),
            withIntermediateDirectories: true
        )

        let marker = root.appendingPathComponent(".sensei-model-vault.json")
        let markerData = Data(
            #"{"kind":"SENSEI_MODEL_VAULT","version":2}"#.utf8
        )
        try markerData.write(to: marker, options: .atomic)

        return root
    }

    func remember(vault url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()

        do {
            guard isSenseiVault(url) else {
                throw ModelVaultError.notSenseiVault
            }

            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            let models = url.appendingPathComponent("Models", isDirectory: true)
            try fileManager.createDirectory(
                at: models,
                withIntermediateDirectories: true
            )

            lock.lock()
            let oldURL = activeURL
            let oldScopeStarted = activeScopeStarted
            activeURL = url
            activeScopeStarted = started
            lock.unlock()

            if oldScopeStarted, oldURL != url {
                oldURL?.stopAccessingSecurityScopedResource()
            }

            defaults.set(bookmark, forKey: bookmarkKey)
            defaults.set("SENSEI Model Vault", forKey: nameKey)
        } catch {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    func forget() {
        lock.lock()
        let url = activeURL
        let shouldStop = activeScopeStarted
        activeURL = nil
        activeScopeStarted = false
        lock.unlock()

        if shouldStop {
            url?.stopAccessingSecurityScopedResource()
        }

        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: nameKey)
    }

    private func isSenseiVault(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        let marker = url.appendingPathComponent(".sensei-model-vault.json")
        return fileManager.fileExists(atPath: marker.path)
    }

    private func restoreAccess() {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else {
            return
        }

        var stale = false

        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return
        }

        let started = url.startAccessingSecurityScopedResource()

        guard isSenseiVault(url) else {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
            return
        }

        lock.lock()
        activeURL = url
        activeScopeStarted = started
        lock.unlock()

        if stale {
            if let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(refreshed, forKey: bookmarkKey)
            }
        }
    }
}

enum ModelVaultError: LocalizedError {
    case notSenseiVault

    var errorDescription: String? {
        switch self {
        case .notSenseiVault:
            return "That item is not a SENSEI Model Vault."
        }
    }
}
