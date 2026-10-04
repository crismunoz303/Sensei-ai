import Foundation
import Security

enum SecretStore {
    private static let service = "com.crismunoz.slipradar"
    private static let oddsAccount = "the-odds-api-key"

    static func loadOddsAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: oddsAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveOddsAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: oddsAccount
        ]

        SecItemDelete(base as CFDictionary)

        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

private struct OddsAPIOutcome: Decodable {
    let name: String
    let description: String?
    let price: Double
    let point: Double?
}

private struct OddsAPIMarket: Decodable {
    let key: String
    let lastUpdate: String?
    let outcomes: [OddsAPIOutcome]

    enum CodingKeys: String, CodingKey {
        case key
        case lastUpdate = "last_update"
        case outcomes
    }
}

private struct OddsAPIBookmaker: Decodable {
    let key: String
    let title: String
    let lastUpdate: String?
    let markets: [OddsAPIMarket]

    enum CodingKeys: String, CodingKey {
        case key, title, markets
        case lastUpdate = "last_update"
    }
}

private struct OddsAPIGame: Decodable {
    let id: String
    let commenceTime: String
    let homeTeam: String
    let awayTeam: String
    let bookmakers: [OddsAPIBookmaker]

    enum CodingKeys: String, CodingKey {
        case id
        case commenceTime = "commence_time"
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case bookmakers
    }
}

private struct OddsAPIEventStub: Decodable {
    let id: String
    let commenceTime: String
    let homeTeam: String
    let awayTeam: String

    enum CodingKeys: String, CodingKey {
        case id
        case commenceTime = "commence_time"
        case homeTeam = "home_team"
        case awayTeam = "away_team"
    }
}

private struct QuoteRow {
    let eventID: String
    let event: String
    let market: String
    let outcome: String
    let description: String?
    let point: Double?
    let bookmaker: String
    let price: Double
    let fairProbability: Double
    let impliedProbability: Double
    let updated: Date
}

enum LiveOddsService {
    static let preferredBooks = ["draftkings", "fanduel", "betmgm", "williamhill_us"]

    static func fetchTeamConsensus(sport: SportFilter, apiKey: String) async throws -> [LiveMarketConsensus] {
        guard let sportKey = sport.oddsAPISportKey else { throw SlipRadarError.unsupportedSport }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SlipRadarError.liveOddsNotConfigured }

        var components = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/odds")!
        components.queryItems = [
            URLQueryItem(name: "apiKey", value: key),
            URLQueryItem(name: "regions", value: "us"),
            URLQueryItem(name: "markets", value: "h2h,spreads,totals"),
            URLQueryItem(name: "bookmakers", value: preferredBooks.joined(separator: ",")),
            URLQueryItem(name: "oddsFormat", value: "american"),
            URLQueryItem(name: "dateFormat", value: "iso")
        ]

        let games: [OddsAPIGame] = try await fetchJSON(components.url!)
        return consensus(from: games.flatMap(teamQuoteRows))
    }

    static func verifyProp(_ prop: PropPick, sport: SportFilter, apiKey: String) async throws -> LivePropVerification {
        guard let sportKey = sport.oddsAPISportKey else { throw SlipRadarError.unsupportedSport }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SlipRadarError.liveOddsNotConfigured }
        guard let marketKey = propMarketKey(prop, sport: sport) else {
            return LivePropVerification(
                status: .unverified,
                event: prop.event,
                market: prop.market,
                player: prop.playerName,
                direction: prop.direction,
                requestedPoint: prop.threshold,
                livePoint: nil,
                fairProbability: nil,
                averageImpliedProbability: nil,
                bestOdds: nil,
                bookCount: 0,
                books: [],
                checkedAt: Date(),
                note: "This prop type is not mapped to a live multi-book market yet."
            )
        }

        var eventComponents = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/events")!
        eventComponents.queryItems = [URLQueryItem(name: "apiKey", value: key)]
        let events: [OddsAPIEventStub] = try await fetchJSON(eventComponents.url!)

        guard let event = events.max(by: { lhs, rhs in
            eventMatchScore(lhs, prop.event) < eventMatchScore(rhs, prop.event)
        }), eventMatchScore(event, prop.event) >= 0.55 else {
            return LivePropVerification(
                status: .unverified,
                event: prop.event,
                market: prop.market,
                player: prop.playerName,
                direction: prop.direction,
                requestedPoint: prop.threshold,
                livePoint: nil,
                fairProbability: nil,
                averageImpliedProbability: nil,
                bestOdds: nil,
                bookCount: 0,
                books: [],
                checkedAt: Date(),
                note: "The current event could not be matched to the live multi-book board."
            )
        }

        var oddsComponents = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/events/\(event.id)/odds")!
        oddsComponents.queryItems = [
            URLQueryItem(name: "apiKey", value: key),
            URLQueryItem(name: "regions", value: "us"),
            URLQueryItem(name: "markets", value: marketKey),
            URLQueryItem(name: "bookmakers", value: preferredBooks.joined(separator: ",")),
            URLQueryItem(name: "oddsFormat", value: "american"),
            URLQueryItem(name: "dateFormat", value: "iso")
        ]

        let game: OddsAPIGame = try await fetchJSON(oddsComponents.url!)
        let rows = propQuoteRows(game, marketKey: marketKey, prop: prop)

        guard !rows.isEmpty else {
            return LivePropVerification(
                status: .unverified,
                event: prop.event,
                market: prop.market,
                player: prop.playerName,
                direction: prop.direction,
                requestedPoint: prop.threshold,
                livePoint: nil,
                fairProbability: nil,
                averageImpliedProbability: nil,
                bestOdds: nil,
                bookCount: 0,
                books: [],
                checkedAt: Date(),
                note: "No matching live player/side was returned by the selected sportsbooks."
            )
        }

        let requestedPoint = prop.threshold
        let exactRows: [QuoteRow]
        if let requestedPoint {
            exactRows = rows.filter { row in
                guard let point = row.point else { return false }
                return abs(point - requestedPoint) < 0.001
            }
        } else {
            exactRows = rows
        }

        let chosen: [QuoteRow]
        let status: LiveLineStatus

        if !exactRows.isEmpty {
            chosen = exactRows
            status = .live
        } else {
            let grouped = Dictionary(grouping: rows) { $0.point ?? -9999 }
            chosen = grouped.values.max(by: { $0.count < $1.count }) ?? rows
            status = .mismatch
        }

        let fair = chosen.map(\.fairProbability).reduce(0, +) / Double(chosen.count)
        let implied = chosen.map(\.impliedProbability).reduce(0, +) / Double(chosen.count)
        let best = chosen.map(\.price).max()
        let books = Array(Set(chosen.map(\.bookmaker))).sorted()
        let livePoint = chosen.compactMap(\.point).first
        let note: String

        if status == .live {
            note = "\(books.count) live book\(books.count == 1 ? "" : "s") confirm the exact prop line."
        } else if let requestedPoint, let livePoint {
            note = "Requested line \(formatPoint(requestedPoint)) does not match the live consensus line \(formatPoint(livePoint))."
        } else {
            note = "The player/market exists live, but the exact requested line could not be confirmed."
        }

        return LivePropVerification(
            status: status,
            event: prop.event,
            market: prop.market,
            player: prop.playerName,
            direction: prop.direction,
            requestedPoint: requestedPoint,
            livePoint: livePoint,
            fairProbability: fair,
            averageImpliedProbability: implied,
            bestOdds: best.map(OddsMath.americanString),
            bookCount: books.count,
            books: books,
            checkedAt: Date(),
            note: note
        )
    }

    static func matchConsensus(for bet: PopularBet, in live: [LiveMarketConsensus]) -> LiveMarketConsensus? {
        let marketName = normalizedMarket(bet.market)
        let eventMatches = live.filter {
            MarketKey.sameEvent($0.event, bet.matchup) && $0.market == marketName
        }

        guard !eventMatches.isEmpty else { return nil }

        let selectionPoint = numericPoint(bet.side)

        let scored = eventMatches.map { item -> (LiveMarketConsensus, Double) in
            var score = selectionScore(bet.side, item.outcome)
            if let selectionPoint, let point = item.point {
                let distance = abs(selectionPoint - point)
                score += distance < 0.001 ? 0.5 : max(0, 0.25 - distance * 0.05)
            } else if selectionPoint == nil && item.point == nil {
                score += 0.2
            }
            return (item, score)
        }

        return scored.max(by: { $0.1 < $1.1 }).flatMap { $0.1 >= 0.45 ? $0.0 : nil }
    }

    static func lineStatus(for bet: PopularBet, consensus: LiveMarketConsensus?) -> LiveLineStatus {
        guard let consensus else { return .unverified }
        let requested = numericPoint(bet.side)
        if let requested, let livePoint = consensus.point {
            return abs(requested - livePoint) < 0.001 ? .live : .mismatch
        }
        return .live
    }

    private static func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("SlipRadar/0.9", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SlipRadarError.noData
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func teamQuoteRows(_ game: OddsAPIGame) -> [QuoteRow] {
        var rows: [QuoteRow] = []
        let event = "\(game.awayTeam) @ \(game.homeTeam)"

        for bookmaker in game.bookmakers {
            for market in bookmaker.markets {
                let displayMarket = normalizedMarket(market.key)
                let updated = isoDate(market.lastUpdate ?? bookmaker.lastUpdate) ?? Date()

                let groups = Dictionary(grouping: market.outcomes) { outcome -> String in
                    switch market.key {
                    case "spreads":
                        return outcome.name + "|" + String(format: "%.3f", outcome.point ?? 0)
                    case "totals":
                        return String(format: "%.3f", outcome.point ?? 0)
                    default:
                        return "all"
                    }
                }

                for outcomes in groups.values {
                    let implied = outcomes.map { OddsMath.impliedProbability(fromAmerican: $0.price) }
                    let total = implied.reduce(0, +)
                    guard total > 0 else { continue }

                    for (index, outcome) in outcomes.enumerated() {
                        rows.append(QuoteRow(
                            eventID: game.id,
                            event: event,
                            market: displayMarket,
                            outcome: outcome.name,
                            description: outcome.description,
                            point: outcome.point,
                            bookmaker: bookmaker.title,
                            price: outcome.price,
                            fairProbability: implied[index] / total * 100.0,
                            impliedProbability: implied[index],
                            updated: updated
                        ))
                    }
                }
            }
        }
        return rows
    }

    private static func propQuoteRows(_ game: OddsAPIGame, marketKey: String, prop: PropPick) -> [QuoteRow] {
        let player = MarketKey.normalized(prop.playerName)
        let desiredDirection = prop.direction?.lowercased()
        var rows: [QuoteRow] = []

        for bookmaker in game.bookmakers {
            for market in bookmaker.markets where market.key == marketKey {
                let updated = isoDate(market.lastUpdate ?? bookmaker.lastUpdate) ?? Date()

                let playerOutcomes = market.outcomes.filter { outcome in
                    let description = MarketKey.normalized(outcome.description ?? "")
                    let name = MarketKey.normalized(outcome.name)
                    let playerMatches = !player.isEmpty && (
                        description == player ||
                        description.contains(player) ||
                        player.contains(description)
                    )
                    let directionMatches = desiredDirection == nil || name == desiredDirection
                    return playerMatches && directionMatches
                }

                for target in playerOutcomes {
                    let pair = market.outcomes.filter { candidate in
                        MarketKey.normalized(candidate.description ?? "") == MarketKey.normalized(target.description ?? "") &&
                        abs((candidate.point ?? -9999) - (target.point ?? -9999)) < 0.001
                    }
                    let implied = pair.map { OddsMath.impliedProbability(fromAmerican: $0.price) }
                    let total = implied.reduce(0, +)
                    guard let index = pair.firstIndex(where: {
                        $0.name == target.name && $0.price == target.price && $0.point == target.point
                    }), total > 0 else { continue }

                    rows.append(QuoteRow(
                        eventID: game.id,
                        event: "\(game.awayTeam) @ \(game.homeTeam)",
                        market: marketKey,
                        outcome: target.name,
                        description: target.description,
                        point: target.point,
                        bookmaker: bookmaker.title,
                        price: target.price,
                        fairProbability: implied[index] / total * 100.0,
                        impliedProbability: implied[index],
                        updated: updated
                    ))
                }
            }
        }
        return rows
    }

    private static func consensus(from rows: [QuoteRow]) -> [LiveMarketConsensus] {
        let grouped = Dictionary(grouping: rows) { row in
            [
                MarketKey.normalized(row.event),
                row.market,
                MarketKey.normalized(row.outcome),
                row.point.map { String(format: "%.3f", $0) } ?? "nil"
            ].joined(separator: "|")
        }

        return grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            let fair = group.map(\.fairProbability).reduce(0, +) / Double(group.count)
            let implied = group.map(\.impliedProbability).reduce(0, +) / Double(group.count)
            let best = group.map(\.price).max() ?? 0
            let books = Array(Set(group.map(\.bookmaker))).sorted()
            return LiveMarketConsensus(
                id: [
                    MarketKey.normalized(first.event),
                    first.market,
                    MarketKey.normalized(first.outcome),
                    first.point.map { String($0) } ?? "nil"
                ].joined(separator: "|"),
                event: first.event,
                market: first.market,
                outcome: first.outcome,
                point: first.point,
                fairProbability: fair,
                averageImpliedProbability: implied,
                bestOdds: OddsMath.americanString(best),
                bookCount: books.count,
                books: books,
                lastUpdated: group.map(\.updated).max() ?? Date()
            )
        }
    }

    private static func normalizedMarket(_ market: String) -> String {
        switch market.lowercased() {
        case "h2h", "moneyline": return "Moneyline"
        case "spreads", "spread", "run line": return "Spread"
        case "totals", "total": return "Total"
        default: return market
        }
    }

    private static func propMarketKey(_ prop: PropPick, sport: SportFilter) -> String? {
        let text = (prop.market + " " + prop.line).lowercased()

        switch sport {
        case .nba, .wnba, .ncaab:
            if text.contains("point") && text.contains("rebound") && text.contains("assist") { return "player_points_rebounds_assists" }
            if text.contains("point") { return "player_points" }
            if text.contains("rebound") { return "player_rebounds" }
            if text.contains("assist") { return "player_assists" }
            if text.contains("3") && (text.contains("made") || text.contains("three")) { return "player_threes" }
            if text.contains("block") { return "player_blocks" }
            if text.contains("steal") { return "player_steals" }
        case .nfl, .ncaaf:
            if text.contains("pass") && text.contains("yard") { return "player_pass_yds" }
            if text.contains("rush") && text.contains("yard") { return "player_rush_yds" }
            if text.contains("receiv") && text.contains("yard") { return "player_reception_yds" }
            if text.contains("reception") { return "player_receptions" }
            if text.contains("pass") && text.contains("touchdown") { return "player_pass_tds" }
            if text.contains("touchdown") || text.contains("td") { return "player_anytime_td" }
        case .mlb:
            if text.contains("total base") { return "batter_total_bases" }
            if text.contains("hit") { return "batter_hits" }
            if text.contains("home run") { return "batter_home_runs" }
            if text.contains("rbi") { return "batter_rbis" }
            if text.contains("run") && !text.contains("home") { return "batter_runs_scored" }
            if text.contains("strikeout") { return "pitcher_strikeouts" }
        case .nhl:
            if text.contains("shot") { return "player_shots_on_goal" }
            if text.contains("goal") { return "player_goals" }
            if text.contains("assist") { return "player_assists" }
            if text.contains("point") { return "player_points" }
        case .soccer, .all:
            return nil
        }

        return nil
    }

    private static func eventMatchScore(_ event: OddsAPIEventStub, _ text: String) -> Double {
        let target = MarketKey.eventTokens(text)
        let eventTokens = MarketKey.eventTokens("\(event.awayTeam) @ \(event.homeTeam)")
        guard !target.isEmpty, !eventTokens.isEmpty else { return 0 }
        return Double(target.intersection(eventTokens).count) / Double(min(target.count, eventTokens.count))
    }

    private static func selectionScore(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(MarketKey.selectionBase(lhs).split(separator: " ").map(String.init))
        let b = Set(MarketKey.selectionBase(rhs).split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    private static func numericPoint(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?"#) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last else { return nil }
        return Double(ns.substring(with: match.range))
    }

    private static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func formatPoint(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
