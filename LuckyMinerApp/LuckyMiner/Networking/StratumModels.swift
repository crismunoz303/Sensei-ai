import Foundation

struct PoolConfiguration: Codable, Equatable {
    var host: String = ""
    var port: UInt16 = 3333
    var username: String = ""
    var password: String = "x"

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum StratumConnectionState: Equatable {
    case disconnected
    case connecting
    case subscribed
    case authorized
    case failed(String)
}
