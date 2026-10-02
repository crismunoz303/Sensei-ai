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

struct StratumJob: Equatable, Sendable {
    let jobId: String
    let prevHash: String
    let coinbase1: String
    let coinbase2: String
    let merkleBranches: [String]
    let version: String
    let nbits: String
    let ntime: String
    let cleanJobs: Bool
    let generation: UInt64
}

struct StratumShare: Sendable {
    let worker: String
    let jobId: String
    let extraNonce2: String
    let ntime: String
    let nonce: String
    let hashHex: String
    let blockCandidate: Bool
}
