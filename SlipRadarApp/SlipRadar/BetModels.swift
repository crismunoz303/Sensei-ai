import Foundation

enum BetSource: String, CaseIterable, Identifiable, Codable {
    case action = "Action Network"
    case draftKings = "DraftKings"
    var id: String { rawValue }
}

enum OddsMath {
    static func americanValue(from odds: String) -> Double? {
        let cleaned = odds
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        guard let value = Double(cleaned), value != 0 else { return nil }
        return value
    }

    static func impliedProbability(from odds: String) -> Double? {
        guard let value = americanValue(from: odds) else { return nil }
        if value > 0 { return 100.0 * 100.0 / (value + 100.0) }
        let absolute = abs(value)
        return 100.0 * absolute / (absolute + 100.0)
    }

    static func decimalOdds(from odds: String) -> Double? {
        guard let value = americanValue(from: odds) else { return nil }
        if value > 0 { return 1.0 + value / 100.0 }
        return 1.0 + 100.0 / abs(value)
    }
}

struct PopularBet: Identifiable, Hashable {
    let id = UUID()
    let source: BetSource
    let matchup: String
    let side: String
    let market: String
    let startTime: String
    let odds: String?
    let betsPercent: Int
    let moneyPercent: Int?
    let splitDifference: Int?

    var impliedProbability: Double? {
        guard let odds else { return nil }
        return OddsMath.impliedProbability(from: odds)
    }

    var moneyEdge: Int? {
        guard let moneyPercent else { return nil }
        return moneyPercent - betsPercent
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
        case .all: return URL(string: "https://www.actionnetwork.com/public-betting/")!
        case .nfl: return URL(string: "https://www.actionnetwork.com/nfl/public-betting/")!
        case .ncaaf: return URL(string: "https://www.actionnetwork.com/ncaaf/public-betting/")!
        case .nba: return URL(string: "https://www.actionnetwork.com/nba/public-betting/")!
        case .ncaab: return URL(string: "https://www.actionnetwork.com/ncaab/public-betting/")!
        case .mlb: return URL(string: "https://www.actionnetwork.com/mlb/public-betting/")!
        case .nhl: return URL(string: "https://www.actionnetwork.com/nhl/public-betting/")!
        case .wnba: return URL(string: "https://www.actionnetwork.com/wnba/public-betting/")!
        case .soccer: return URL(string: "https://www.actionnetwork.com/soccer/public-betting/")!
        }
    }

    var draftKingsURL: URL {
        var components = URLComponents(string: "https://dknetwork.draftkings.com/draftkings-sportsbook-betting-splits/")!
        components.queryItems = [URLQueryItem(name: "tb_eg", value: draftKingsGroup)]
        return components.url!
    }

    var draftKingsPropsURL: URL {
        var components = URLComponents(string: "https://dknetwork.draftkings.com/draftkings-sportsbook-player-props/")!
        components.queryItems = [URLQueryItem(name: "tb_eg", value: draftKingsGroup)]
        return components.url!
    }

    var contextURL: URL? {
        switch self {
        case .all: return nil
        case .nfl: return URL(string: "https://www.espn.com/nfl/injuries")
        case .ncaaf: return URL(string: "https://www.espn.com/college-football/injuries")
        case .nba: return URL(string: "https://www.espn.com/nba/injuries")
        case .ncaab: return URL(string: "https://www.espn.com/mens-college-basketball/injuries")
        case .mlb: return URL(string: "https://www.espn.com/mlb/injuries")
        case .nhl: return URL(string: "https://www.espn.com/nhl/injuries")
        case .wnba: return URL(string: "https://www.espn.com/wnba/injuries")
        case .soccer: return URL(string: "https://www.espn.com/soccer/injuries")
        }
    }

    private var draftKingsGroup: String {
        switch self {
        case .all: return "0"
        case .nfl: return "NFL"
        case .ncaaf: return "NCAA Football"
        case .nba: return "NBA"
        case .ncaab: return "NCAA Basketball"
        case .mlb: return "MLB"
        case .nhl: return "NHL"
        case .wnba: return "WNBA"
        case .soccer: return "Soccer"
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

enum AppSection: String, CaseIterable, Identifiable {
    case locks = "Locks"
    case teams = "Teams"
    case props = "Props"
    case slip = "My Slip"
    case performance = "Track"

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

    var id: String { [event, market, line, odds].joined(separator: "|") }

    var impliedProbability: Double? {
        OddsMath.impliedProbability(from: odds)
    }

    var playerName: String {
        let candidates = [line, market]
        for candidate in candidates {
            let lower = candidate.lowercased()
            if let range = lower.range(of: " over ") ?? lower.range(of: " under ") {
                let prefix = String(candidate[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if prefix.split(separator: " ").count >= 2 { return prefix }
            }
            if let dash = candidate.range(of: " - ") {
                let prefix = String(candidate[..<dash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if prefix.split(separator: " ").count >= 2 { return prefix }
            }
        }
        return ""
    }
}

enum PickVerdict: String, Codable, CaseIterable {
    case lock = "LOCK"
    case strong = "STRONG"
    case consider = "CONSIDER"
    case pass = "PASS"

    var rank: Int {
        switch self {
        case .lock: return 4
        case .strong: return 3
        case .consider: return 2
        case .pass: return 1
        }
    }
}

struct DecisionReport {
    let fairProbability: Double?
    let marketProbability: Double?
    let evidenceScore: Int
    let dataQuality: Int
    let sourceCount: Int
    let verdict: PickVerdict
    let reasons: [String]
    let risks: [String]
}

struct ScoredBet: Identifiable {
    let bet: PopularBet
    let report: DecisionReport
    var id: UUID { bet.id }
}

struct ScoredProp: Identifiable {
    let prop: PropPick
    let report: DecisionReport
    var id: String { prop.id }
}

struct SlipLeg: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let subtitle: String
    let source: String
    let signal: String
    let event: String
    let market: String
    let odds: String?
    let probability: Double?
    let evidenceScore: Int
}
