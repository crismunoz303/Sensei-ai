import Foundation
import Network

@MainActor
final class StratumClient: ObservableObject {
    @Published private(set) var state: StratumConnectionState = .disconnected
    @Published private(set) var extraNonce1: String = ""
    @Published private(set) var extraNonce2Size: Int = 0
    @Published private(set) var currentDifficulty: Double = 0
    @Published private(set) var currentJob: StratumJob?
    @Published private(set) var acceptedShares: UInt64 = 0
    @Published private(set) var rejectedShares: UInt64 = 0
    @Published private(set) var submittedShares: UInt64 = 0
    @Published private(set) var lastMessage: String = ""
    @Published private(set) var lastShareResult: String = "No shares submitted"

    private var connection: NWConnection?
    private var buffer = Data()
    private var config: PoolConfiguration?
    private var nextRequestId = 10
    private var pendingSubmitIds = Set<Int>()
    private var jobGeneration: UInt64 = 0

    var workerName: String {
        config?.username ?? ""
    }

    func connect(_ config: PoolConfiguration) {
        disconnect()

        guard config.isComplete else {
            state = .failed("Pool host and username are required")
            return
        }

        self.config = config
        acceptedShares = 0
        rejectedShares = 0
        submittedShares = 0
        lastShareResult = "No shares submitted"
        currentJob = nil
        currentDifficulty = 0
        extraNonce1 = ""
        extraNonce2Size = 0
        state = .connecting

        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            state = .failed("Invalid pool port")
            return
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: port,
            using: .tcp
        )

        connection = conn

        conn.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor in
                guard let self else { return }

                switch nwState {
                case .ready:
                    self.send(
                        id: 1,
                        method: "mining.subscribe",
                        params: ["LuckyMiner/0.2.0"]
                    )
                    self.receiveLoop()

                case .failed(let error):
                    self.state = .failed(error.localizedDescription)

                case .cancelled:
                    self.state = .disconnected

                default:
                    break
                }
            }
        }

        conn.start(
            queue: DispatchQueue(
                label: "LuckyMiner.Stratum",
                qos: .utility
            )
        )
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        pendingSubmitIds.removeAll()
        currentJob = nil
        state = .disconnected
    }

    func submitShare(_ share: StratumShare) {
        guard state == .authorized, let connection else { return }

        let requestId = nextRequestId
        nextRequestId += 1
        pendingSubmitIds.insert(requestId)
        submittedShares &+= 1
        lastShareResult = share.blockCandidate
            ? "Submitting block candidate…"
            : "Submitting share…"

        let object: [String: Any] = [
            "id": requestId,
            "method": "mining.submit",
            "params": [
                share.worker,
                share.jobId,
                share.extraNonce2,
                share.ntime,
                share.nonce
            ]
        ]

        guard var data = try? JSONSerialization.data(withJSONObject: object) else {
            pendingSubmitIds.remove(requestId)
            rejectedShares &+= 1
            lastShareResult = "Failed to encode share"
            return
        }

        data.append(0x0a)

        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if self.pendingSubmitIds.remove(requestId) != nil {
                        self.rejectedShares &+= 1
                    }
                    self.lastShareResult = "Submit transport error: " + error.localizedDescription
                }
            }
        )
    }

    private func send(id: Int, method: String, params: [Any]) {
        guard let connection else { return }

        let object: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]

        guard var data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }

        data.append(0x0a)

        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { @MainActor in
                        self?.state = .failed(error.localizedDescription)
                    }
                }
            }
        )
    }

    private func receiveLoop() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let data {
                    self.consume(data)
                }

                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }

                if isComplete {
                    self.disconnect()
                    return
                }

                self.receiveLoop()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)

            guard
                !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(
                    with: Data(line)
                ) as? [String: Any]
            else {
                continue
            }

            handle(object)
        }
    }

    private func handle(_ json: [String: Any]) {
        if let method = json["method"] as? String {
            lastMessage = method

            switch method {
            case "mining.set_difficulty":
                handleDifficulty(json)

            case "mining.set_extranonce":
                handleExtraNonce(json)

            case "mining.notify":
                handleNotify(json)

            default:
                break
            }

            return
        }

        guard let id = (json["id"] as? NSNumber)?.intValue else {
            return
        }

        if pendingSubmitIds.remove(id) != nil {
            let accepted = (json["result"] as? Bool) == true

            if accepted {
                acceptedShares &+= 1
                lastShareResult = "Share accepted"
            } else {
                rejectedShares &+= 1
                lastShareResult = rejectionMessage(json)
            }

            return
        }

        if id == 1,
           let result = json["result"] as? [Any],
           result.count >= 3 {

            extraNonce1 = result[1] as? String ?? ""
            extraNonce2Size = (result[2] as? NSNumber)?.intValue ?? 0
            state = .subscribed

            if let config {
                send(
                    id: 2,
                    method: "mining.authorize",
                    params: [config.username, config.password]
                )
            }

            return
        }

        if id == 2 {
            if (json["result"] as? Bool) == true {
                state = .authorized
                lastMessage = "Authorized"
            } else {
                state = .failed("Pool authorization failed")
            }
        }
    }

    private func handleDifficulty(_ json: [String: Any]) {
        guard
            let params = json["params"] as? [Any],
            let first = params.first,
            let difficulty = (first as? NSNumber)?.doubleValue,
            difficulty > 0,
            difficulty.isFinite
        else {
            return
        }

        currentDifficulty = difficulty
        jobGeneration &+= 1

        if let job = currentJob {
            currentJob = StratumJob(
                jobId: job.jobId,
                prevHash: job.prevHash,
                coinbase1: job.coinbase1,
                coinbase2: job.coinbase2,
                merkleBranches: job.merkleBranches,
                version: job.version,
                nbits: job.nbits,
                ntime: job.ntime,
                cleanJobs: job.cleanJobs,
                generation: jobGeneration
            )
        }
    }

    private func handleExtraNonce(_ json: [String: Any]) {
        guard
            let params = json["params"] as? [Any],
            params.count >= 2,
            let extra = params[0] as? String,
            let size = (params[1] as? NSNumber)?.intValue
        else {
            return
        }

        extraNonce1 = extra
        extraNonce2Size = size
        jobGeneration &+= 1

        if let job = currentJob {
            currentJob = StratumJob(
                jobId: job.jobId,
                prevHash: job.prevHash,
                coinbase1: job.coinbase1,
                coinbase2: job.coinbase2,
                merkleBranches: job.merkleBranches,
                version: job.version,
                nbits: job.nbits,
                ntime: job.ntime,
                cleanJobs: true,
                generation: jobGeneration
            )
        }
    }

    private func handleNotify(_ json: [String: Any]) {
        guard
            let params = json["params"] as? [Any],
            params.count >= 9,
            let jobId = params[0] as? String,
            let prevHash = params[1] as? String,
            let coinbase1 = params[2] as? String,
            let coinbase2 = params[3] as? String,
            let branches = params[4] as? [String],
            let version = params[5] as? String,
            let nbits = params[6] as? String,
            let ntime = params[7] as? String,
            let cleanJobs = params[8] as? Bool
        else {
            lastMessage = "Malformed mining.notify"
            return
        }

        jobGeneration &+= 1

        currentJob = StratumJob(
            jobId: jobId,
            prevHash: prevHash,
            coinbase1: coinbase1,
            coinbase2: coinbase2,
            merkleBranches: branches,
            version: version,
            nbits: nbits,
            ntime: ntime,
            cleanJobs: cleanJobs,
            generation: jobGeneration
        )

        lastMessage = "New job " + jobId
    }

    private func rejectionMessage(_ json: [String: Any]) -> String {
        guard let error = json["error"], !(error is NSNull) else {
            return "Share rejected"
        }

        if let array = error as? [Any], array.count >= 2 {
            return "Share rejected: " + String(describing: array[1])
        }

        return "Share rejected"
    }
}
