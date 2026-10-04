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

    static func impliedProbability(fromAmerican value: Double) -> Double {
        if value > 0 { return 100.0 * 100.0 / (value + 100.0) }
        let absolute = abs(value)
        return 100.0 * absolute / (absolute + 100.0)
    }

    static func impliedProbability(from odds: String) -> Double? {
        guard let value = americanValue(from: odds) else { return nil }
        return impliedProbability(fromAmerican: value)
    }

    static func decimalOdds(from odds: String) -> Double? {
        guard let value = americanValue(from: odds) else { return nil }
        if value > 0 { return 1.0 + value / 100.0 }
        return 1.0 + 100.0 / abs(value)
    }

    static func americanString(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
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

enum SportFilter: String, CaseIterable, Identifiable, Codable {
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

    var oddsAPISportKey: String? {
        switch self {
        case .all: return nil
        case .nfl: return "americanfootball_nfl"
        case .ncaaf: return "americanfootball_ncaaf"
        case .nba: return "basketball_nba"
        case .ncaab: return "basketball_ncaab"
        case .mlb: return "baseball_mlb"
        case .nhl: return "icehockey_nhl"
        case .wnba: return "basketball_wnba"
        case .soccer: return "soccer_usa_mls"
        }
    }

    var espnRoute: (sport: String, league: String, searchSport: String)? {
        switch self {
        case .all: return nil
        case .nfl: return ("football", "nfl", "football")
        case .ncaaf: return ("football", "college-football", "football")
        case .nba: return ("basketball", "nba", "basketball")
        case .ncaab: return ("basketball", "mens-college-basketball", "basketball")
        case .mlb: return ("baseball", "mlb", "baseball")
        case .nhl: return ("hockey", "nhl", "hockey")
        case .wnba: return ("basketball", "wnba", "basketball")
        case .soccer: return ("soccer", "usa.1", "soccer")
        }
    }

    var supportsPlayerGameLogs: Bool {
        switch self {
        case .nba, .wnba, .ncaab, .nfl, .ncaaf, .mlb:
            return true
        default:
            return false
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
    case liveOddsNotConfigured
    case unsupportedSport

    var errorDescription: String? {
        switch self {
        case .noData: return "No public betting rows were found yet."
        case .invalidPage: return "SlipRadar could not read the public betting page."
        case .liveOddsNotConfigured: return "Live multi-book odds are not connected."
        case .unsupportedSport: return "This live-data feature is not available for the selected sport."
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
        for candidate in [line, market] {
            for separator in [" over ", " under ", " - "] {
                if let range = candidate.range(of: separator, options: [.caseInsensitive]) {
                    let prefix = String(candidate[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if prefix.split(separator: " ").count >= 2 { return prefix }
                }
            }

            if let regex = try? NSRegularExpression(pattern: #"\s+[oOuU]\s*\d"#) {
                let ns = candidate as NSString
                let full = NSRange(location: 0, length: ns.length)
                if let match = regex.firstMatch(in: candidate, range: full) {
                    let prefix = ns.substring(with: NSRange(location: 0, length: match.range.location))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if prefix.split(separator: " ").count >= 2 { return prefix }
                }
            }

            if let regex = try? NSRegularExpression(pattern: #"\s+\d+(?:\.\d+)?"#) {
                let ns = candidate as NSString
                let full = NSRange(location: 0, length: ns.length)
                if let match = regex.firstMatch(in: candidate, range: full) {
                    let prefix = ns.substring(with: NSRange(location: 0, length: match.range.location))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if prefix.split(separator: " ").count >= 2 { return prefix }
                }
            }
        }
        return ""
    }

    var threshold: Double? {
        for candidate in [line, market] {
            guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { continue }
            let ns = candidate as NSString
            let matches = regex.matches(in: candidate, range: NSRange(location: 0, length: ns.length))
            if let match = matches.last,
               let value = Double(ns.substring(with: match.range)) {
                return value
            }
        }
        return nil
    }

    var direction: String? {
        let lower = (line + " " + market).lowercased()
        if lower.contains("under") || lower.range(of: #"(^|\s)u\s*\d"#, options: .regularExpression) != nil { return "Under" }
        if lower.contains("over") || lower.range(of: #"(^|\s)o\s*\d"#, options: .regularExpression) != nil { return "Over" }
        return nil
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

enum LiveLineStatus: String, Codable {
    case live = "LIVE"
    case stale = "STALE"
    case mismatch = "MISMATCH"
    case unverified = "UNVERIFIED"
    case notConnected = "NOT CONNECTED"
}

struct LiveMarketConsensus: Identifiable, Hashable {
    let id: String
    let event: String
    let market: String
    let outcome: String
    let point: Double?
    let fairProbability: Double
    let averageImpliedProbability: Double
    let bestOdds: String
    let bookCount: Int
    let books: [String]
    let lastUpdated: Date
}

struct LivePropVerification: Hashable {
    let status: LiveLineStatus
    let event: String
    let market: String
    let player: String
    let direction: String?
    let requestedPoint: Double?
    let livePoint: Double?
    let fairProbability: Double?
    let averageImpliedProbability: Double?
    let bestOdds: String?
    let bookCount: Int
    let books: [String]
    let checkedAt: Date
    let note: String
}

struct StatProjection: Hashable {
    let playerName: String
    let metricName: String
    let threshold: Double
    let direction: String
    let sampleSize: Int
    let recentSampleSize: Int
    let seasonAverage: Double
    let recentAverage: Double
    let seasonHitRate: Double
    let recentHitRate: Double
    let rawModelProbability: Double
    let modelProbability: Double
    let calibratedSampleSize: Int
    let generatedAt: Date

    var edgeToLine: Double {
        direction == "Under" ? threshold - recentAverage : recentAverage - threshold
    }
}

struct TeamProjection: Hashable {
    let matchup: String
    let awayTeam: String
    let homeTeam: String
    let awayAverageFor: Double
    let awayAverageAgainst: Double
    let homeAverageFor: Double
    let homeAverageAgainst: Double
    let projectedAwayScore: Double
    let projectedHomeScore: Double
    let projectedTotal: Double
    let projectedHomeMargin: Double
    let marginStdDev: Double
    let totalStdDev: Double
    let sampleSize: Int
    let generatedAt: Date
}

struct DecisionReport {
    let modelProbability: Double?
    let fairProbability: Double?
    let marketProbability: Double?
    let estimatedEdge: Double?
    let evidenceScore: Int
    let dataQuality: Int
    let sourceCount: Int
    let liveStatus: LiveLineStatus
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
    let sport: String
    let event: String
    let market: String
    let odds: String?
    let probability: Double?
    let marketProbability: Double?
    let evidenceScore: Int
    let playerName: String?
    let threshold: Double?
    let direction: String?
    let addedAt: Date
}
