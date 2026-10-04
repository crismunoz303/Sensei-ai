import Foundation

enum BetSource: String, CaseIterable, Identifiable {
    case action = "Action Network"
    case draftKings = "DraftKings"

    var id: String { rawValue }
}

enum OddsMath {
    static func impliedProbability(from odds: String) -> Double? {
        let cleaned = odds
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        guard let value = Double(cleaned) else { return nil }

        if value > 0 {
            return 100.0 * (100.0 / (value + 100.0))
        } else if value < 0 {
            let absolute = abs(value)
            return 100.0 * (absolute / (absolute + 100.0))
        }
        return nil
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

    var impliedProbability: Double? {
        guard let odds else { return nil }
        return OddsMath.impliedProbability(from: odds)
    }

    var displayedProbability: Int {
        if let impliedProbability {
            return Int(impliedProbability.rounded())
        }
        return min(95, max(50, lockScore))
    }

    var probabilityLabel: String {
        impliedProbability == nil ? "SIGNAL %" : "IMPLIED %"
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

    var evidenceStrength: String {
        guard let moneyPercent else { return impliedProbability == nil ? "LIMITED" : "MODERATE" }
        let edge = moneyPercent - betsPercent
        if impliedProbability != nil && moneyPercent >= 72 && edge >= 8 { return "STRONG" }
        if moneyPercent >= 68 || edge >= 6 { return "GOOD" }
        return "MODERATE"
    }

    var evidenceNotes: [String] {
        var notes: [String] = []

        if let impliedProbability {
            notes.append(String(format: "Market price implies %.1f%% before removing sportsbook margin.", impliedProbability))
        } else {
            notes.append("No usable sportsbook price was available, so there is no market-implied probability.")
        }

        if let moneyPercent {
            let edge = moneyPercent - betsPercent
            if edge >= 8 {
                notes.append("\(moneyPercent)% of money vs \(betsPercent)% of bets: +\(edge) points of money-over-ticket support.")
            } else {
                notes.append("\(betsPercent)% of bets and \(moneyPercent)% of money are on this side.")
            }
        } else {
            notes.append("No verified money percentage is available, so public support is less informative.")
        }

        if source == .draftKings {
            notes.append("DraftKings split-feed lines can differ by jurisdiction; verify the exact line in your sportsbook before betting.")
        }

        return notes
    }

    var riskNote: String {
        if source == .draftKings {
            return "Risk: split-feed line may not match your local book."
        }
        if moneyPercent == nil {
            return "Risk: no money-split confirmation."
        }
        return "Risk: market pricing and public splits can still be wrong."
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
            URLQueryItem(name: "tb_eg", value: group)
        ]
        return components.url!
    }

    var draftKingsPropsURL: URL {
        let base = "https://dknetwork.draftkings.com/draftkings-sportsbook-player-props/"
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
    case teams = "Teams"
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

    var impliedProbability: Double? {
        OddsMath.impliedProbability(from: odds)
    }

    var displayedProbability: Int? {
        impliedProbability.map { Int($0.rounded()) }
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

    var evidenceStrength: String {
        if let handlePercent, let betPercent {
            let edge = handlePercent - betPercent
            if impliedProbability != nil && handlePercent >= 70 && edge >= 8 { return "STRONG" }
            if handlePercent >= 65 || edge >= 6 { return "GOOD" }
        }
        if let impliedProbability, impliedProbability >= 60 { return "MODERATE" }
        return "LIMITED"
    }

    var evidenceNotes: [String] {
        var notes: [String] = []

        if let impliedProbability {
            notes.append(String(format: "Sportsbook price implies %.1f%% before removing sportsbook margin.", impliedProbability))
        } else {
            notes.append("No usable sportsbook price is available, so probability cannot be estimated from the market.")
        }

        if let handlePercent, let betPercent {
            let edge = handlePercent - betPercent
            notes.append(String(format: "%.0f%% handle vs %.0f%% bets (%+.0f points).", handlePercent, betPercent, edge))
        } else {
            notes.append("No verified public handle-vs-bet split is available for this prop.")
        }

        notes.append("Verify the exact player, line, and price in your sportsbook before adding it to a real wager.")
        return notes
    }

    var riskNote: String {
        if handlePercent == nil || betPercent == nil {
            return "Risk: market price only; no independent public split confirmation."
        }
        return "Risk: prop markets can move quickly with lineup, injury, and price changes."
    }
}

struct SlipLeg: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let source: String
    let signal: String
}
