import Foundation

enum ModelVersion {
    static let current = "1.0.0"
}

enum BetSource: String, CaseIterable, Identifiable, Codable {
    case action = "Action Network"
    case draftKings = "DraftKings"
    case multiBook = "Multi-book Live"

    var id: String { rawValue }

    static let publicFeeds: [BetSource] = [.action, .draftKings]
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

    static func expectedValuePercent(probability: Double?, odds: String?) -> Double? {
        guard let probability,
              let odds,
              let decimal = decimalOdds(from: odds) else { return nil }

        let p = probability / 100.0
        return (p * (decimal - 1.0) - (1.0 - p)) * 100.0
    }
}

struct PopularBet: Identifiable, Hashable {
    let id: UUID
    let source: BetSource
    let matchup: String
    let side: String
    let market: String
    let startTime: String
    let odds: String?
    let betsPercent: Int
    let moneyPercent: Int?
    let splitDifference: Int?
    var sport: SportFilter?

    init(
        id: UUID = UUID(),
        source: BetSource,
        matchup: String,
        side: String,
        market: String,
        startTime: String,
        odds: String?,
        betsPercent: Int,
        moneyPercent: Int?,
        splitDifference: Int?,
        sport: SportFilter? = nil
    ) {
        self.id = id
        self.source = source
        self.matchup = matchup
        self.side = side
        self.market = market
        self.startTime = startTime
        self.odds = odds
        self.betsPercent = betsPercent
        self.moneyPercent = moneyPercent
        self.splitDifference = splitDifference
        self.sport = sport
    }

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

    static let modeledSports: [SportFilter] = [
        .nfl, .ncaaf, .nba, .ncaab, .mlb, .nhl, .wnba, .soccer
    ]

    var isOutdoorWeatherRelevant: Bool {
        switch self {
        case .nfl, .ncaaf, .mlb, .soccer: return true
        default: return false
        }
    }

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
        case .nba, .wnba, .ncaab, .nfl, .ncaaf, .mlb, .nhl:
            return true
        case .soccer, .all:
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
        case .noData: return "No usable current data was returned."
        case .invalidPage: return "SlipRadar could not read the public data page."
        case .liveOddsNotConfigured: return "Live multi-book odds are not connected."
        case .unsupportedSport: return "This live-data feature is not available for the selected sport."
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case locks = "Best"
    case teams = "Teams"
    case props = "Props"
    case watch = "Watch"
    case slip = "My Slip"
    case performance = "Track"
    case health = "Health"

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
    var sport: SportFilter?

    init(
        event: String,
        eventDate: String,
        market: String,
        line: String,
        odds: String,
        source: String,
        isLock: Bool,
        handlePercent: Double?,
        betPercent: Double?,
        sport: SportFilter? = nil
    ) {
        self.event = event
        self.eventDate = eventDate
        self.market = market
        self.line = line
        self.odds = odds
        self.source = source
        self.isLock = isLock
        self.handlePercent = handlePercent
        self.betPercent = betPercent
        self.sport = sport
    }

    var id: String { [sport?.rawValue ?? "", event, market, line, odds].joined(separator: "|") }

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

    var rank: Int {
        switch self {
        case .live: return 5
        case .unverified: return 3
        case .notConnected: return 2
        case .stale: return 1
        case .mismatch: return 0
        }
    }
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
    let bestBook: String
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
    let bestBook: String?
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
    let awayRestDays: Int?
    let homeRestDays: Int?
    let generatedAt: Date
}

struct ConfidenceBreakdown: Hashable {
    let stats: Int
    let market: Int
    let availability: Int
    let freshness: Int
    let history: Int
    let publicSignal: Int

    var total: Int {
        stats + market + availability + freshness + history + publicSignal
    }
}

struct DecisionReport {
    let modelProbability: Double?
    let fairProbability: Double?
    let marketProbability: Double?
    let estimatedEdge: Double?
    let expectedValuePercent: Double?
    let evidenceScore: Int
    let dataQuality: Int
    let sourceCount: Int
    let liveStatus: LiveLineStatus
    let verdict: PickVerdict
    let components: ConfidenceBreakdown
    let reasons: [String]
    let risks: [String]
}

struct ScoredBet: Identifiable {
    let sport: SportFilter
    let bet: PopularBet
    let report: DecisionReport
    var id: UUID { bet.id }
}

struct ScoredProp: Identifiable {
    let sport: SportFilter
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
    let bestBook: String?
    let probability: Double?
    let marketProbability: Double?
    let expectedValuePercent: Double?
    let evidenceScore: Int
    let playerName: String?
    let threshold: Double?
    let direction: String?
    let modelVersion: String
    let addedAt: Date
}

enum SourceHealthState: String, Codable {
    case healthy = "HEALTHY"
    case limited = "LIMITED"
    case loading = "LOADING"
    case failed = "FAILED"
    case off = "OFF"
}

struct SourceHealthItem: Identifiable, Hashable {
    let id: String
    let name: String
    let state: SourceHealthState
    let detail: String
    let lastUpdated: Date?
}

enum AvailabilitySeverity: String, Codable {
    case clear
    case caution
    case severe
    case unknown
}

struct EventContextSnapshot: Identifiable, Hashable {
    let id: String
    let sport: SportFilter
    let event: String
    let venue: String?
    let weather: String?
    let windMPH: Double?
    let weatherSeverity: Int
    let statusText: String?
    let updatedAt: Date
}

struct PlayerAvailabilitySnapshot: Hashable {
    let player: String
    let severity: AvailabilitySeverity
    let starterConfirmed: Bool?
    let activeConfirmed: Bool?
    let note: String
    let checkedAt: Date
}

enum WatchKind: String, Codable {
    case team
    case prop
}

struct WatchItem: Identifiable, Hashable, Codable {
    let id: String
    let kind: WatchKind
    let sport: SportFilter
    let event: String
    let market: String
    let selection: String
    let playerName: String?
    let threshold: Double?
    let direction: String?
    let createdAt: Date
    var lastVerdict: PickVerdict?
    var lastOdds: String?
    var lastBook: String?
    var lastModelProbability: Double?
    var lastFairProbability: Double?
    var lastLineStatus: LiveLineStatus?
    var lastUpdated: Date?
}

struct WatchAlert: Hashable {
    let title: String
    let body: String
}

struct CalibrationBucket: Identifiable, Hashable {
    let id: String
    let label: String
    let count: Int
    let averagePredicted: Double
    let observedWinRate: Double
}

struct BacktestSummary: Hashable {
    let label: String
    let sampleSize: Int
    let wins: Int
    let losses: Int
    let winRate: Double?
    let roi: Double?
}
