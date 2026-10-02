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
    @Published private(set) var activeJobId = ""
    @Published private(set) var blockCandidates: UInt64 = 0

    private var tasks: [Task<Void, Never>] = []
    private var monitorTask: Task<Void, Never>?
    private var sessionHashes: UInt64 = 0
    private var lastRateHashes: UInt64 = 0
    private var lastRateTime = Date()
    private var activeGeneration: UInt64?
    private var extraNonce2Counter: UInt64 = 0

    func start(
        mode: MiningMode,
        governor: ThermalGovernor,
        stratum: StratumClient
    ) {
        guard !isRunning else { return }

        guard stratum.state == .authorized else {
            status = "Connect and authorize a pool first"
            return
        }

        isRunning = true
        startedAt = Date()
        sessionHashes = 0
        lastRateHashes = 0
        lastRateTime = Date()
        totalHashes = 0
        hashRate = 0
        bestZeroBits = 0
        workerCount = 0
        activeGeneration = nil
        activeJobId = ""
        blockCandidates = 0
        extraNonce2Counter = 0
        status = "Waiting for pool job"

        monitorTask = Task { [weak self, weak governor, weak stratum] in
            while let self,
                  let governor,
                  let stratum,
                  self.isRunning,
                  !Task.isCancelled {

                try? await Task.sleep(nanoseconds: 250_000_000)
                governor.refresh()

                guard stratum.state == .authorized else {
                    self.stop(reason: "Stopped: pool disconnected")
                    return
                }

                let requested = mode.requestedWorkers(
                    coreCount: ProcessInfo.processInfo.activeProcessorCount
                )
                let allowed = governor.allowedWorkers(requested: requested)

                if allowed == 0 {
                    self.stop(reason: "Stopped: critical thermal state")
                    return
                }

                guard
                    let job = stratum.currentJob,
                    !stratum.extraNonce1.isEmpty,
                    stratum.extraNonce2Size > 0,
                    stratum.currentDifficulty > 0
                else {
                    self.status = "Waiting for pool job"
                    continue
                }

                let mustRestart =
                    self.activeGeneration != job.generation ||
                    self.workerCount != allowed

                if mustRestart {
                    do {
                        let work = try StratumWorkBuilder.prepare(
                            job: job,
                            extraNonce1: stratum.extraNonce1,
                            extraNonce2Size: stratum.extraNonce2Size,
                            difficulty: stratum.currentDifficulty,
                            extraNonce2Counter: self.extraNonce2Counter
                        )

                        self.extraNonce2Counter &+= 1
                        self.activeGeneration = job.generation
                        self.activeJobId = job.jobId
                        self.launchWorkers(
                            work: work,
                            workers: allowed,
                            mode: mode,
                            stratum: stratum
                        )
                        self.status = "Mining pool job " + job.jobId
                    } catch {
                        self.stop(
                            reason: "Stopped: " + error.localizedDescription
                        )
                        return
                    }
                }

                let now = Date()
                let elapsed = Swift.max(
                    0.001,
                    now.timeIntervalSince(self.lastRateTime)
                )
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
        activeGeneration = nil
        activeJobId = ""
        status = reason
    }

    private func launchWorkers(
        work: PreparedStratumWork,
        workers: Int,
        mode: MiningMode,
        stratum: StratumClient
    ) {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()

        workerCount = workers
        guard workers > 0 else { return }

        for worker in 0..<workers {
            let task = Task.detached(
                priority: mode == .max ? .userInitiated : .utility
            ) { [weak self, weak stratum] in
                var nonce = UInt32(worker)
                let stride = UInt32(workers)
                var localHashes: UInt64 = 0
                var localBest = 0

                while !Task.isCancelled {
                    let header = StratumWorkBuilder.header(
                        work,
                        nonce: nonce
                    )
                    let digest = SHA256Core.doubleHash(header)
                    let zeroBits = BitcoinHasher.leadingZeroBits(digest)
                    let numericValue = StratumWorkBuilder.numericHashValue(
                        digest
                    )

                    localBest = Swift.max(localBest, zeroBits)
                    localHashes &+= 1

                    if numericValue <= work.shareTarget {
                        let share = StratumShare(
                            worker: await MainActor.run {
                                stratum?.workerName ?? ""
                            },
                            jobId: work.job.jobId,
                            extraNonce2: work.extraNonce2,
                            ntime: work.job.ntime,
                            nonce: String(format: "%08x", nonce),
                            hashHex: HexCodec.hex(Array(digest.reversed())),
                            blockCandidate:
                                work.networkTarget > 0 &&
                                numericValue <= work.networkTarget
                        )

                        await MainActor.run {
                            guard let self,
                                  self.isRunning,
                                  self.activeGeneration == work.job.generation,
                                  let stratum
                            else {
                                return
                            }

                            if share.blockCandidate {
                                self.blockCandidates &+= 1
                            }

                            stratum.submitShare(share)
                        }
                    }

                    nonce &+= stride

                    if localHashes % 512 == 0 {
                        let reportHashes = localHashes
                        let reportBest = localBest
                        localHashes = 0
                        localBest = 0

                        await MainActor.run {
                            guard let self,
                                  self.isRunning,
                                  self.activeGeneration == work.job.generation
                            else {
                                return
                            }

                            self.sessionHashes &+= reportHashes
                            self.bestZeroBits = Swift.max(
                                self.bestZeroBits,
                                reportBest
                            )
                        }
                    }
                }
            }

            tasks.append(task)
        }
    }
}
