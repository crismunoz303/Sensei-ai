import Foundation
import Combine

private final class HashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var bestLeadingZeroBits: Int = 0
    private var bestHashHex: String = "—"

    func record(hash: Data, count: UInt64 = 1) {
        let zeros = Self.leadingZeroBits(hash)
        lock.lock()
        value &+= count
        if zeros > bestLeadingZeroBits {
            bestLeadingZeroBits = zeros
            bestHashHex = hash.hexString
        }
        lock.unlock()
    }

    func snapshot() -> (hashes: UInt64, bestBits: Int, bestHash: String) {
        lock.lock()
        defer { lock.unlock() }
        return (value, bestLeadingZeroBits, bestHashHex)
    }

    private static func leadingZeroBits(_ data: Data) -> Int {
        var total = 0
        for byte in data {
            if byte == 0 {
                total += 8
            } else {
                total += byte.leadingZeroBitCount
                break
            }
        }
        return total
    }
}

@MainActor
final class MiningEngine: ObservableObject {
    @Published private(set) var isMining = false
    @Published private(set) var hashRate: Double = 0
    @Published private(set) var totalHashes: UInt64 = 0
    @Published private(set) var bestLeadingZeroBits = 0
    @Published private(set) var bestHash = "—"
    @Published private(set) var sessionSeconds: TimeInterval = 0
    @Published var mode: MiningMode = .balanced
    @Published var autoThermalThrottle = true

    let thermal = ThermalGovernor()

    private let counter = HashCounter()
    private var runID = UUID()
    private var sampleTimer: Timer?
    private var sessionStart: Date?
    private var lastSampleDate = Date()
    private var lastSampleHashes: UInt64 = 0

    init() {
        precondition(BitcoinHasher.selfTest(), "SHA-256d self-test failed")
    }

    func start() {
        guard !isMining else { return }

        thermal.refresh()
        if thermal.shouldEmergencyStop { return }

        runID = UUID()
        let activeRun = runID
        sessionStart = Date()
        lastSampleDate = Date()
        lastSampleHashes = counter.snapshot().hashes
        hashRate = 0
        isMining = true

        let chosenMode = effectiveMode
        for worker in 0..<chosenMode.workerCount {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.mineLoop(worker: worker, runID: activeRun, mode: chosenMode)
            }
        }

        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        guard isMining else { return }
        isMining = false
        runID = UUID()
        sampleTimer?.invalidate()
        sampleTimer = nil
        sample()
        hashRate = 0
    }

    private var effectiveMode: MiningMode {
        guard autoThermalThrottle else { return mode }
        let recommendation = thermal.recommendedMode
        switch (mode, recommendation) {
        case (.max, .balanced), (.max, .eco), (.balanced, .eco):
            return recommendation
        default:
            return mode
        }
    }

    nonisolated private func mineLoop(worker: Int, runID: UUID, mode: MiningMode) {
        var seed = Data(repeating: 0, count: 76)
        var workerLE = UInt32(worker).littleEndian
        withUnsafeBytes(of: &workerLE) { bytes in
            seed.replaceSubrange(0..<4, with: bytes)
        }

        var nonce = UInt32(worker)
        let stride = UInt32(max(1, mode.workerCount))
        let burst = 2_048
        let restNanoseconds = mode.dutyCycle >= 1
            ? UInt64(0)
            : UInt64((1.0 - mode.dutyCycle) * 8_000_000)

        while true {
            let shouldContinue = DispatchQueue.main.sync { [weak self] in
                guard let self else { return false }
                return self.isMining && self.runID == runID && !self.thermal.shouldEmergencyStop
            }
            if !shouldContinue { return }

            for _ in 0..<burst {
                let hash = BitcoinHasher.hashHeader(prefix76: seed, nonce: nonce)
                counter.record(hash: hash)
                nonce &+= stride
            }

            if restNanoseconds > 0 {
                Thread.sleep(forTimeInterval: Double(restNanoseconds) / 1_000_000_000)
            }
        }
    }

    private func sample() {
        thermal.refresh()

        if isMining && thermal.shouldEmergencyStop {
            stop()
            return
        }

        let now = Date()
        let snapshot = counter.snapshot()
        let elapsed = max(0.001, now.timeIntervalSince(lastSampleDate))
        let delta = snapshot.hashes &- lastSampleHashes

        hashRate = Double(delta) / elapsed
        totalHashes = snapshot.hashes
        bestLeadingZeroBits = snapshot.bestBits
        bestHash = snapshot.bestHash
        sessionSeconds = sessionStart.map { now.timeIntervalSince($0) } ?? 0
        lastSampleDate = now
        lastSampleHashes = snapshot.hashes
    }
}
