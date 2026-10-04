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
              let value = String(data: data, encoding: .utf8) else { return "" }
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
    enum CodingKeys: String, CodingKey { case key, outcomes; case lastUpdate = "last_update" }
}
private struct OddsAPIBookmaker: Decodable {
    let key: String
    let title: String
    let lastUpdate: String?
    let markets: [OddsAPIMarket]
    enum CodingKeys: String, CodingKey { case key, title, markets; case lastUpdate = "last_update" }
}
private struct OddsAPIGame: Decodable {
    let id: String
    let commenceTime: String
    let homeTeam: String
    let awayTeam: String
    let bookmakers: [OddsAPIBookmaker]
    enum CodingKeys: String, CodingKey {
        case id, bookmakers
        case commenceTime = "commence_time"
        case homeTeam = "home_team"
        case awayTeam = "away_team"
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
private struct OddsAPISport: Decodable {
    let key: String
    let active: Bool
}
private struct QuoteRow {
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
    let commenceTime: Date?
}

private struct PersistedOddsBoard: Codable {
    let timestamp: Date
    let values: [LiveMarketConsensus]
}

private actor LiveOddsCache {
    static let shared = LiveOddsCache()
    private var memory: [String: PersistedOddsBoard] = [:]
    private let prefix = "SlipRadar.liveOddsCache.v10."

    func get(_ key: String, maxAge: TimeInterval) -> [LiveMarketConsensus]? {
        if let item = memory[key], Date().timeIntervalSince(item.timestamp) <= maxAge {
            return item.values
        }

        let storageKey = prefix + key
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PersistedOddsBoard.self, from: data),
           Date().timeIntervalSince(decoded.timestamp) <= maxAge {
            memory[key] = decoded
            return decoded.values
        }

        return nil
    }

    func set(_ value: [LiveMarketConsensus], key: String) {
        let item = PersistedOddsBoard(timestamp: Date(), values: value)
        memory[key] = item
        if let data = try? JSONEncoder().encode(item) {
            UserDefaults.standard.set(data, forKey: prefix + key)
        }
    }
}

private actor OddsUsageStore {
    static let shared = OddsUsageStore()
    private var snapshot: OddsUsageSnapshot?

    func set(remaining: Int?, used: Int?, lastCost: Int?) {
        snapshot = OddsUsageSnapshot(
            remaining: remaining,
            used: used,
            lastCost: lastCost,
            updatedAt: Date()
        )
    }

    func get() -> OddsUsageSnapshot? { snapshot }
}

enum LiveOddsService {
    static func usageSnapshot() async -> OddsUsageSnapshot? {
        await OddsUsageStore.shared.get()
    }

    static func fetchTeamConsensus(
        sport: SportFilter,
        apiKey: String,
        force: Bool = false,
        cacheMaxAge: TimeInterval = 300
    ) async throws -> [LiveMarketConsensus] {
        guard let sportKey = sport.oddsAPISportKey else { throw SlipRadarError.unsupportedSport }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SlipRadarError.liveOddsNotConfigured }

        if !force, let cached = await LiveOddsCache.shared.get(sportKey, maxAge: cacheMaxAge) { return cached }

        var components = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/odds")!
        components.queryItems = [
            URLQueryItem(name: "apiKey", value: key),
            URLQueryItem(name: "regions", value: "us"),
            URLQueryItem(name: "markets", value: "h2h,spreads,totals"),
            URLQueryItem(name: "oddsFormat", value: "american"),
            URLQueryItem(name: "dateFormat", value: "iso")
        ]
        let games: [OddsAPIGame] = try await fetchJSON(components.url!)
        let result = consensus(from: games.flatMap(teamQuoteRows))
        await LiveOddsCache.shared.set(result, key: sportKey)
        return result
    }

    static func fetchAllActiveTeamBoards(apiKey: String) async throws -> [SportFilter: [LiveMarketConsensus]] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SlipRadarError.liveOddsNotConfigured }

        var components = URLComponents(string: "https://api.the-odds-api.com/v4/sports")!
        components.queryItems = [URLQueryItem(name: "apiKey", value: key)]
        let active: [OddsAPISport] = try await fetchJSON(components.url!)
        let activeKeys = Set(active.filter(\.active).map(\.key))
        let sports = SportFilter.modeledSports.filter { sport in
            guard let key = sport.oddsAPISportKey else { return false }
            return activeKeys.contains(key)
        }

        return await withTaskGroup(of: (SportFilter, [LiveMarketConsensus]?).self) { group in
            for sport in sports {
                group.addTask {
                    (sport, try? await fetchTeamConsensus(
                        sport: sport,
                        apiKey: key,
                        cacheMaxAge: 900
                    ))
                }
            }
            var output: [SportFilter: [LiveMarketConsensus]] = [:]
            for await (sport, board) in group {
                if let board, !board.isEmpty {
                    output[sport] = board
                }
            }
            return output
        }
    }

    static func makeBets(from consensus: [LiveMarketConsensus], sport: SportFilter) -> [PopularBet] {
        consensus.map { item in
            let side: String
            if item.market == "Spread", let point = item.point {
                side = "\(item.outcome) \(formatSigned(point))"
            } else if item.market == "Total", let point = item.point {
                side = "\(item.outcome) \(formatPoint(point))"
            } else {
                side = item.outcome
            }
            return PopularBet(
                source: .multiBook,
                matchup: item.event,
                side: side,
                market: item.market,
                startTime: item.lastUpdated.formatted(date: .omitted, time: .shortened),
                odds: item.bestOdds,
                betsPercent: 0,
                moneyPercent: nil,
                splitDifference: nil,
                sport: sport
            )
        }
    }

    static func verifyProp(_ prop: PropPick, sport: SportFilter, apiKey: String) async throws -> LivePropVerification {
        guard let sportKey = sport.oddsAPISportKey else { throw SlipRadarError.unsupportedSport }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SlipRadarError.liveOddsNotConfigured }
        guard let marketKey = propMarketKey(prop, sport: sport) else {
            return unverified(prop, note: "This prop type is not mapped to a live multi-book market yet.")
        }

        var eventComponents = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/events")!
        eventComponents.queryItems = [URLQueryItem(name: "apiKey", value: key)]
        let events: [OddsAPIEventStub] = try await fetchJSON(eventComponents.url!)

        guard let event = events.max(by: { eventMatchScore($0, prop.event) < eventMatchScore($1, prop.event) }),
              eventMatchScore(event, prop.event) >= 0.55 else {
            return unverified(prop, note: "The current event could not be matched to the live multi-book board.")
        }

        var oddsComponents = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/events/\(event.id)/odds")!
        oddsComponents.queryItems = [
            URLQueryItem(name: "apiKey", value: key),
            URLQueryItem(name: "regions", value: "us"),
            URLQueryItem(name: "markets", value: marketKey),
            URLQueryItem(name: "oddsFormat", value: "american"),
            URLQueryItem(name: "dateFormat", value: "iso")
        ]

        let game: OddsAPIGame = try await fetchJSON(oddsComponents.url!)
        let rows = propQuoteRows(game, marketKey: marketKey, prop: prop)
        guard !rows.isEmpty else { return unverified(prop, note: "No matching live player/side was returned by the selected sportsbooks.") }

        let requestedPoint = prop.threshold
        let exact = requestedPoint == nil ? rows : rows.filter { row in
            guard let p = row.point, let requestedPoint else { return false }
            return abs(p - requestedPoint) < 0.001
        }
        let chosen: [QuoteRow]
        let status: LiveLineStatus
        if !exact.isEmpty {
            chosen = exact
            status = .live
        } else {
            let grouped = Dictionary(grouping: rows) { $0.point ?? -9999 }
            chosen = grouped.values.max(by: { $0.count < $1.count }) ?? rows
            status = .mismatch
        }

        let fair = chosen.map(\.fairProbability).reduce(0, +) / Double(chosen.count)
        let implied = chosen.map(\.impliedProbability).reduce(0, +) / Double(chosen.count)
        let bestRow = chosen.max(by: { $0.price < $1.price })
        let books = Array(Set(chosen.map(\.bookmaker))).sorted()
        let livePoint = chosen.compactMap(\.point).first
        let note: String
        if status == .live {
            note = "\(books.count) live book\(books.count == 1 ? "" : "s") confirm the exact prop line."
        } else if let requestedPoint, let livePoint {
            note = "Requested line \(formatPoint(requestedPoint)) does not match live consensus \(formatPoint(livePoint))."
        } else {
            note = "The market exists live, but the exact requested line could not be confirmed."
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
            bestOdds: bestRow.map { OddsMath.americanString($0.price) },
            bestBook: bestRow?.bookmaker,
            eventStart: isoDate(event.commenceTime),
            bookCount: books.count,
            books: books,
            checkedAt: Date(),
            note: note
        )
    }

    static func matchConsensus(for bet: PopularBet, in live: [LiveMarketConsensus]) -> LiveMarketConsensus? {
        let marketName = normalizedMarket(bet.market)
        let matches = live.filter { MarketKey.sameEvent($0.event, bet.matchup) && $0.market == marketName }
        guard !matches.isEmpty else { return nil }
        let selectionPoint = numericPoint(bet.side)
        let scored = matches.map { item -> (LiveMarketConsensus, Double) in
            var score = selectionScore(bet.side, item.outcome)
            if let selectionPoint, let point = item.point {
                score += abs(selectionPoint - point) < 0.001 ? 0.5 : 0
            } else if selectionPoint == nil && item.point == nil {
                score += 0.2
            }
            return (item, score)
        }
        return scored.max(by: { $0.1 < $1.1 }).flatMap { $0.1 >= 0.45 ? $0.0 : nil }
    }

    static func lineStatus(for bet: PopularBet, consensus: LiveMarketConsensus?) -> LiveLineStatus {
        guard let consensus else { return .unverified }
        if Date().timeIntervalSince(consensus.lastUpdated) > 15 * 60 { return .stale }
        if let requested = numericPoint(bet.side), let livePoint = consensus.point {
            return abs(requested - livePoint) < 0.001 ? .live : .mismatch
        }
        return .live
    }

    static func numericPoint(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?"#) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last else { return nil }
        return Double(ns.substring(with: match.range))
    }

    private static func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("SlipRadar/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw SlipRadarError.noData }

        let remaining = Int(http.value(forHTTPHeaderField: "x-requests-remaining") ?? "")
        let used = Int(http.value(forHTTPHeaderField: "x-requests-used") ?? "")
        let last = Int(http.value(forHTTPHeaderField: "x-requests-last") ?? "")
        await OddsUsageStore.shared.set(remaining: remaining, used: used, lastCost: last)

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
                    case "spreads": return String(format: "%.3f", abs(outcome.point ?? 0))
                    case "totals": return String(format: "%.3f", outcome.point ?? 0)
                    default: return "all"
                    }
                }
                for outcomes in groups.values {
                    let implied = outcomes.map { OddsMath.impliedProbability(fromAmerican: $0.price) }
                    let total = implied.reduce(0, +)
                    guard total > 0 else { continue }
                    for (index, outcome) in outcomes.enumerated() {
                        rows.append(QuoteRow(
                            event: event,
                            market: displayMarket,
                            outcome: outcome.name,
                            description: outcome.description,
                            point: outcome.point,
                            bookmaker: bookmaker.title,
                            price: outcome.price,
                            fairProbability: implied[index] / total * 100,
                            impliedProbability: implied[index],
                            updated: updated,
                            commenceTime: isoDate(game.commenceTime)
                        ))
                    }
                }
            }
        }
        return rows
    }

    private static func propQuoteRows(_ game: OddsAPIGame, marketKey: String, prop: PropPick) -> [QuoteRow] {
        let player = MarketKey.normalized(prop.playerName)
        let desired = prop.direction?.lowercased()
        var rows: [QuoteRow] = []
        for bookmaker in game.bookmakers {
            for market in bookmaker.markets where market.key == marketKey {
                let updated = isoDate(market.lastUpdate ?? bookmaker.lastUpdate) ?? Date()
                let targets = market.outcomes.filter { outcome in
                    let desc = MarketKey.normalized(outcome.description ?? "")
                    let name = MarketKey.normalized(outcome.name)
                    let playerMatches = !player.isEmpty && (desc == player || desc.contains(player) || player.contains(desc))
                    return playerMatches && (desired == nil || name == desired)
                }
                for target in targets {
                    let pair = market.outcomes.filter {
                        MarketKey.normalized($0.description ?? "") == MarketKey.normalized(target.description ?? "") &&
                        abs(($0.point ?? -9999) - (target.point ?? -9999)) < 0.001
                    }
                    let implied = pair.map { OddsMath.impliedProbability(fromAmerican: $0.price) }
                    let total = implied.reduce(0, +)
                    guard let index = pair.firstIndex(where: { $0.name == target.name && $0.price == target.price && $0.point == target.point }), total > 0 else { continue }
                    rows.append(QuoteRow(
                        event: "\(game.awayTeam) @ \(game.homeTeam)",
                        market: marketKey,
                        outcome: target.name,
                        description: target.description,
                        point: target.point,
                        bookmaker: bookmaker.title,
                        price: target.price,
                        fairProbability: implied[index] / total * 100,
                        impliedProbability: implied[index],
                        updated: updated,
                        commenceTime: isoDate(game.commenceTime)
                    ))
                }
            }
        }
        return rows
    }

    private static func consensus(from rows: [QuoteRow]) -> [LiveMarketConsensus] {
        let grouped = Dictionary(grouping: rows) { row in
            [MarketKey.normalized(row.event), row.market, MarketKey.normalized(row.outcome), row.point.map { String(format: "%.3f", $0) } ?? "nil"].joined(separator: "|")
        }
        return grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            let fair = group.map(\.fairProbability).reduce(0, +) / Double(group.count)
            let implied = group.map(\.impliedProbability).reduce(0, +) / Double(group.count)
            guard let bestRow = group.max(by: { $0.price < $1.price }) else { return nil }
            let books = Array(Set(group.map(\.bookmaker))).sorted()
            return LiveMarketConsensus(
                id: [MarketKey.normalized(first.event), first.market, MarketKey.normalized(first.outcome), first.point.map { String($0) } ?? "nil"].joined(separator: "|"),
                event: first.event,
                market: first.market,
                outcome: first.outcome,
                point: first.point,
                fairProbability: fair,
                averageImpliedProbability: implied,
                bestOdds: OddsMath.americanString(bestRow.price),
                bestBook: bestRow.bookmaker,
                commenceTime: group.compactMap(\.commenceTime).min(),
                bookCount: books.count,
                books: books,
                lastUpdated: group.map(\.updated).max() ?? Date()
            )
        }
    }

    private static func unverified(_ prop: PropPick, note: String) -> LivePropVerification {
        LivePropVerification(
            status: .unverified, event: prop.event, market: prop.market, player: prop.playerName,
            direction: prop.direction, requestedPoint: prop.threshold, livePoint: nil,
            fairProbability: nil, averageImpliedProbability: nil, bestOdds: nil, bestBook: nil,
            eventStart: nil,
            bookCount: 0, books: [], checkedAt: Date(), note: note
        )
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
        case .soccer, .all: return nil
        }
        return nil
    }

    private static func eventMatchScore(_ event: OddsAPIEventStub, _ text: String) -> Double {
        let a = MarketKey.eventTokens(text)
        let b = MarketKey.eventTokens("\(event.awayTeam) @ \(event.homeTeam)")
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
    private static func selectionScore(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(MarketKey.selectionBase(lhs).split(separator: " ").map(String.init))
        let b = Set(MarketKey.selectionBase(rhs).split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
    private static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
    private static func formatPoint(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
    private static func formatSigned(_ value: Double) -> String {
        let base = formatPoint(abs(value))
        return value >= 0 ? "+\(base)" : "-\(base)"
    }
}
