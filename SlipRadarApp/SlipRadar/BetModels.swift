import Foundation

struct PopularBet: Identifiable, Hashable {
    let id = UUID()
    let matchup: String
    let side: String
    let startTime: String
    let betsPercent: Int
    let moneyPercent: Int?
    let splitDifference: Int?

    var lockScore: Int {
        guard let moneyPercent else { return 0 }
        let agreement = min(betsPercent, moneyPercent)
        let moneyEdge = max(0, moneyPercent - betsPercent)
        return min(99, agreement + moneyEdge)
    }

    var isLock: Bool {
        guard let moneyPercent else { return false }
        let moneyEdge = moneyPercent - betsPercent
        let strongConsensus = betsPercent >= 68 && moneyPercent >= 72
        let moneyConfirmation = moneyEdge >= 3
        let eliteConsensus = betsPercent >= 76 && moneyPercent >= 76
        return (strongConsensus && moneyConfirmation) || eliteConsensus
    }

    var lockReason: String {
        guard let moneyPercent else { return "Insufficient data" }
        let edge = moneyPercent - betsPercent
        if betsPercent >= 76 && moneyPercent >= 76 {
            return "Elite agreement: \(betsPercent)% bets / \(moneyPercent)% money"
        }
        return "Money confirms public side by +\(edge)%"
    }
}

enum SportFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case nfl = "NFL"
    case mlb = "MLB"
    case nba = "NBA"
    case nhl = "NHL"
    case ncaaf = "NCAAF"

    var id: String { rawValue }

    var sourceURL: URL {
        switch self {
        case .all: return URL(string: "https://www.actionnetwork.com/public-betting/")!
        case .nfl: return URL(string: "https://www.actionnetwork.com/nfl/public-betting/")!
        case .mlb: return URL(string: "https://www.actionnetwork.com/mlb/public-betting/")!
        case .nba: return URL(string: "https://www.actionnetwork.com/nba/public-betting/")!
        case .nhl: return URL(string: "https://www.actionnetwork.com/nhl/public-betting/")!
        case .ncaaf: return URL(string: "https://www.actionnetwork.com/ncaaf/public-betting/")!
        }
    }
}

enum SlipRadarError: LocalizedError {
    case noData
    case invalidPage

    var errorDescription: String? {
        switch self {
        case .noData: return "No public betting rows were found yet."
        case .invalidPage: return "SlipRadar could not read the public betting page."
        }
    }
}
