import Foundation

enum BetSource: String, CaseIterable, Identifiable {
    case action = "Action Network"
    case draftKings = "DraftKings"

    var id: String { rawValue }
}

struct PopularBet: Identifiable, Hashable {
    let id = UUID()
    let source: BetSource
    let matchup: String
    let side: String
    let market: String
    let startTime: String
    let betsPercent: Int
    let moneyPercent: Int?
    let splitDifference: Int?

    var lockScore: Int {
        guard let moneyPercent else { return min(85, betsPercent) }
        let confirmation = max(0, moneyPercent - betsPercent)
        return min(99, max(betsPercent, moneyPercent) + confirmation / 2)
    }

    var isLock: Bool {
        guard let moneyPercent else {
            return betsPercent >= 82
        }
        let edge = moneyPercent - betsPercent
        let strongConsensus = betsPercent >= 65 && moneyPercent >= 70
        let sharpMoney = moneyPercent >= 68 && edge >= 8
        let eliteConsensus = betsPercent >= 78 && moneyPercent >= 78
        return strongConsensus || sharpMoney || eliteConsensus
    }

    var lockReason: String {
        guard let moneyPercent else {
            return "\(betsPercent)% of bets"
        }
        let edge = moneyPercent - betsPercent
        if edge >= 8 {
            return "\(moneyPercent)% money vs \(betsPercent)% bets (+\(edge)%)"
        }
        return "\(betsPercent)% bets / \(moneyPercent)% money"
    }
}

enum SportFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case nfl = "NFL"
    case ncaaf = "NCAAF"
    case nba = "NBA"
    case ncaab = "NCAAB"
    case mlb = "MLB"
    case nhl = "NHL"
    case wnba = "WNBA"
    case soccer = "Soccer"

    var id: String { rawValue }

    var actionURL: URL {
        switch self {
        case .nfl: return URL(string: "https://www.actionnetwork.com/nfl/public-betting/")!
        case .ncaaf: return URL(string: "https://www.actionnetwork.com/ncaaf/public-betting/")!
        case .nba: return URL(string: "https://www.actionnetwork.com/nba/public-betting/")!
        case .ncaab: return URL(string: "https://www.actionnetwork.com/ncaab/public-betting/")!
        case .mlb: return URL(string: "https://www.actionnetwork.com/mlb/public-betting/")!
        case .nhl: return URL(string: "https://www.actionnetwork.com/nhl/public-betting/")!
        case .wnba: return URL(string: "https://www.actionnetwork.com/wnba/public-betting/")!
        case .soccer: return URL(string: "https://www.actionnetwork.com/soccer/public-betting/")!
        case .all: return URL(string: "https://www.actionnetwork.com/public-betting/")!
        }
    }

    var draftKingsURL: URL {
        let base = "https://dknetwork.draftkings.com/draftkings-sportsbook-betting-splits/"
        let group: String
        switch self {
        case .nfl: group = "NFL"
        case .ncaaf: group = "NCAA Football"
        case .nba: group = "NBA"
        case .ncaab: group = "NCAA Basketball"
        case .mlb: group = "MLB"
        case .nhl: group = "NHL"
        case .wnba: group = "WNBA"
        case .soccer: group = "Soccer"
        case .all: group = "0"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [
            URLQueryItem(name: "tb_edate", value: "n7days"),
            URLQueryItem(name: "tb_eg", value: group)
        ]
        return components.url!
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


enum AppSection: String, CaseIterable, Identifiable {
    case locks = "Locks"
    case props = "Props"
    case slip = "My Slip"
    var id: String { rawValue }
}

struct PropPick: Identifiable, Hashable {
    let event: String
    let eventDate: String
    let market: String
    let line: String
    let odds: String
    let source: String
    let isLock: Bool
    let handlePercent: Double?
    let betPercent: Double?

    var id: String {
        [event, market, line, odds].joined(separator: "|")
    }

    var signalLabel: String {
        isLock ? "LOCK" : "POPULAR"
    }

    var reasonText: String {
        if let handlePercent, let betPercent {
            let diff = handlePercent - betPercent
            return String(format: "%.1f%% handle / %.1f%% bets (%+.1f%%)", handlePercent, betPercent, diff)
        }
        return "Popular public prop"
    }
}

struct SlipLeg: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let source: String
    let signal: String
}
