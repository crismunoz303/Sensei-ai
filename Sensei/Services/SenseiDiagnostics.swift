import Foundation
import Darwin

struct SenseiDiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: String
    let operationID: String?
    let model: String?
    let stage: String
    let message: String
    let residentMemoryBytes: UInt64?
}

@MainActor
final class SenseiDiagnostics: ObservableObject {
    static let shared = SenseiDiagnostics()

    @Published private(set) var events: [SenseiDiagnosticEvent] = []
    @Published private(set) var suspectedInterruptedLoad: SenseiDiagnosticEvent?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxEvents = 250

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        events = readEvents()
        recoverInterruptedOperationIfNeeded()
        record(stage: "APP_LAUNCHED", message: "SENSEI launched.", level: "INFO")
    }

    var latestSummary: String {
        if let interrupted = suspectedInterruptedLoad {
            return "Previous model load ended unexpectedly after \(interrupted.stage)."
        }
        return events.first?.message ?? "No diagnostics recorded yet."
    }

    func beginModelLoad(model: LocalModelOption) -> String {
        let operationID = UUID().uuidString
        suspectedInterruptedLoad = nil
        writeActiveOperation(
            operationID: operationID,
            model: model.name,
            stage: "LOAD_REQUESTED",
            message: "User requested local model load."
        )
        record(
            operationID: operationID,
            model: model.name,
            stage: "LOAD_REQUESTED",
            message: "Load requested for \(model.name)."
        )
        return operationID
    }

    func checkpoint(
        operationID: String,
        model: LocalModelOption,
        stage: String,
        message: String
    ) {
        writeActiveOperation(
            operationID: operationID,
            model: model.name,
            stage: stage,
            message: message
        )
        record(
            operationID: operationID,
            model: model.name,
            stage: stage,
            message: message
        )
    }

    func completeModelLoad(operationID: String, model: LocalModelOption) {
        record(
            operationID: operationID,
            model: model.name,
            stage: "LOAD_COMPLETE",
            message: "\(model.name) loaded successfully.",
            level: "SUCCESS"
        )
        clearActiveOperation()
        suspectedInterruptedLoad = nil
    }

    func failModelLoad(operationID: String, model: LocalModelOption, error: Error) {
        record(
            operationID: operationID,
            model: model.name,
            stage: "LOAD_ERROR",
            message: error.localizedDescription,
            level: "ERROR"
        )
        clearActiveOperation()
    }

    func record(
        operationID: String? = nil,
        model: String? = nil,
        stage: String,
        message: String,
        level: String = "INFO"
    ) {
        let event = SenseiDiagnosticEvent(
            id: UUID(),
            timestamp: Date(),
            level: level,
            operationID: operationID,
            model: model,
            stage: stage,
            message: message,
            residentMemoryBytes: Self.residentMemoryBytes()
        )
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        persistEvents()
    }

    /// Complete, untruncated text report for debugging/export.
    /// Chat response limits never apply to this file.
    var exportReportURL: URL {
        writeExportReport()
        return diagnosticsDirectory.appendingPathComponent("SENSEI-Diagnostic-Report.txt")
    }

    private func writeExportReport() {
        var lines: [String] = [
            "SENSEI DIAGNOSTIC REPORT",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Events: \(events.count)",
            ""
        ]

        for event in events.reversed() {
            lines.append("------------------------------------------------------------")
            lines.append("TIME: \(ISO8601DateFormatter().string(from: event.timestamp))")
            lines.append("LEVEL: \(event.level)")
            lines.append("STAGE: \(event.stage)")
            if let operationID = event.operationID { lines.append("OPERATION: \(operationID)") }
            if let model = event.model { lines.append("MODEL: \(model)") }
            if let bytes = event.residentMemoryBytes {
                lines.append(String(format: "RESIDENT_MEMORY_GB: %.3f", Double(bytes) / 1_000_000_000))
            }
            lines.append("MESSAGE:")
            lines.append(event.message)
            lines.append("")
        }

        try? lines.joined(separator: "\n").write(
            to: diagnosticsDirectory.appendingPathComponent("SENSEI-Diagnostic-Report.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    func clear() {
        events = []
        suspectedInterruptedLoad = nil
        try? fileManager.removeItem(at: eventsURL)
        clearActiveOperation()
    }

    private func recoverInterruptedOperationIfNeeded() {
        guard
            let data = try? Data(contentsOf: activeOperationURL),
            let event = try? decoder.decode(SenseiDiagnosticEvent.self, from: data)
        else {
            return
        }

        suspectedInterruptedLoad = event
        let recovered = SenseiDiagnosticEvent(
            id: UUID(),
            timestamp: Date(),
            level: "CRITICAL",
            operationID: event.operationID,
            model: event.model,
            stage: "PROCESS_ENDED_DURING_LOAD",
            message: "The previous SENSEI process ended before the model load completed. Last persisted checkpoint: \(event.stage) — \(event.message). This proves where execution stopped; it does not by itself prove whether iOS memory pressure, a native MLX failure, or another process-level termination caused it.",
            residentMemoryBytes: Self.residentMemoryBytes()
        )
        events.insert(recovered, at: 0)
        persistEvents()
        clearActiveOperation()
    }

    private func writeActiveOperation(
        operationID: String,
        model: String,
        stage: String,
        message: String
    ) {
        let event = SenseiDiagnosticEvent(
            id: UUID(),
            timestamp: Date(),
            level: "ACTIVE",
            operationID: operationID,
            model: model,
            stage: stage,
            message: message,
            residentMemoryBytes: Self.residentMemoryBytes()
        )
        if let data = try? encoder.encode(event) {
            try? data.write(to: activeOperationURL, options: [.atomic])
        }
    }

    private func readEvents() -> [SenseiDiagnosticEvent] {
        guard
            let data = try? Data(contentsOf: eventsURL),
            let decoded = try? decoder.decode([SenseiDiagnosticEvent].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func persistEvents() {
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: eventsURL, options: [.atomic])
    }

    private func clearActiveOperation() {
        try? fileManager.removeItem(at: activeOperationURL)
    }

    private var diagnosticsDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("SENSEI-Diagnostics", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var eventsURL: URL {
        diagnosticsDirectory.appendingPathComponent("events.json")
    }

    private var activeOperationURL: URL {
        diagnosticsDirectory.appendingPathComponent("active-model-load.json")
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
