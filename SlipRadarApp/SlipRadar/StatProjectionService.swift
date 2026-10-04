import Foundation
import Darwin

private struct StatGame {
    let date: Date?
    let value: Double
}

private struct TeamGameSample {
    let date: Date?
    let pointsFor: Double
    let pointsAgainst: Double

    var margin: Double { pointsFor - pointsAgainst }
    var total: Double { pointsFor + pointsAgainst }
}

private actor ESPNCache {
    static let shared = ESPNCache()
    private var data: [String: Data] = [:]

    func value(for key: String) -> Data? { data[key] }
    func set(_ value: Data, for key: String) { data[key] = value }
}

enum StatProjectionService {
    static func playerProjection(for prop: PropPick, sport: SportFilter) async -> StatProjection? {
        guard sport.supportsPlayerGameLogs,
              let route = sport.espnRoute,
              !prop.playerName.isEmpty,
              let threshold = prop.threshold,
              let direction = prop.direction,
              let metric = metricDefinition(for: prop, sport: sport) else {
            return nil
        }

        do {
            guard let athleteID = try await findAthleteID(
                name: prop.playerName,
                searchSport: route.searchSport
            ) else {
                return nil
            }

            let url = URL(string:
                "https://site.web.api.espn.com/apis/common/v3/sports/\(route.sport)/\(route.league)/athletes/\(athleteID)/gamelog"
            )!
            let data = try await fetch(url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let games = extractStatGames(root: root, metric: metric)
                .sorted { lhs, rhs in
                    switch (lhs.date, rhs.date) {
                    case let (l?, r?): return l > r
                    case (_?, nil): return true
                    default: return false
                    }
                }

            guard games.count >= 3 else { return nil }
            let values = games.map(\.value)
            let recentValues = Array(values.prefix(min(10, values.count)))

            let seasonAverage = mean(values)
            let recentAverage = mean(recentValues)
            let seasonHitRate = hitRate(values, threshold: threshold, direction: direction)
            let recentHitRate = hitRate(recentValues, threshold: threshold, direction: direction)

            let standardDeviation = stddev(values)
            let distributionProbability: Double
            if standardDeviation >= 0.25 {
                let z = (threshold - seasonAverage) / standardDeviation
                let over = (1.0 - normalCDF(z)) * 100.0
                distributionProbability = direction == "Under" ? 100.0 - over : over
            } else {
                distributionProbability = seasonHitRate
            }

            let recentWeight = recentValues.count >= 8 ? 0.40 : 0.30
            let seasonWeight = 0.25
            let distributionWeight = 1.0 - recentWeight - seasonWeight
            let raw = recentHitRate * recentWeight +
                seasonHitRate * seasonWeight +
                distributionProbability * distributionWeight

            let sampleConfidence = min(1.0, Double(values.count) / 20.0)
            let shrunk = 50.0 + (raw - 50.0) * sampleConfidence
            let calibration = PerformanceStore.calibrate(rawProbability: shrunk)
            let finalProbability = calibration?.probability ?? shrunk

            return StatProjection(
                playerName: prop.playerName,
                metricName: metric.displayName,
                threshold: threshold,
                direction: direction,
                sampleSize: values.count,
                recentSampleSize: recentValues.count,
                seasonAverage: seasonAverage,
                recentAverage: recentAverage,
                seasonHitRate: seasonHitRate,
                recentHitRate: recentHitRate,
                rawModelProbability: shrunk,
                modelProbability: finalProbability,
                calibratedSampleSize: calibration?.sampleSize ?? 0,
                generatedAt: Date()
            )
        } catch {
            return nil
        }
    }

    static func teamProjection(for matchup: String, sport: SportFilter) async -> TeamProjection? {
        guard let route = sport.espnRoute,
              let teams = splitMatchup(matchup),
              sport != .soccer else {
            return nil
        }

        do {
            async let awayID = findTeamID(name: teams.away, searchSport: route.searchSport)
            async let homeID = findTeamID(name: teams.home, searchSport: route.searchSport)

            guard let away = try await awayID,
                  let home = try await homeID else {
                return nil
            }

            async let awaySamples = fetchTeamSchedule(teamID: away, route: route)
            async let homeSamples = fetchTeamSchedule(teamID: home, route: route)

            let a = try await awaySamples
            let h = try await homeSamples
            let awayRecent = Array(a.sorted(by: newestFirst).prefix(10))
            let homeRecent = Array(h.sorted(by: newestFirst).prefix(10))

            guard awayRecent.count >= 3, homeRecent.count >= 3 else { return nil }

            let awayPF = mean(awayRecent.map(\.pointsFor))
            let awayPA = mean(awayRecent.map(\.pointsAgainst))
            let homePF = mean(homeRecent.map(\.pointsFor))
            let homePA = mean(homeRecent.map(\.pointsAgainst))

            let projectedAway = (awayPF + homePA) / 2.0
            let projectedHome = (homePF + awayPA) / 2.0
            let projectedTotal = projectedAway + projectedHome
            let projectedHomeMargin = projectedHome - projectedAway

            let marginSamples = awayRecent.map(\.margin) + homeRecent.map { -$0.margin }
            let totalSamples = awayRecent.map(\.total) + homeRecent.map(\.total)

            return TeamProjection(
                matchup: matchup,
                awayTeam: teams.away,
                homeTeam: teams.home,
                awayAverageFor: awayPF,
                awayAverageAgainst: awayPA,
                homeAverageFor: homePF,
                homeAverageAgainst: homePA,
                projectedAwayScore: projectedAway,
                projectedHomeScore: projectedHome,
                projectedTotal: projectedTotal,
                projectedHomeMargin: projectedHomeMargin,
                marginStdDev: max(stddev(marginSamples), defaultMarginStdDev(for: sport)),
                totalStdDev: max(stddev(totalSamples), defaultTotalStdDev(for: sport)),
                sampleSize: min(awayRecent.count, homeRecent.count),
                generatedAt: Date()
            )
        } catch {
            return nil
        }
    }

    static func teamModelProbability(for bet: PopularBet, projection: TeamProjection?) -> Double? {
        guard let projection else { return nil }

        let market = bet.market.lowercased()
        let side = bet.side.lowercased()
        let isHome = teamSelectionMatches(bet.side, team: projection.homeTeam)
        let isAway = teamSelectionMatches(bet.side, team: projection.awayTeam)

        if market.contains("total") || side.contains("over") || side.contains("under") {
            guard let line = lastNumber(in: bet.side) else { return nil }
            let z = (line - projection.projectedTotal) / max(projection.totalStdDev, 0.5)
            let over = (1.0 - normalCDF(z)) * 100.0
            return side.contains("under") ? 100.0 - over : over
        }

        if market.contains("spread") || lastSignedNumber(in: bet.side) != nil {
            guard isHome || isAway,
                  let spread = lastSignedNumber(in: bet.side) else { return nil }

            let selectedMargin = isHome
                ? projection.projectedHomeMargin
                : -projection.projectedHomeMargin
            let threshold = -spread
            let z = (threshold - selectedMargin) / max(projection.marginStdDev, 0.5)
            return (1.0 - normalCDF(z)) * 100.0
        }

        if market.contains("moneyline") || market == "side" {
            guard isHome || isAway else { return nil }
            let selectedMargin = isHome
                ? projection.projectedHomeMargin
                : -projection.projectedHomeMargin
            let z = (0.0 - selectedMargin) / max(projection.marginStdDev, 0.5)
            return (1.0 - normalCDF(z)) * 100.0
        }

        return nil
    }

    private struct MetricDefinition {
        let displayName: String
        let aliases: [[String]]
    }

    private static func metricDefinition(for prop: PropPick, sport: SportFilter) -> MetricDefinition? {
        let text = (prop.market + " " + prop.line).lowercased()

        switch sport {
        case .nba, .wnba, .ncaab:
            if text.contains("point") && text.contains("rebound") && text.contains("assist") {
                return MetricDefinition(displayName: "Points + rebounds + assists", aliases: [
                    ["points", "pts"],
                    ["rebounds", "totalRebounds", "reb"],
                    ["assists", "ast"]
                ])
            }
            if text.contains("point") {
                return MetricDefinition(displayName: "Points", aliases: [["points", "pts"]])
            }
            if text.contains("rebound") {
                return MetricDefinition(displayName: "Rebounds", aliases: [["rebounds", "totalRebounds", "reb"]])
            }
            if text.contains("assist") {
                return MetricDefinition(displayName: "Assists", aliases: [["assists", "ast"]])
            }
            if (text.contains("3") || text.contains("three")) && text.contains("made") {
                return MetricDefinition(displayName: "3-pointers made", aliases: [[
                    "threePointsMade", "threePointFieldGoalsMade", "3pt", "3pm"
                ]])
            }
            if text.contains("steal") {
                return MetricDefinition(displayName: "Steals", aliases: [["steals", "stl"]])
            }
            if text.contains("block") {
                return MetricDefinition(displayName: "Blocks", aliases: [["blocks", "blk"]])
            }

        case .nfl, .ncaaf:
            if text.contains("pass") && text.contains("yard") {
                return MetricDefinition(displayName: "Passing yards", aliases: [["passingYards", "passYards", "yds"]])
            }
            if text.contains("rush") && text.contains("yard") {
                return MetricDefinition(displayName: "Rushing yards", aliases: [["rushingYards", "rushYards"]])
            }
            if text.contains("receiv") && text.contains("yard") {
                return MetricDefinition(displayName: "Receiving yards", aliases: [["receivingYards", "recYards"]])
            }
            if text.contains("reception") {
                return MetricDefinition(displayName: "Receptions", aliases: [["receptions", "rec"]])
            }
            if text.contains("pass") && text.contains("touchdown") {
                return MetricDefinition(displayName: "Passing touchdowns", aliases: [["passingTouchdowns", "passTD", "td"]])
            }
            if text.contains("touchdown") || text.contains("anytime td") {
                return MetricDefinition(displayName: "Touchdowns", aliases: [["totalTouchdowns", "touchdowns", "td"]])
            }

        case .mlb:
            if text.contains("total base") {
                return MetricDefinition(displayName: "Total bases", aliases: [["totalBases", "tb"]])
            }
            if text.contains("hit") && !text.contains("pitch") {
                return MetricDefinition(displayName: "Hits", aliases: [["hits", "h"]])
            }
            if text.contains("home run") {
                return MetricDefinition(displayName: "Home runs", aliases: [["homeRuns", "hr"]])
            }
            if text.contains("rbi") {
                return MetricDefinition(displayName: "RBIs", aliases: [["runsBattedIn", "rbi", "rbis"]])
            }
            if text.contains("strikeout") {
                return MetricDefinition(displayName: "Strikeouts", aliases: [["strikeouts", "strikeoutsPitching", "so", "k"]])
            }
            if text.contains("run") {
                return MetricDefinition(displayName: "Runs", aliases: [["runs", "r"]])
            }

        default:
            return nil
        }

        return nil
    }

    private static func extractStatGames(root: [String: Any], metric: MetricDefinition) -> [StatGame] {
        let names = stringArray(root["names"]) ?? stringArray(root["labels"]) ?? []
        let events = eventArray(root)
        guard !names.isEmpty, !events.isEmpty else { return [] }

        var output: [StatGame] = []

        for event in events {
            guard let rawStats = event["stats"] as? [Any] else { continue }
            let stats = rawStats.map { String(describing: $0) }
            let offset = max(0, names.count - stats.count)

            var total = 0.0
            var foundAll = true

            for aliasGroup in metric.aliases {
                guard let nameIndex = indexForAliases(aliasGroup, names: names) else {
                    foundAll = false
                    break
                }

                let statsIndex = nameIndex - offset
                guard statsIndex >= 0, statsIndex < stats.count,
                      let value = numericStat(stats[statsIndex]) else {
                    foundAll = false
                    break
                }
                total += value
            }

            guard foundAll else { continue }
            output.append(StatGame(date: eventDate(event), value: total))
        }

        return output
    }

    private static func eventArray(_ root: [String: Any]) -> [[String: Any]] {
        for key in ["events", "games", "gameLog"] {
            if let array = root[key] as? [[String: Any]] { return array }
            if let dictionary = root[key] as? [String: Any] {
                if let items = dictionary["items"] as? [[String: Any]] { return items }
                let values = dictionary.values.compactMap { $0 as? [String: Any] }
                if !values.isEmpty { return values }
            }
        }
        return []
    }

    private static func fetchTeamSchedule(
        teamID: String,
        route: (sport: String, league: String, searchSport: String)
    ) async throws -> [TeamGameSample] {
        let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/\(route.sport)/\(route.league)/teams/\(teamID)/schedule"
        )!
        let data = try await fetch(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        let events = (root["events"] as? [[String: Any]]) ?? []
        var samples: [TeamGameSample] = []

        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let competitors = competition["competitors"] as? [[String: Any]] else {
                continue
            }

            var ownScore: Double?
            var opponentScore: Double?

            for competitor in competitors {
                guard let team = competitor["team"] as? [String: Any],
                      let id = stringValue(team["id"]),
                      let score = scoreValue(competitor["score"]) else {
                    continue
                }

                if id == teamID {
                    ownScore = score
                } else {
                    opponentScore = score
                }
            }

            if let ownScore, let opponentScore {
                samples.append(TeamGameSample(
                    date: parseDate(event["date"]),
                    pointsFor: ownScore,
                    pointsAgainst: opponentScore
                ))
            }
        }

        return samples
    }

    private static func findAthleteID(name: String, searchSport: String) async throws -> String? {
        try await searchID(name: name, searchSport: searchSport, kind: "athlete")
    }

    private static func findTeamID(name: String, searchSport: String) async throws -> String? {
        try await searchID(name: name, searchSport: searchSport, kind: "team")
    }

    private static func searchID(name: String, searchSport: String, kind: String) async throws -> String? {
        var components = URLComponents(string: "https://site.web.api.espn.com/apis/search/v2")!
        components.queryItems = [
            URLQueryItem(name: "query", value: name),
            URLQueryItem(name: "sport", value: searchSport),
            URLQueryItem(name: "limit", value: "20")
        ]

        let data = try await fetch(components.url!)
        let object = try JSONSerialization.jsonObject(with: data)
        return bestID(in: object, targetName: name, kind: kind)
    }

    private static func bestID(in object: Any, targetName: String, kind: String) -> String? {
        let target = MarketKey.normalized(targetName)
        var candidates: [(id: String, score: Double)] = []

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let display = stringValue(dictionary["displayName"]) ??
                    stringValue(dictionary["name"]) ??
                    stringValue(dictionary["fullName"])
                let id = stringValue(dictionary["id"])
                let type = (
                    stringValue(dictionary["type"]) ??
                    stringValue(dictionary["resultType"]) ??
                    ""
                ).lowercased()
                let uid = stringValue(dictionary["uid"]) ?? ""

                if let display, let id {
                    let normalized = MarketKey.normalized(display)
                    let similarity = nameSimilarity(target, normalized)
                    let kindBonus: Double

                    if kind == "team" {
                        kindBonus = type.contains("team") || uid.contains("~t:") ? 0.35 : 0
                    } else {
                        kindBonus = type.contains("player") || type.contains("athlete") || uid.contains("~a:") ? 0.35 : 0
                    }

                    if similarity >= 0.55 {
                        candidates.append((id, similarity + kindBonus))
                    }
                }

                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }

        walk(object)
        return candidates.max(by: { $0.score < $1.score })?.id
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let key = url.absoluteString
        if let cached = await ESPNCache.shared.value(for: key) { return cached }

        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("SlipRadar/0.9", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SlipRadarError.noData
        }

        await ESPNCache.shared.set(data, for: key)
        return data
    }

    private static func indexForAliases(_ aliases: [String], names: [String]) -> Int? {
        let normalizedAliases = aliases.map(MarketKey.normalized)

        for (index, name) in names.enumerated() {
            let normalized = MarketKey.normalized(name)
            if normalizedAliases.contains(normalized) { return index }
        }

        for (index, name) in names.enumerated() {
            let normalized = MarketKey.normalized(name)
            if normalizedAliases.contains(where: { normalized.contains($0) || $0.contains(normalized) }) {
                return index
            }
        }
        return nil
    }

    private static func numericStat(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) { return direct }

        if trimmed.contains("-") {
            let first = trimmed.split(separator: "-").first.map(String.init)
            if let first, let number = Double(first) { return number }
        }

        let clean = trimmed.replacingOccurrences(of: "%", with: "")
        return Double(clean)
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        if let strings = value as? [String] { return strings }
        if let array = value as? [Any] { return array.map { String(describing: $0) } }
        return nil
    }

    private static func eventDate(_ event: [String: Any]) -> Date? {
        for key in ["date", "gameDate", "eventDate"] {
            if let date = parseDate(event[key]) { return date }
        }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = stringValue(value) else { return nil }

        if let date = ISO8601DateFormatter().date(from: string) { return date }

        let formats = ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd", "MM/dd/yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static func scoreValue(_ value: Any?) -> Double? {
        if let dictionary = value as? [String: Any] {
            for key in ["value", "displayValue"] {
                if let score = doubleValue(dictionary[key]) { return score }
            }
        }
        return doubleValue(value)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func splitMatchup(_ value: String) -> (away: String, home: String)? {
        if let range = value.range(of: " @ ") {
            return (
                String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if let range = value.range(of: " vs ") {
            return (
                String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return nil
    }

    private static func teamSelectionMatches(_ selection: String, team: String) -> Bool {
        let a = Set(MarketKey.selectionBase(selection).split(separator: " ").map(String.init))
        let b = Set(MarketKey.normalized(team).split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return false }

        let overlap = Double(a.intersection(b).count) / Double(min(a.count, b.count))
        if overlap >= 0.5 { return true }

        let acronym = b.compactMap { $0.first }.map(String.init).joined()
        return MarketKey.normalized(selection).contains(acronym)
    }

    private static func lastNumber(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last else { return nil }
        return Double(ns.substring(with: match.range))
    }

    private static func lastSignedNumber(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"[-+]\d+(?:\.\d+)?"#) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last else { return nil }
        return Double(ns.substring(with: match.range))
    }

    private static func nameSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1.0 }
        let a = Set(lhs.split(separator: " ").map(String.init))
        let b = Set(rhs.split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(max(a.count, b.count))
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func stddev(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let avg = mean(values)
        let variance = values.map { pow($0 - avg, 2) }.reduce(0, +) / Double(values.count - 1)
        return sqrt(max(variance, 0))
    }

    private static func hitRate(_ values: [Double], threshold: Double, direction: String) -> Double {
        guard !values.isEmpty else { return 50 }
        let hits = values.reduce(0.0) { total, value in
            if value == threshold { return total + 0.5 }
            if direction == "Under" { return total + (value < threshold ? 1.0 : 0.0) }
            return total + (value > threshold ? 1.0 : 0.0)
        }
        return hits / Double(values.count) * 100.0
    }

    private static func normalCDF(_ z: Double) -> Double {
        0.5 * (1.0 + Darwin.erf(z / sqrt(2.0)))
    }

    private static func newestFirst(_ lhs: TeamGameSample, _ rhs: TeamGameSample) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (l?, r?): return l > r
        case (_?, nil): return true
        default: return false
        }
    }

    private static func defaultMarginStdDev(for sport: SportFilter) -> Double {
        switch sport {
        case .nba, .wnba, .ncaab: return 12
        case .nfl, .ncaaf: return 10
        case .mlb: return 3.2
        case .nhl: return 1.8
        case .soccer: return 1.5
        case .all: return 10
        }
    }

    private static func defaultTotalStdDev(for sport: SportFilter) -> Double {
        switch sport {
        case .nba, .wnba, .ncaab: return 18
        case .nfl, .ncaaf: return 14
        case .mlb: return 4.5
        case .nhl: return 2.5
        case .soccer: return 2
        case .all: return 14
        }
    }
}
