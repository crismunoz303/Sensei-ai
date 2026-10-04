import Foundation

private actor ContextCache {
    static let shared = ContextCache()
    private var values: [String: (Date, Data)] = [:]

    func get(_ key: String, maxAge: TimeInterval) -> Data? {
        guard let item = values[key], Date().timeIntervalSince(item.0) <= maxAge else { return nil }
        return item.1
    }

    func set(_ data: Data, key: String) {
        values[key] = (Date(), data)
    }
}

enum EventContextService {
    static func fetchContexts(sport: SportFilter) async throws -> [EventContextSnapshot] {
        guard let route = sport.espnRoute else { throw SlipRadarError.unsupportedSport }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let start = Date().addingTimeInterval(-6 * 3600)
        let end = Date().addingTimeInterval(4 * 86400)
        var components = URLComponents(
            string: "https://site.api.espn.com/apis/site/v2/sports/\(route.sport)/\(route.league)/scoreboard"
        )!
        components.queryItems = [
            URLQueryItem(name: "dates", value: "\(formatter.string(from: start))-\(formatter.string(from: end))"),
            URLQueryItem(name: "limit", value: "200")
        ]

        let data = try await fetch(components.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            return []
        }

        return events.compactMap { event in
            guard let eventID = stringValue(event["id"]) else { return nil }
            let name = stringValue(event["name"]) ?? stringValue(event["shortName"]) ?? eventID
            let status = ((event["status"] as? [String: Any])?["type"] as? [String: Any]).flatMap {
                stringValue($0["shortDetail"]) ?? stringValue($0["detail"]) ?? stringValue($0["description"])
            }

            let competition = (event["competitions"] as? [[String: Any]])?.first
            let venue = (competition?["venue"] as? [String: Any]).flatMap {
                stringValue($0["fullName"]) ?? stringValue($0["shortName"]) ?? stringValue($0["name"])
            }

            let weatherObject = competition?["weather"] as? [String: Any]
            let weather = weatherObject.flatMap {
                stringValue($0["displayValue"]) ??
                stringValue($0["conditionId"]) ??
                stringValue($0["condition"])
            }

            let wind = extractWindMPH(weather ?? "")
            let severity = weatherSeverity(weather ?? "", wind: wind)

            return EventContextSnapshot(
                id: eventID,
                sport: sport,
                event: name,
                venue: venue,
                weather: weather,
                windMPH: wind,
                weatherSeverity: severity,
                statusText: status,
                updatedAt: Date()
            )
        }
    }

    static func matchContext(
        event: String,
        sport: SportFilter,
        contexts: [EventContextSnapshot]
    ) -> EventContextSnapshot? {
        contexts
            .filter { $0.sport == sport }
            .map { ($0, eventScore(event, $0.event)) }
            .filter { $0.1 >= 0.55 }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    static func playerAvailability(
        playerName: String,
        event: String,
        sport: SportFilter
    ) async -> PlayerAvailabilitySnapshot {
        guard let route = sport.espnRoute,
              !playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PlayerAvailabilitySnapshot(
                player: playerName,
                severity: .unknown,
                starterConfirmed: nil,
                activeConfirmed: nil,
                note: "Player/event could not be resolved for lineup validation.",
                checkedAt: Date()
            )
        }

        do {
            let contexts = try await fetchContexts(sport: sport)
            guard let matched = matchContext(event: event, sport: sport, contexts: contexts) else {
                return unknown(playerName, "Current ESPN event could not be matched for lineup validation.")
            }

            var components = URLComponents(
                string: "https://site.api.espn.com/apis/site/v2/sports/\(route.sport)/\(route.league)/summary"
            )!
            components.queryItems = [URLQueryItem(name: "event", value: matched.id)]
            let data = try await fetch(components.url!)
            let root = try JSONSerialization.jsonObject(with: data)

            let target = MarketKey.normalized(playerName)
            var matches: [[String: Any]] = []

            func walk(_ value: Any) {
                if let dictionary = value as? [String: Any] {
                    let name = stringValue(dictionary["displayName"]) ??
                        stringValue(dictionary["fullName"]) ??
                        stringValue(dictionary["shortName"]) ??
                        stringValue(dictionary["name"])

                    if let name, nameSimilarity(target, MarketKey.normalized(name)) >= 0.72 {
                        matches.append(dictionary)
                    }

                    for child in dictionary.values { walk(child) }
                } else if let array = value as? [Any] {
                    for child in array { walk(child) }
                }
            }

            walk(root)
            guard !matches.isEmpty else {
                return unknown(playerName, "Player was not found in the current event roster/summary.")
            }

            var starter: Bool?
            var active: Bool?
            var words: [String] = []

            for dictionary in matches {
                if let value = dictionary["starter"] as? Bool { starter = value }
                if let value = dictionary["active"] as? Bool { active = value }
                collectStatusWords(dictionary, into: &words)
            }

            let joined = words.joined(separator: " ").lowercased()
            let severeTokens = ["out", "inactive", "suspended", "injured reserve", "disabled list", "ruled out"]
            let cautionTokens = ["questionable", "doubtful", "day-to-day", "game-time", "limited", "minutes restriction"]

            if active == false || severeTokens.contains(where: { joined.contains($0) }) {
                return PlayerAvailabilitySnapshot(
                    player: playerName,
                    severity: .severe,
                    starterConfirmed: starter,
                    activeConfirmed: active,
                    note: "Current event data indicates \(playerName) is unavailable or carries a severe status.",
                    checkedAt: Date()
                )
            }

            if cautionTokens.contains(where: { joined.contains($0) }) {
                return PlayerAvailabilitySnapshot(
                    player: playerName,
                    severity: .caution,
                    starterConfirmed: starter,
                    activeConfirmed: active,
                    note: "Current event data carries a caution/availability flag for \(playerName).",
                    checkedAt: Date()
                )
            }

            let note: String
            if starter == true {
                note = "\(playerName) is shown as a starter in the current event data."
            } else if active == true {
                note = "\(playerName) is shown active in the current event data; starter status is not confirmed."
            } else {
                note = "No severe availability flag was found, but starter/active status is not explicitly confirmed."
            }

            return PlayerAvailabilitySnapshot(
                player: playerName,
                severity: .clear,
                starterConfirmed: starter,
                activeConfirmed: active,
                note: note,
                checkedAt: Date()
            )
        } catch {
            return unknown(playerName, "Lineup validation failed: \(error.localizedDescription)")
        }
    }

    static func weatherAdjustment(
        for bet: PopularBet,
        sport: SportFilter,
        context: EventContextSnapshot?
    ) -> (points: Double, note: String?) {
        guard sport.isOutdoorWeatherRelevant,
              let context,
              context.weatherSeverity > 0,
              bet.market.lowercased().contains("total") else {
            return (0, nil)
        }

        let side = bet.side.lowercased()
        let magnitude = context.weatherSeverity >= 2 ? 2.0 : 1.0

        if side.contains("under") {
            return (magnitude, "Outdoor weather (\(context.weather ?? "adverse conditions")) slightly supports the Under.")
        }
        if side.contains("over") {
            return (-magnitude, "Outdoor weather (\(context.weather ?? "adverse conditions")) slightly works against the Over.")
        }
        return (0, nil)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let key = url.absoluteString
        if let cached = await ContextCache.shared.get(key, maxAge: 180) { return cached }

        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("SlipRadar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw SlipRadarError.noData
        }

        await ContextCache.shared.set(data, key: key)
        return data
    }

    private static func collectStatusWords(_ dictionary: [String: Any], into words: inout [String]) {
        for key in ["status", "description", "detail", "shortDetail", "type", "reason"] {
            if let string = stringValue(dictionary[key]) { words.append(string) }
            if let nested = dictionary[key] as? [String: Any] {
                for value in nested.values {
                    if let string = stringValue(value) { words.append(string) }
                }
            }
        }
    }

    private static func extractWindMPH(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*mph"#, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return Double(ns.substring(with: match.range(at: 1)))
    }

    private static func weatherSeverity(_ text: String, wind: Double?) -> Int {
        let lower = text.lowercased()
        var severity = 0

        if lower.contains("rain") || lower.contains("snow") || lower.contains("storm") ||
            lower.contains("showers") || lower.contains("sleet") {
            severity = max(severity, 1)
        }
        if lower.contains("heavy") || lower.contains("thunder") || lower.contains("blizzard") {
            severity = max(severity, 2)
        }
        if let wind {
            if wind >= 20 { severity = max(severity, 2) }
            else if wind >= 14 { severity = max(severity, 1) }
        }
        return severity
    }

    private static func eventScore(_ lhs: String, _ rhs: String) -> Double {
        let a = MarketKey.eventTokens(lhs)
        let b = MarketKey.eventTokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    private static func nameSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let a = Set(lhs.split(separator: " ").map(String.init))
        let b = Set(rhs.split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(max(a.count, b.count))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func unknown(_ player: String, _ note: String) -> PlayerAvailabilitySnapshot {
        PlayerAvailabilitySnapshot(
            player: player,
            severity: .unknown,
            starterConfirmed: nil,
            activeConfirmed: nil,
            note: note,
            checkedAt: Date()
        )
    }
}
