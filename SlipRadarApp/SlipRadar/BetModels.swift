import Foundation

struct PopularBet: Identifiable, Hashable {
    let id = UUID()
    let matchup: String
    let side: String
    let startTime: String
    let betsPercent: Int
    let moneyPercent: Int?
    let splitDifference: Int?
    
    var score: Int {
        let moneyBoost = moneyPercent.map { max(0, $0 - betsPercent) } ?? 0
        return min(100, betsPercent + moneyBoost)
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
