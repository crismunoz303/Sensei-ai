import Foundation

final class ModelVaultManager: @unchecked Sendable {
    static let shared = ModelVaultManager()

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private let bookmarkKey = "sensei.modelVault.bookmark.v1"
    private let nameKey = "sensei.modelVault.name.v1"

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
        vaultRootURL != nil
    }

    func remember(folder url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()

        do {
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

            let marker = url.appendingPathComponent(".sensei-model-vault.json")
            let markerData = Data(
                #"{"kind":"SENSEI_MODEL_VAULT","version":1}"#.utf8
            )
            try markerData.write(to: marker, options: .atomic)

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
            defaults.set(url.lastPathComponent, forKey: nameKey)
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
