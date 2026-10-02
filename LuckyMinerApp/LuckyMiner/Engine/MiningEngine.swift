import Foundation

@MainActor
final class MiningEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var hashRate: Double = 0
    @Published private(set) var totalHashes: UInt64 = 0
    @Published private(set) var bestZeroBits: Int = 0
    @Published private(set) var workerCount: Int = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var status = "Stopped"

    private var tasks: [Task<Void, Never>] = []
    private var monitorTask: Task<Void, Never>?
    private var sessionHashes: UInt64 = 0
    private var lastRateHashes: UInt64 = 0
    private var lastRateTime = Date()

    func start(mode: MiningMode, governor: ThermalGovernor) {
        guard !isRunning else { return }

        isRunning = true
        startedAt = Date()
        sessionHashes = 0
        lastRateHashes = 0
        lastRateTime = Date()
        totalHashes = 0
        hashRate = 0
        bestZeroBits = 0
        status = "Mining local SHA-256d work"

        restartWorkers(mode: mode, governor: governor)

        monitorTask = Task { [weak self, weak governor] in
            while let self, let governor, self.isRunning, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                governor.refresh()

                let requested = mode.requestedWorkers(
                    coreCount: ProcessInfo.processInfo.activeProcessorCount
                )
                let allowed = governor.allowedWorkers(requested: requested)

                if allowed == 0 {
                    self.stop(reason: "Stopped: critical thermal state")
                    return
                }

                if allowed != self.workerCount {
                    self.restartWorkers(mode: mode, governor: governor)
                }

                let now = Date()
                let elapsed = max(0.001, now.timeIntervalSince(self.lastRateTime))
                let delta = self.sessionHashes &- self.lastRateHashes

                self.hashRate = Double(delta) / elapsed
                self.totalHashes = self.sessionHashes
                self.lastRateHashes = self.sessionHashes
                self.lastRateTime = now
            }
        }
    }

    func stop(reason: String = "Stopped") {
        isRunning = false
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        monitorTask?.cancel()
        monitorTask = nil
        workerCount = 0
        hashRate = 0
        status = reason
    }

    private func restartWorkers(mode: MiningMode, governor: ThermalGovernor) {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()

        let requested = mode.requestedWorkers(
            coreCount: ProcessInfo.processInfo.activeProcessorCount
        )
        let allowed = governor.allowedWorkers(requested: requested)

        workerCount = allowed
        guard allowed > 0 else { return }

        for worker in 0..<allowed {
            let task = Task.detached(
                priority: mode == .max ? .userInitiated : .utility
            ) { [weak self] in
                var header = BitcoinHasher.benchmarkHeader()
                var nonce = UInt32(worker) &* 0x10000000
                var localHashes: UInt64 = 0
                var localBest = 0

                while !Task.isCancelled {
                    BitcoinHasher.writeNonceLE(nonce, into: &header)
                    let digest = BitcoinHasher.hashHeader(header)
                    let zeroBits = BitcoinHasher.leadingZeroBits(digest)

                    localBest = max(localBest, zeroBits)
                    localHashes &+= 1
                    nonce &+= UInt32(allowed)

                    if localHashes % 1024 == 0 {
                        let reportHashes = localHashes
                        let reportBest = localBest

                        localHashes = 0

                        await MainActor.run {
                            guard let self, self.isRunning else { return }
                            self.sessionHashes &+= reportHashes
                            self.bestZeroBits = max(self.bestZeroBits, reportBest)
                        }
                    }
                }
            }

            tasks.append(task)
        }
    }
}
