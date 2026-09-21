import Foundation
import MLX

/// Builds a language-only runtime checkpoint from a downloaded unified Qwen 3.5
/// checkpoint without re-downloading the model.
///
/// The mlx-community Qwen3.5 9B checkpoint used by SENSEI includes both the
/// language model and a vision tower. MLX's generic loader materializes every
/// tensor in each safetensors shard before Qwen35Model.sanitize() discards the
/// vision tensors. On iPhone that creates an avoidable multi-gigabyte peak.
///
/// This preparer reads the existing checkpoint lazily and writes only
/// language_model.* tensors into small local safetensor shards. The original
/// download is left untouched.
enum Qwen35TextRuntimePreparer {
    private static let runtimeFolderName = "SENSEI-Text-Runtime-v1"
    private static let readyMarkerName = ".sensei-text-runtime-ready"
    private static let targetShardBytes = 96 * 1024 * 1024
    private static let storageHeadroomBytes: Int64 = 256 * 1024 * 1024

    static func prepare(
        from sourceDirectory: URL,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let runtimeDirectory = sourceDirectory.appendingPathComponent(
            runtimeFolderName,
            isDirectory: true
        )

        if isReady(runtimeDirectory) {
            await progressHandler(0.18)
            return runtimeDirectory
        }

        await progressHandler(0.03)

        let result = try await Task.detached(priority: .userInitiated) {
            try buildRuntime(
                from: sourceDirectory,
                runtimeDirectory: runtimeDirectory
            )
        }.value

        await progressHandler(0.18)
        return result
    }

    private static func isReady(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(readyMarkerName)
        let config = directory.appendingPathComponent("config.json")

        guard fm.fileExists(atPath: marker.path),
              fm.fileExists(atPath: config.path),
              let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              )
        else {
            return false
        }

        return files.contains {
            $0.pathExtension == "safetensors"
                && $0.lastPathComponent.hasPrefix("model-")
        }
    }

    private static func buildRuntime(
        from sourceDirectory: URL,
        runtimeDirectory: URL
    ) throws -> URL {
        let fm = FileManager.default

        let sourceShards = try fm.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.pathExtension == "safetensors"
                && $0.lastPathComponent.hasPrefix("model")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !sourceShards.isEmpty else {
            throw Qwen35TextRuntimeError.noSafetensorsFound
        }

        struct Batch {
            let source: URL
            let keys: [String]
            let logicalBytes: Int64
        }

        var batches: [Batch] = []
        var totalLanguageBytes: Int64 = 0
        var languageTensorCount = 0

        // First pass is lazy: inspect names/shapes and create bounded batches
        // without evaluating the tensor payloads.
        for shard in sourceShards {
            let arrays = try MLX.loadArrays(url: shard, stream: .cpu)

            let languageEntries = arrays
                .filter { key, _ in
                    key.hasPrefix("language_model.")
                        && !key.contains(".mtp.")
                }
                .sorted { $0.key < $1.key }

            guard !languageEntries.isEmpty else { continue }

            var keys: [String] = []
            var bytes: Int64 = 0

            for (key, array) in languageEntries {
                let tensorBytes = Int64(array.nbytes)

                if !keys.isEmpty && bytes + tensorBytes > Int64(targetShardBytes) {
                    batches.append(
                        Batch(source: shard, keys: keys, logicalBytes: bytes)
                    )
                    totalLanguageBytes += bytes
                    keys.removeAll(keepingCapacity: true)
                    bytes = 0
                }

                keys.append(key)
                bytes += tensorBytes
                languageTensorCount += 1
            }

            if !keys.isEmpty {
                batches.append(
                    Batch(source: shard, keys: keys, logicalBytes: bytes)
                )
                totalLanguageBytes += bytes
            }
        }

        guard !batches.isEmpty, languageTensorCount > 0 else {
            throw Qwen35TextRuntimeError.noLanguageTensorsFound
        }

        // We need temporary room for the derived language-only checkpoint.
        // The source checkpoint remains untouched.
        if let available = try? sourceDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            let required = totalLanguageBytes + storageHeadroomBytes
            guard available >= required else {
                throw Qwen35TextRuntimeError.insufficientStorage(
                    requiredBytes: required,
                    availableBytes: available
                )
            }
        }

        let temporaryDirectory = sourceDirectory.appendingPathComponent(
            ".SENSEI-Text-Runtime-\(UUID().uuidString)",
            isDirectory: true
        )

        try fm.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        do {
            try copySupportFiles(
                from: sourceDirectory,
                to: temporaryDirectory
            )

            let shardCount = batches.count
            let digits = max(5, String(shardCount).count)

            for (index, batch) in batches.enumerated() {
                try autoreleasepool {
                    let (allArrays, metadata) = try MLX.loadArraysAndMetadata(
                        url: batch.source,
                        stream: .cpu
                    )

                    var selected: [String: MLXArray] = [:]
                    selected.reserveCapacity(batch.keys.count)

                    for key in batch.keys {
                        guard let value = allArrays[key] else {
                            throw Qwen35TextRuntimeError.missingTensor(key)
                        }
                        selected[key] = value
                    }

                    let number = String(
                        format: "%0\(digits)d",
                        index + 1
                    )
                    let total = String(
                        format: "%0\(digits)d",
                        shardCount
                    )
                    let output = temporaryDirectory.appendingPathComponent(
                        "model-\(number)-of-\(total).safetensors"
                    )

                    try MLX.save(
                        arrays: selected,
                        metadata: metadata,
                        url: output,
                        stream: .cpu
                    )
                }

                MLX.Memory.clearCache()
            }

            let marker = """
            version=1
            language_tensors=\(languageTensorCount)
            logical_bytes=\(totalLanguageBytes)
            source_shards=\(sourceShards.count)
            output_shards=\(batches.count)
            """
            try Data(marker.utf8).write(
                to: temporaryDirectory.appendingPathComponent(readyMarkerName),
                options: .atomic
            )

            if fm.fileExists(atPath: runtimeDirectory.path) {
                try fm.removeItem(at: runtimeDirectory)
            }

            try fm.moveItem(
                at: temporaryDirectory,
                to: runtimeDirectory
            )

            return runtimeDirectory
        } catch {
            try? fm.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private static func copySupportFiles(
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws {
        let fm = FileManager.default

        for item in try fm.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            // The derived directory gets its own text-only weight shards.
            guard item.pathExtension != "safetensors",
                  item.lastPathComponent != "model.safetensors.index.json"
            else {
                continue
            }

            let destination = destinationDirectory.appendingPathComponent(
                item.lastPathComponent
            )
            try fm.copyItem(at: item, to: destination)
        }
    }
}

enum Qwen35TextRuntimeError: LocalizedError {
    case noSafetensorsFound
    case noLanguageTensorsFound
    case missingTensor(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .noSafetensorsFound:
            return "Qwen3.5 9B is marked downloaded, but its safetensor files are missing."
        case .noLanguageTensorsFound:
            return "Qwen3.5 9B downloaded files do not contain the expected language_model tensors."
        case .missingTensor(let key):
            return "Qwen3.5 9B runtime preparation could not read tensor: \(key)"
        case .insufficientStorage(let requiredBytes, let availableBytes):
            let requiredGB = Double(requiredBytes) / 1_000_000_000
            let availableGB = Double(availableBytes) / 1_000_000_000
            return String(
                format: "Qwen3.5 9B needs about %.1f GB of temporary free storage to build its memory-safe text runtime. %.1f GB is currently available.",
                requiredGB,
                availableGB
            )
        }
    }
}
