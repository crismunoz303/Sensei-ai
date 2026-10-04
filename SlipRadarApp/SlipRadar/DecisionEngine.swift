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
        return Set(
            normalized(text)
                .split(separator: " ")
                .map(String.init)
                .filter { !ignored.contains($0) }
        )
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
        return overlap / Double(min(a.count, b.count)) >= 0.6
    }

    static func betHistoryKey(_ bet: PopularBet) -> String {
        [
            normalized(bet.matchup),
            normalized(bet.market),
            selectionBase(bet.side)
        ].joined(separator: "|")
    }

    static func propHistoryKey(_ prop: PropPick) -> String {
        [
            normalized(prop.event),
            normalized(prop.market),
            selectionBase(prop.line)
        ].joined(separator: "|")
    }
}

enum ContextAnalyzer {
    static func flags(for playerName: String, in text: String) -> [String] {
        let name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.split(separator: " ").count >= 2, !text.isEmpty else { return [] }

        let lowerText = text.lowercased() as NSString
        let match = lowerText.range(of: name.lowercased())
        guard match.location != NSNotFound else { return [] }

        let start = max(0, match.location - 220)
        let end = min(lowerText.length, match.location + match.length + 280)
        let window = lowerText.substring(with: NSRange(location: start, length: end - start))

        let severe = [" out ", "inactive", "injured reserve", " il ", " ir ", "suspended"]
        let caution = ["questionable", "doubtful", "day-to-day", "game-time decision", "minutes restriction"]

        if severe.contains(where: { window.contains($0) }) {
            return ["Public injury context shows a severe availability warning near \(name)."]
        }
        if caution.contains(where: { window.contains($0) }) {
            return ["Public injury context shows a caution/availability warning near \(name)."]
        }
        return []
    }
}

enum DecisionEngine {
    static func report(
        for bet: PopularBet,
        board: [PopularBet],
        liveConsensus: LiveMarketConsensus?,
        teamProjection: TeamProjection?,
        liveConfigured: Bool
    ) -> DecisionReport {
        let model = StatProjectionService.teamModelProbability(for: bet, projection: teamProjection)
        let fallbackFair = fairProbability(for: bet, board: board)
        let fair = liveConsensus?.fairProbability ?? fallbackFair
        let market = liveConsensus?.averageImpliedProbability ?? bet.impliedProbability
        let lineStatus: LiveLineStatus = {
            if !liveConfigured { return .notConnected }
            return LiveOddsService.lineStatus(for: bet, consensus: liveConsensus)
        }()

        let sourceCount = sourceCount(for: bet, board: board)
        let movement = MarketHistoryStore.movement(for: bet)

        var score = 0
        var quality = 0
        var reasons: [String] = []
        var risks: [String] = []

        if let model, let projection = teamProjection {
            let sample = projection.sampleSize
            score += 42
            quality += min(35, 20 + sample)
            reasons.append(String(
                format: "Independent recent-performance model: %.1f%% from %d-game team samples.",
                model,
                sample
            ))
            reasons.append(String(
                format: "Projected score: %@ %.1f, %@ %.1f.",
                projection.awayTeam,
                projection.projectedAwayScore,
                projection.homeTeam,
                projection.projectedHomeScore
            ))
        } else {
            risks.append("No reliable independent team-stat projection was available for this exact market.")
        }

        if let live = liveConsensus {
            quality += min(30, 12 + live.bookCount * 5)
            score += min(18, 8 + live.bookCount * 2)
            reasons.append(String(
                format: "Live de-vig consensus: %.1f%% across %d book%@ (%@).",
                live.fairProbability,
                live.bookCount,
                live.bookCount == 1 ? "" : "s",
                live.books.joined(separator: ", ")
            ))
            reasons.append("Best observed price: \(live.bestOdds).")
        } else if let fallbackFair {
            quality += 10
            score += 5
            reasons.append(String(format: "Fallback de-vig estimate from the available listed market: %.1f%%.", fallbackFair))
            risks.append("Multi-book live consensus was not available for this selection.")
        } else if let market {
            quality += 6
            reasons.append(String(format: "Listed price implies %.1f%% before removing sportsbook margin.", market))
            risks.append("No complete two-sided live market was available for de-vigging.")
        }

        var edge: Double?
        if let model, let fair {
            let value = model - fair
            edge = value

            if value >= 6 {
                score += 18
                reasons.append(String(format: "Model edge over market fair probability: +%.1f points.", value))
            } else if value >= 3 {
                score += 12
                reasons.append(String(format: "Model edge over market fair probability: +%.1f points.", value))
            } else if value >= 1 {
                score += 5
                reasons.append(String(format: "Small model edge: +%.1f points.", value))
            } else if value < 0 {
                score -= 15
                risks.append(String(format: "Independent model is %.1f points below the market.", abs(value)))
            }
        }

        switch lineStatus {
        case .live:
            score += 10
            quality += 15
            reasons.append("The exact market/line is confirmed on the live multi-book board.")
        case .mismatch:
            score -= 40
            risks.append("Current live line does not match the line being scored.")
        case .stale:
            score -= 30
            risks.append("The live market is stale.")
        case .unverified:
            score -= 8
            risks.append("The current line could not be verified across the connected books.")
        case .notConnected:
            score -= 8
            risks.append("Live multi-book verification is not connected.")
        }

        if let money = bet.moneyPercent {
            let publicEdge = money - bet.betsPercent
            if publicEdge >= 8 {
                score += 5
                reasons.append("\(money)% money vs \(bet.betsPercent)% bets gives a secondary +\(publicEdge)-point confirmation.")
            } else if publicEdge >= 3 {
                score += 2
                reasons.append("Public money/ticket split gives mild confirmation.")
            } else if publicEdge < -5 {
                score -= 2
                risks.append("Public money trails ticket share.")
            }
        }

        if sourceCount >= 2 {
            score += 4
            quality += 5
            reasons.append("\(sourceCount) public split sources point to the same selection.")
        }

        if let movement {
            let adjustment = max(-4, min(5, movement.supportPoints))
            score += adjustment
            quality += 4
            reasons.append(movement.summary)
        }

        risks.append("Public betting popularity is intentionally a minor input, not the prediction engine.")
        risks.append("Recent-team modeling is a statistical estimate; roster changes and matchup effects can still invalidate it.")

        score = min(100, max(0, score))
        quality = min(100, max(0, quality))

        let verdict: PickVerdict
        if lineStatus == .mismatch || lineStatus == .stale {
            verdict = .pass
        } else if let model, let edge,
                  lineStatus == .live,
                  (liveConsensus?.bookCount ?? 0) >= 2,
                  model >= 57,
                  edge >= 3,
                  score >= 78,
                  quality >= 68 {
            verdict = .lock
        } else if let model, let edge,
                  model >= 54,
                  edge >= 1.5,
                  score >= 62,
                  lineStatus == .live {
            verdict = .strong
        } else if model != nil && score >= 48 {
            verdict = .consider
        } else {
            verdict = .pass
        }

        return DecisionReport(
            modelProbability: model,
            fairProbability: fair,
            marketProbability: market,
            estimatedEdge: edge,
            evidenceScore: score,
            dataQuality: quality,
            sourceCount: sourceCount,
            liveStatus: lineStatus,
            verdict: verdict,
            reasons: reasons,
            risks: risks
        )
    }

    static func report(
        for prop: PropPick,
        projection: StatProjection?,
        verification: LivePropVerification?,
        contextText: String,
        liveConfigured: Bool
    ) -> DecisionReport {
        let model = projection?.modelProbability
        let fair = verification?.status == .live
            ? verification?.fairProbability
            : prop.impliedProbability
        let market = verification?.averageImpliedProbability ?? prop.impliedProbability
        let lineStatus: LiveLineStatus = {
            if !liveConfigured { return .notConnected }
            return verification?.status ?? .unverified
        }()

        let movement = MarketHistoryStore.movement(for: prop)
        let contextFlags = ContextAnalyzer.flags(for: prop.playerName, in: contextText)

        var score = 0
        var quality = 0
        var reasons: [String] = []
        var risks: [String] = []

        if let projection {
            let sample = projection.sampleSize
            score += 48
            quality += min(40, 22 + sample)
            reasons.append(String(
                format: "Independent %@ model: %.1f%% (%d games).",
                projection.metricName,
                projection.modelProbability,
                sample
            ))
            reasons.append(String(
                format: "Recent average %.2f vs %.2f line; last-%d hit rate %.0f%%.",
                projection.recentAverage,
                projection.threshold,
                projection.recentSampleSize,
                projection.recentHitRate
            ))
            reasons.append(String(
                format: "Season sample average %.2f; season hit rate %.0f%%.",
                projection.seasonAverage,
                projection.seasonHitRate
            ))

            if projection.calibratedSampleSize >= 10 {
                reasons.append("Probability was calibration-adjusted using \(projection.calibratedSampleSize) previously settled tracked picks.")
            }
        } else {
            risks.append("No verified recent-game statistical projection is available for this prop.")
        }

        if let verification {
            if verification.status == .live,
               let liveFair = verification.fairProbability {
                score += min(18, 8 + verification.bookCount * 2)
                quality += min(30, 10 + verification.bookCount * 5)
                reasons.append(String(
                    format: "Exact live line confirmed by %d book%@; de-vig fair probability %.1f%%.",
                    verification.bookCount,
                    verification.bookCount == 1 ? "" : "s",
                    liveFair
                ))
                if let best = verification.bestOdds {
                    reasons.append("Best observed live price: \(best).")
                }
            } else {
                risks.append(verification.note)
            }
        } else if liveConfigured {
            risks.append("Live prop verification has not been run for this prop yet.")
        } else {
            risks.append("Live multi-book prop verification is not connected.")
        }

        var edge: Double?
        if let model, let fair {
            let value = model - fair
            edge = value

            if value >= 7 {
                score += 18
                reasons.append(String(format: "Independent model edge: +%.1f percentage points.", value))
            } else if value >= 4 {
                score += 14
                reasons.append(String(format: "Independent model edge: +%.1f percentage points.", value))
            } else if value >= 2 {
                score += 7
                reasons.append(String(format: "Modest model edge: +%.1f points.", value))
            } else if value < 0 {
                score -= 16
                risks.append(String(format: "Model probability is %.1f points below the market.", abs(value)))
            }
        }

        if !contextText.isEmpty {
            quality += 8
            if prop.playerName.isEmpty {
                risks.append("Player name could not be parsed reliably for injury matching.")
            } else if contextFlags.isEmpty {
                reasons.append("No injury warning was detected for \(prop.playerName) on the loaded public injury page.")
            } else {
                score -= 35
                risks.append(contentsOf: contextFlags)
            }
        } else {
            risks.append("Live injury/availability context was unavailable.")
        }

        if let handle = prop.handlePercent, let tickets = prop.betPercent {
            let publicEdge = handle - tickets
            if publicEdge >= 8 {
                score += 5
                reasons.append(String(format: "Public money adds secondary confirmation: %.0f%% handle vs %.0f%% tickets.", handle, tickets))
            } else if publicEdge >= 3 {
                score += 2
            }
        }

        if let movement {
            score += max(-4, min(5, movement.supportPoints))
            quality += 4
            reasons.append(movement.summary)
        }

        switch lineStatus {
        case .live:
            score += 8
        case .mismatch:
            score -= 40
        case .stale:
            score -= 35
        case .unverified:
            score -= 10
        case .notConnected:
            score -= 8
        }

        risks.append("Recent hit rate is not treated as the probability by itself; the model also uses the distribution of the game log.")
        risks.append("Public bet popularity has little to no influence unless it confirms an independently favorable projection.")

        score = min(100, max(0, score))
        quality = min(100, max(0, quality))

        let severeContext = !contextFlags.isEmpty
        let verdict: PickVerdict

        if severeContext || lineStatus == .mismatch || lineStatus == .stale {
            verdict = .pass
        } else if let model, let edge,
                  lineStatus == .live,
                  (verification?.bookCount ?? 0) >= 2,
                  model >= 60,
                  edge >= 4,
                  score >= 80,
                  quality >= 68 {
            verdict = .lock
        } else if let model, let edge,
                  lineStatus == .live,
                  model >= 56,
                  edge >= 2,
                  score >= 64 {
            verdict = .strong
        } else if model != nil && score >= 48 {
            verdict = .consider
        } else {
            verdict = .pass
        }

        return DecisionReport(
            modelProbability: model,
            fairProbability: fair,
            marketProbability: market,
            estimatedEdge: edge,
            evidenceScore: score,
            dataQuality: quality,
            sourceCount: verification?.bookCount ?? 1,
            liveStatus: lineStatus,
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
