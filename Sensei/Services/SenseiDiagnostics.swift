import Foundation
import Darwin
import UIKit

struct SenseiDiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: String
    let operationID: String?
    let model: String?
    let stage: String
    let message: String
    let residentMemoryBytes: UInt64?
    let thermalState: String?
    let lowPowerMode: Bool?
    let systemUptime: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, level, operationID, model, stage, message
        case residentMemoryBytes, thermalState, lowPowerMode, systemUptime
    }

    init(
        id: UUID, timestamp: Date, level: String, operationID: String?,
        model: String?, stage: String, message: String,
        residentMemoryBytes: UInt64?, thermalState: String? = nil,
        lowPowerMode: Bool? = nil, systemUptime: TimeInterval? = nil
    ) {
        self.id = id; self.timestamp = timestamp; self.level = level
        self.operationID = operationID; self.model = model; self.stage = stage
        self.message = message; self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState; self.lowPowerMode = lowPowerMode
        self.systemUptime = systemUptime
    }

    init(from decoder: Decoder) throws {
        let x = try decoder.container(keyedBy: CodingKeys.self)
        id = try x.decode(UUID.self, forKey: .id)
        timestamp = try x.decode(Date.self, forKey: .timestamp)
        level = try x.decode(String.self, forKey: .level)
        operationID = try x.decodeIfPresent(String.self, forKey: .operationID)
        model = try x.decodeIfPresent(String.self, forKey: .model)
        stage = try x.decode(String.self, forKey: .stage)
        message = try x.decode(String.self, forKey: .message)
        residentMemoryBytes = try x.decodeIfPresent(UInt64.self, forKey: .residentMemoryBytes)
        thermalState = try x.decodeIfPresent(String.self, forKey: .thermalState)
        lowPowerMode = try x.decodeIfPresent(Bool.self, forKey: .lowPowerMode)
        systemUptime = try x.decodeIfPresent(TimeInterval.self, forKey: .systemUptime)
    }
}

@MainActor
final class SenseiDiagnostics: ObservableObject {
    static let shared = SenseiDiagnostics()

    @Published private(set) var events: [SenseiDiagnosticEvent] = []
    @Published private(set) var suspectedInterruptedLoad: SenseiDiagnosticEvent?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxEvents = 500
    private var thermalObserver: NSObjectProtocol?
    private var memoryWarningObserver: NSObjectProtocol?
    private var persistenceTask: Task<Void, Never>?
    private var performanceTask: Task<Void, Never>?
    private var performanceSessionID: String?
    private var performanceModel: String?
    private var performanceMode: String?
    private var performanceStartedAt: Date?
    private var sessionStartMemory: UInt64?
    private var sessionPeakMemory: UInt64?
    private var sessionStartThermal: String?
    private var sessionWorstThermal: String?

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        events = readEvents()
        recoverInterruptedOperationIfNeeded()
        recoverInterruptedGenerationIfNeeded()
        record(stage: "APP_LAUNCHED", message: "SENSEI launched.", level: "INFO")
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.record(
                    operationID: self?.performanceSessionID,
                    model: self?.performanceModel,
                    stage: "IOS_MEMORY_WARNING",
                    message: "iOS delivered a memory warning while SENSEI was running. This is direct evidence of memory pressure, but does not by itself identify which allocation caused it.",
                    level: "WARNING"
                )
            }
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.captureThermalTransition() }
        }
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
            residentMemoryBytes: Self.residentMemoryBytes(),
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        schedulePersistence()
    }

    func startPerformanceSession(model: String?, mode: String) -> String {
        stopPerformanceSession(outcome: "REPLACED")
        let id = UUID().uuidString
        performanceSessionID = id
        performanceModel = model
        performanceMode = mode
        performanceStartedAt = Date()
        sessionStartMemory = Self.residentMemoryBytes()
        sessionPeakMemory = sessionStartMemory
        sessionStartThermal = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        sessionWorstThermal = sessionStartThermal
        record(operationID: id, model: model, stage: "PERFORMANCE_SESSION_STARTED",
               message: "Performance trace started. Mode: \(mode). Thermal, memory, power state and elapsed time will be sampled.",
               level: "INFO")
        performanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.performanceSessionID == id else { break }
                self.recordPerformanceSample()
            }
        }
        return id
    }

    func markFirstOutput(operationID: String) {
        guard performanceSessionID == operationID, let start = performanceStartedAt else { return }
        record(operationID: operationID, model: performanceModel, stage: "FIRST_OUTPUT",
               message: String(format: "First generated output observed %.3f seconds after the diagnostic session began.", Date().timeIntervalSince(start)),
               level: "SUCCESS")
    }

    func stopPerformanceSession(outcome: String) {
        guard let id = performanceSessionID else { return }
        performanceTask?.cancel()
        performanceTask = nil
        recordPerformanceSample(stage: "PERFORMANCE_FINAL_SAMPLE")
        let elapsed = performanceStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let endMemory = Self.residentMemoryBytes()
        let deltaMB: Double? = {
            guard let start = sessionStartMemory, let endMemory else { return nil }
            return Double(Int64(endMemory) - Int64(start)) / 1_000_000
        }()
        let memorySummary = deltaMB.map { String(format: " RAM delta: %+.1f MB.", $0) } ?? ""
        let thermalSummary = " Thermal: \(sessionStartThermal ?? "UNKNOWN") -> \(sessionWorstThermal ?? "UNKNOWN")."
        record(operationID: id, model: performanceModel, stage: "PERFORMANCE_SESSION_ENDED",
               message: String(format: "Performance trace ended after %.2f seconds. Outcome: %@. Mode: %@.%@%@", elapsed, outcome, performanceMode ?? "UNKNOWN", memorySummary, thermalSummary),
               level: outcome == "SUCCESS" ? "SUCCESS" : "INFO")
        classifyCompletedSession(operationID: id)
        performanceSessionID = nil; performanceModel = nil; performanceMode = nil; performanceStartedAt = nil
        sessionStartMemory = nil; sessionPeakMemory = nil; sessionStartThermal = nil; sessionWorstThermal = nil
        persistEventsNow()
    }

    private func recordPerformanceSample(stage: String = "PERFORMANCE_SAMPLE") {
        guard let id = performanceSessionID else { return }
        let elapsed = performanceStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if let memory = Self.residentMemoryBytes() {
            sessionPeakMemory = max(sessionPeakMemory ?? memory, memory)
        }
        let currentThermal = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        if Self.thermalRank(currentThermal) > Self.thermalRank(sessionWorstThermal ?? "UNKNOWN") {
            sessionWorstThermal = currentThermal
        }
        record(operationID: id, model: performanceModel, stage: stage,
               message: String(format: "Runtime sample at +%.1fs. Mode: %@.", elapsed, performanceMode ?? "UNKNOWN"))
    }

    private func captureThermalTransition() {
        let state = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        if Self.thermalRank(state) > Self.thermalRank(sessionWorstThermal ?? "UNKNOWN") {
            sessionWorstThermal = state
        }
        record(operationID: performanceSessionID, model: performanceModel, stage: "THERMAL_STATE_CHANGED",
               message: "iOS thermal state changed to \(state).", level: state == "SERIOUS" || state == "CRITICAL" ? "WARNING" : "INFO")
    }

    private func classifyCompletedSession(operationID: String) {
        let sessionEvents = events.filter { $0.operationID == operationID }
        let peak = sessionEvents.compactMap(\.residentMemoryBytes).max() ?? sessionPeakMemory
        let first = sessionStartMemory
        let worst = sessionWorstThermal ?? sessionEvents.compactMap(\.thermalState).max(by: { Self.thermalRank($0) < Self.thermalRank($1) }) ?? "UNKNOWN"
        var findings: [String] = []

        if worst == "SERIOUS" || worst == "CRITICAL" {
            findings.append("Elevated iOS thermal pressure was observed (\(worst)). This can coincide with reduced system performance; the trace alone does not prove it caused a slowdown.")
        }
        if let first, let peak {
            let growth = Int64(peak) - Int64(first)
            if growth > 500_000_000 {
                findings.append(String(format: "Resident memory increased by at least %.2f GB during the session. Review model residency, swapping, caches, and temporary allocations.", Double(growth) / 1_000_000_000))
            }
        }
        if sessionEvents.contains(where: { $0.stage.contains("ERROR") }) {
            findings.append("An explicit application error was captured during this session; inspect the ERROR event and its neighboring checkpoints.")
        }
        if sessionEvents.contains(where: { $0.stage == "BENCHMARK_STILL_RUNNING" }) {
            findings.append("The on-device benchmark exceeded the 20-second stall checkpoint.")
        }
        if findings.isEmpty {
            findings.append("No high-confidence thermal, large-memory-growth, explicit-error, or benchmark-stall signal was captured. This does not rule out UI/render, inference, I/O, or OS-level issues.")
        }

        record(operationID: operationID, model: performanceModel, stage: "DIAGNOSTIC_CLASSIFICATION",
               message: findings.joined(separator: " "), level: findings.count > 1 || worst == "SERIOUS" || worst == "CRITICAL" ? "WARNING" : "INFO")
    }

    func beginGenerationCheckpoint(operationID: String, model: String?, mode: String) {
        let event = SenseiDiagnosticEvent(
            id: UUID(), timestamp: Date(), level: "ACTIVE",
            operationID: operationID, model: model, stage: "GENERATION_ACTIVE",
            message: "Generation began in \(mode) mode.",
            residentMemoryBytes: Self.residentMemoryBytes(),
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
        if let data = try? encoder.encode(event) {
            try? data.write(to: activeGenerationURL, options: [.atomic])
        }
    }

    func clearGenerationCheckpoint() {
        try? fileManager.removeItem(at: activeGenerationURL)
    }

    private func recoverInterruptedGenerationIfNeeded() {
        guard
            let data = try? Data(contentsOf: activeGenerationURL),
            let event = try? decoder.decode(SenseiDiagnosticEvent.self, from: data)
        else { return }

        let recovered = SenseiDiagnosticEvent(
            id: UUID(), timestamp: Date(), level: "CRITICAL",
            operationID: event.operationID, model: event.model,
            stage: "PROCESS_ENDED_DURING_GENERATION",
            message: "The previous SENSEI process ended while a generation was active. Last persisted state: \(event.message) This establishes that the process ended during generation, but does not by itself identify whether the cause was memory pressure, thermal pressure, a native MLX failure, OS termination, or another process-level event.",
            residentMemoryBytes: Self.residentMemoryBytes(),
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
        events.insert(recovered, at: 0)
        persistEventsNow()
        clearGenerationCheckpoint()
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
            "Current thermal state: \(Self.thermalStateName(ProcessInfo.processInfo.thermalState))",
            "Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "OFF")",
            ""
        ]

        let thermalCounts = Dictionary(grouping: events.compactMap { $0.thermalState }, by: { $0 }).mapValues(\.count)
        let peakMemory = events.compactMap { $0.residentMemoryBytes }.max()
        lines += [
            "SESSION SUMMARY",
            "Thermal samples: \(thermalCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))",
            peakMemory.map { String(format: "Peak observed resident memory: %.3f GB", Double($0) / 1_000_000_000) } ?? "Peak observed resident memory: unavailable",
            "Note: correlations in this report are observations; they do not by themselves prove root cause.",
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
            if let thermal = event.thermalState { lines.append("THERMAL_STATE: \(thermal)") }
            if let lowPower = event.lowPowerMode { lines.append("LOW_POWER_MODE: \(lowPower ? "ON" : "OFF")") }
            if let uptime = event.systemUptime { lines.append(String(format: "SYSTEM_UPTIME_SECONDS: %.1f", uptime)) }
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

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.persistEventsNow()
        }
    }

    private func persistEvents() { persistEventsNow() }

    private func persistEventsNow() {
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

    private var activeGenerationURL: URL {
        diagnosticsDirectory.appendingPathComponent("active-generation.json")
    }

    private static func thermalRank(_ state: String) -> Int {
        switch state {
        case "NOMINAL": return 0
        case "FAIR": return 1
        case "SERIOUS": return 2
        case "CRITICAL": return 3
        default: return -1
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "NOMINAL"
        case .fair: return "FAIR"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "UNKNOWN"
        }
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
