import Foundation
import Network

@MainActor
final class StratumClient: ObservableObject {
    @Published private(set) var state: StratumConnectionState = .disconnected
    @Published private(set) var extraNonce1: String = ""
    @Published private(set) var extraNonce2Size: Int = 0
    @Published private(set) var currentDifficulty: Double = 0
    @Published private(set) var lastMessage: String = ""

    private var connection: NWConnection?
    private var buffer = Data()
    private var config: PoolConfiguration?

    func connect(_ config: PoolConfiguration) {
        disconnect()

        guard config.isComplete else {
            state = .failed("Pool host and username are required")
            return
        }

        self.config = config
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
                        params: ["LuckyMiner/0.1.0"]
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
        state = .disconnected
    }

    private func send(id: Int, method: String, params: [Any]) {
        guard let connection else { return }

        let object: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]

        guard var data = try? JSONSerialization.data(
            withJSONObject: object
        ) else {
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

            if method == "mining.set_difficulty",
               let params = json["params"] as? [Any],
               let first = params.first,
               let difficulty = (first as? NSNumber)?.doubleValue {
                currentDifficulty = difficulty
            }

            return
        }

        if let id = (json["id"] as? NSNumber)?.intValue,
           id == 1,
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

        if let id = (json["id"] as? NSNumber)?.intValue,
           id == 2 {

            if (json["result"] as? Bool) == true {
                state = .authorized
                lastMessage = "Authorized"
            } else {
                state = .failed("Pool authorization failed")
            }
        }
    }
}
