import Foundation

enum ResultAutoGrader {
    static func grade(_ pick: TrackedPick) async -> PickOutcome? {
        guard pick.outcome == .pending,
              pick.playerName == nil,
              let sportName = pick.sport,
              let sport = SportFilter(rawValue: sportName),
              let route = sport.espnRoute,
              sport != .all else {
            return nil
        }

        for offset in 0...3 {
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: pick.addedAt) else { continue }

            do {
                let finals = try await fetchFinals(route: route, date: date)
                guard let game = bestMatch(for: pick.event, in: finals) else { continue }
                return gradeTeamPick(pick, game: game)
            } catch {
                continue
            }
        }

        return nil
    }

    private struct FinalGame {
        let event: String
        let homeTeam: String
        let awayTeam: String
        let homeScore: Double
        let awayScore: Double
    }

    private static func fetchFinals(
        route: (sport: String, league: String, searchSport: String),
        date: Date
    ) async throws -> [FinalGame] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        var components = URLComponents(
            string: "https://site.api.espn.com/apis/site/v2/sports/\(route.sport)/\(route.league)/scoreboard"
        )!
        components.queryItems = [
            URLQueryItem(name: "dates", value: formatter.string(from: date)),
            URLQueryItem(name: "limit", value: "100")
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("SlipRadar/0.9", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            throw SlipRadarError.noData
        }

        return events.compactMap { event in
            guard let status = event["status"] as? [String: Any],
                  let type = status["type"] as? [String: Any],
                  (type["completed"] as? Bool) == true,
                  let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let competitors = competition["competitors"] as? [[String: Any]] else {
                return nil
            }

            var homeTeam: String?
            var awayTeam: String?
            var homeScore: Double?
            var awayScore: Double?

            for competitor in competitors {
                guard let team = competitor["team"] as? [String: Any] else { continue }
                let name = (team["displayName"] as? String) ?? (team["name"] as? String) ?? ""
                let homeAway = competitor["homeAway"] as? String
                let score: Double? = {
                    if let string = competitor["score"] as? String { return Double(string) }
                    if let number = competitor["score"] as? NSNumber { return number.doubleValue }
                    return nil
                }()

                if homeAway == "home" {
                    homeTeam = name
                    homeScore = score
                } else if homeAway == "away" {
                    awayTeam = name
                    awayScore = score
                }
            }

            guard let homeTeam, let awayTeam, let homeScore, let awayScore else { return nil }

            return FinalGame(
                event: (event["name"] as? String) ?? "\(awayTeam) @ \(homeTeam)",
                homeTeam: homeTeam,
                awayTeam: awayTeam,
                homeScore: homeScore,
                awayScore: awayScore
            )
        }
    }

    private static func bestMatch(for eventText: String, in games: [FinalGame]) -> FinalGame? {
        games
            .map { ($0, eventScore(eventText, $0.event)) }
            .filter { $0.1 >= 0.55 }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    private static func gradeTeamPick(_ pick: TrackedPick, game: FinalGame) -> PickOutcome? {
        let market = pick.market.lowercased()
        let title = pick.title.lowercased()

        if market.contains("total") {
            guard let line = numericPoint(pick.title) else { return nil }
            let total = game.homeScore + game.awayScore
            if title.contains("under") { return compare(total, line: line, direction: "under") }
            if title.contains("over") { return compare(total, line: line, direction: "over") }
            return nil
        }

        if market.contains("moneyline") {
            let selectedHome = teamScore(pick.title, game.homeTeam) >= teamScore(pick.title, game.awayTeam)
            let selected = selectedHome ? game.homeScore : game.awayScore
            let opponent = selectedHome ? game.awayScore : game.homeScore
            if selected > opponent { return .win }
            if selected < opponent { return .loss }
            return .push
        }

        if market.contains("spread"), let spread = numericPoint(pick.title) {
            let selectedHome = teamScore(pick.title, game.homeTeam) >= teamScore(pick.title, game.awayTeam)
            let selected = selectedHome ? game.homeScore : game.awayScore
            let opponent = selectedHome ? game.awayScore : game.homeScore
            let adjusted = selected + spread
            if adjusted > opponent { return .win }
            if adjusted < opponent { return .loss }
            return .push
        }

        return nil
    }

    private static func compare(_ value: Double, line: Double, direction: String) -> PickOutcome {
        if value == line { return .push }
        if direction == "under" { return value < line ? .win : .loss }
        return value > line ? .win : .loss
    }

    private static func eventScore(_ lhs: String, _ rhs: String) -> Double {
        let a = MarketKey.eventTokens(lhs)
        let b = MarketKey.eventTokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    private static func teamScore(_ selection: String, _ team: String) -> Double {
        let a = Set(MarketKey.selectionBase(selection).split(separator: " ").map(String.init))
        let b = Set(MarketKey.normalized(team).split(separator: " ").map(String.init))
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
}
