import Foundation

enum MarketKey {
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func selectionBase(_ text: String) -> String {
        normalized(text.replacingOccurrences(
            of: #"[-+]?\d+(?:\.\d+)?"#,
            with: "",
            options: .regularExpression
        ))
    }

    static func eventTokens(_ text: String) -> Set<String> {
        let ignored = Set(["vs", "at", "the"])
        return Set(normalized(text).split(separator: " ").map(String.init).filter { !ignored.contains($0) })
    }

    static func sameEvent(_ lhs: String, _ rhs: String) -> Bool {
        let a = eventTokens(lhs)
        let b = eventTokens(rhs)
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let overlap = Double(a.intersection(b).count)
        return overlap / Double(min(a.count, b.count)) >= 0.6
    }

    static func sameSelection(_ lhs: String, _ rhs: String) -> Bool {
        let a = Set(selectionBase(lhs).split(separator: " ").map(String.init))
        let b = Set(selectionBase(rhs).split(separator: " ").map(String.init))
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let overlap = Double(a.intersection(b).count)
        return overlap / Double(min(a.count, b.count)) >= 0.7
    }

    static func betHistoryKey(_ bet: PopularBet) -> String {
        [normalized(bet.matchup), normalized(bet.market), selectionBase(bet.side)].joined(separator: "|")
    }

    static func propHistoryKey(_ prop: PropPick) -> String {
        [normalized(prop.event), normalized(prop.market), selectionBase(prop.line)].joined(separator: "|")
    }
}

enum ContextAnalyzer {
    static func flags(for playerName: String, in text: String) -> [String] {
        let name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.split(separator: " ").count >= 2, !text.isEmpty else { return [] }

        let lowerText = text.lowercased() as NSString
        let match = lowerText.range(of: name.lowercased())
        guard match.location != NSNotFound else { return [] }

        let start = max(0, match.location - 180)
        let end = min(lowerText.length, match.location + match.length + 220)
        let window = lowerText.substring(with: NSRange(location: start, length: end - start))

        let severe = [" out ", "inactive", "injured reserve", " il ", " ir "]
        let caution = ["questionable", "doubtful", "day-to-day", "game-time decision"]

        if severe.contains(where: { window.contains($0) }) {
            return ["Public injury context shows a severe status near \(name)."]
        }
        if caution.contains(where: { window.contains($0) }) {
            return ["Public injury context shows a caution status near \(name)."]
        }
        return []
    }
}

enum DecisionEngine {
    static func report(for bet: PopularBet, board: [PopularBet]) -> DecisionReport {
        let fair = fairProbability(for: bet, board: board)
        let market = bet.impliedProbability
        let sources = sourceCount(for: bet, board: board)
        let movement = MarketHistoryStore.movement(for: bet)

        var score = 0
        var quality = 0
        var reasons: [String] = []
        var risks: [String] = []

        if let fair {
            score += 35
            quality += 35
            score += min(10, max(0, Int((fair - 50.0) / 3.0)))
            reasons.append(String(format: "De-vigged fair probability: %.1f%% from the available two-sided market.", fair))
        } else if let market {
            score += 24
            quality += 22
            score += min(8, max(0, Int((market - 50.0) / 4.0)))
            reasons.append(String(format: "Listed price implies %.1f%% before removing sportsbook margin.", market))
            risks.append("No complete opposing-price set was available, so fair probability could not be de-vigged.")
        } else {
            quality += 5
            risks.append("No usable sportsbook price was available.")
        }

        if let money = bet.moneyPercent {
            quality += 20
            score += 10
            if money >= 70 { score += 8 }
            if money >= 80 { score += 4 }

            let edge = money - bet.betsPercent
            if edge >= 8 {
                score += 12
                reasons.append("\(money)% money vs \(bet.betsPercent)% bets: +\(edge)-point money-over-ticket support.")
            } else if edge >= 3 {
                score += 5
                reasons.append("\(money)% money vs \(bet.betsPercent)% bets: modest +\(edge)-point confirmation.")
            } else if edge < 0 {
                score -= 5
                risks.append("Money share trails ticket share by \(abs(edge)) points.")
            } else {
                reasons.append("\(bet.betsPercent)% bets / \(money)% money are broadly aligned.")
            }
        } else {
            risks.append("No verified money percentage is available.")
        }

        if sources >= 2 {
            score += 15
            quality += 20
            reasons.append("The same selection is supported by \(sources) independent public source feeds.")
        } else {
            quality += 5
            risks.append("Only one public source feed currently confirms this exact selection.")
        }

        if let movement {
            score += movement.supportPoints
            quality += 8
            reasons.append(movement.summary)
        } else {
            risks.append("No meaningful price movement history has been recorded yet.")
        }

        if bet.source == .draftKings {
            score -= 5
            risks.append("DraftKings split-feed lines can differ by jurisdiction; verify the exact line in your sportsbook.")
        }

        score -= 5
        risks.append("Public split pages do not expose a reliable wager-count sample size, so confidence is capped.")

        score = min(100, max(0, score))
        quality = min(100, max(0, quality))

        let probability = fair ?? market ?? 0
        let edge = bet.moneyEdge ?? -100

        let verdict: PickVerdict
        if sources >= 2 && score >= 78 && probability >= 54 && edge >= 3 {
            verdict = .lock
        } else if score >= 82 && probability >= 60 && (bet.moneyPercent ?? 0) >= 75 && edge >= 8 {
            verdict = .lock
        } else if score >= 62 && probability >= 52 {
            verdict = .strong
        } else if score >= 48 {
            verdict = .consider
        } else {
            verdict = .pass
        }

        return DecisionReport(
            fairProbability: fair,
            marketProbability: market,
            evidenceScore: score,
            dataQuality: quality,
            sourceCount: sources,
            verdict: verdict,
            reasons: reasons,
            risks: risks
        )
    }

    static func report(for prop: PropPick, contextText: String) -> DecisionReport {
        let market = prop.impliedProbability
        let movement = MarketHistoryStore.movement(for: prop)
        let contextFlags = ContextAnalyzer.flags(for: prop.playerName, in: contextText)

        var score = 0
        var quality = 0
        var reasons: [String] = []
        var risks: [String] = []

        if let market {
            score += 28
            quality += 30
            score += min(15, max(0, Int((market - 50.0) / 2.5)))
            reasons.append(String(format: "Sportsbook price implies %.1f%% before removing sportsbook margin.", market))
        } else {
            risks.append("No usable sportsbook price is available for this prop.")
        }

        if let handle = prop.handlePercent, let bets = prop.betPercent {
            quality += 25
            score += 10
            let edge = handle - bets
            if edge >= 8 {
                score += 12
                reasons.append(String(format: "%.0f%% handle vs %.0f%% bets (%+.0f points) supports the side.", handle, bets, edge))
            } else if edge >= 3 {
                score += 5
                reasons.append(String(format: "%.0f%% handle vs %.0f%% bets gives modest confirmation.", handle, bets))
            } else if edge < 0 {
                score -= 5
                risks.append(String(format: "Handle trails ticket share by %.0f points.", abs(edge)))
            }
        } else {
            risks.append("No verified public handle-vs-ticket split is available for this exact prop.")
        }

        if let movement {
            score += movement.supportPoints
            quality += 10
            reasons.append(movement.summary)
        } else {
            risks.append("No meaningful prop price movement has been recorded yet.")
        }

        if !contextText.isEmpty {
            quality += 10
            if prop.playerName.isEmpty {
                risks.append("Player name could not be parsed reliably for injury matching.")
            } else if contextFlags.isEmpty {
                reasons.append("No injury warning was detected for \(prop.playerName) on the loaded public injury page.")
            } else {
                score -= 25
                risks.append(contentsOf: contextFlags)
            }
        } else {
            risks.append("Live injury/lineup context was unavailable, so confidence is reduced.")
        }

        risks.append("Recent-form and matchup statistics are not used unless a verified feed is available; SlipRadar will not invent them.")
        score -= 5
        risks.append("Public prop sample size is not published, so evidence strength is capped.")

        score = min(100, max(0, score))
        quality = min(100, max(0, quality))

        let probability = market ?? 0
        let hasSplit = prop.handlePercent != nil && prop.betPercent != nil
        let severeContext = !contextFlags.isEmpty

        let verdict: PickVerdict
        if severeContext {
            verdict = .pass
        } else if hasSplit && score >= 82 && probability >= 60 {
            verdict = .lock
        } else if score >= 60 && probability >= 58 {
            verdict = .strong
        } else if score >= 45 && probability >= 52 {
            verdict = .consider
        } else {
            verdict = .pass
        }

        return DecisionReport(
            fairProbability: nil,
            marketProbability: market,
            evidenceScore: score,
            dataQuality: quality,
            sourceCount: 1,
            verdict: verdict,
            reasons: reasons,
            risks: risks
        )
    }

    private static func fairProbability(for bet: PopularBet, board: [PopularBet]) -> Double? {
        guard let target = bet.impliedProbability else { return nil }

        let marketGroup = board.filter {
            $0.source == bet.source &&
            MarketKey.sameEvent($0.matchup, bet.matchup) &&
            MarketKey.normalized($0.market) == MarketKey.normalized(bet.market)
        }
        let probabilities = marketGroup.compactMap { $0.impliedProbability }

        guard probabilities.count >= 2, probabilities.count == marketGroup.count else { return nil }
        let total = probabilities.reduce(0, +)
        guard total > 0 else { return nil }

        return target / total * 100.0
    }

    private static func sourceCount(for bet: PopularBet, board: [PopularBet]) -> Int {
        let matches = board.filter {
            MarketKey.sameEvent($0.matchup, bet.matchup) &&
            MarketKey.sameSelection($0.side, bet.side)
        }
        return Set(matches.map { $0.source }).count
    }
}
