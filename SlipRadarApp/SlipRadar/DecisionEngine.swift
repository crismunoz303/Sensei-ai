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
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.6
    }

    static func sameSelection(_ lhs: String, _ rhs: String) -> Bool {
        let a = Set(selectionBase(lhs).split(separator: " ").map(String.init))
        let b = Set(selectionBase(rhs).split(separator: " ").map(String.init))
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.7
    }

    static func betHistoryKey(_ bet: PopularBet) -> String {
        [
            bet.sport?.rawValue ?? "",
            normalized(bet.matchup),
            normalized(bet.market),
            selectionBase(bet.side)
        ].joined(separator: "|")
    }

    static func propHistoryKey(_ prop: PropPick) -> String {
        [
            prop.sport?.rawValue ?? "",
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

        let severe = [" out ", "inactive", "injured reserve", " il ", " ir ", "suspended", "ruled out"]
        let caution = ["questionable", "doubtful", "day-to-day", "game-time decision", "minutes restriction", "limited"]

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
        eventContext: EventContextSnapshot?,
        liveConfigured: Bool
    ) -> DecisionReport {
        var model = StatProjectionService.teamModelProbability(for: bet, projection: teamProjection)
        let weather = EventContextService.weatherAdjustment(
            for: bet,
            sport: bet.sport ?? .all,
            context: eventContext
        )
        if let current = model, weather.points != 0 {
            model = clamp(current + weather.points, 2, 98)
        }

        let fallbackFair = fairProbability(for: bet, board: board)
        let fair = liveConsensus?.fairProbability ?? fallbackFair
        let market = liveConsensus?.averageImpliedProbability ?? bet.impliedProbability
        let lineStatus: LiveLineStatus = {
            if !liveConfigured { return .notConnected }
            return LiveOddsService.lineStatus(for: bet, consensus: liveConsensus)
        }()
        let sources = sourceCount(for: bet, board: board)
        let movement = MarketHistoryStore.movement(for: bet)

        var evidence = 0
        var reasons: [String] = []
        var risks: [String] = []

        var statsQuality = 0
        var marketQuality = 0
        var availabilityQuality = 0
        var freshnessQuality = 0
        var historyQuality = 0
        var publicQuality = 0

        if let model, let projection = teamProjection {
            statsQuality = min(40, 24 + projection.sampleSize)
            evidence += 38
            evidence += max(-6, min(12, Int((model - 50) / 2)))
            reasons.append(String(
                format: "Independent team model: %.1f%% from recent scoring/defense distributions (%d-game samples).",
                model,
                projection.sampleSize
            ))
            reasons.append(String(
                format: "Projected score %.1f–%.1f; projected total %.1f.",
                projection.projectedAwayScore,
                projection.projectedHomeScore,
                projection.projectedTotal
            ))
            if let awayRest = projection.awayRestDays, let homeRest = projection.homeRestDays {
                reasons.append("Rest context: \(projection.awayTeam) \(awayRest)d • \(projection.homeTeam) \(homeRest)d since last recorded game.")
            }
        } else {
            risks.append("Independent team-stat projection is unavailable; this line cannot become a LOCK.")
        }

        if let live = liveConsensus {
            marketQuality = min(25, 10 + live.bookCount * 4)
            evidence += 12 + min(8, live.bookCount * 2)
            reasons.append(String(
                format: "Live no-vig consensus %.1f%% across %d book%@.",
                live.fairProbability,
                live.bookCount,
                live.bookCount == 1 ? "" : "s"
            ))
            reasons.append("Best observed price \(live.bestOdds) at \(live.bestBook).")
        } else if let fallbackFair {
            marketQuality = 8
            evidence += 4
            reasons.append(String(format: "Fallback single-feed de-vig estimate %.1f%%.", fallbackFair))
            risks.append("Multi-book consensus is unavailable for this exact line.")
        } else if let market {
            marketQuality = 4
            reasons.append(String(format: "Listed price implies %.1f%% before removing vig.", market))
            risks.append("No reliable no-vig market probability is available.")
        }

        var edge: Double?
        if let model, let fair {
            edge = model - fair
            if let edge {
                if edge >= 7 {
                    evidence += 20
                    reasons.append(String(format: "Model edge: +%.1f percentage points vs market.", edge))
                } else if edge >= 4 {
                    evidence += 14
                    reasons.append(String(format: "Model edge: +%.1f points.", edge))
                } else if edge >= 2 {
                    evidence += 7
                    reasons.append(String(format: "Modest model edge: +%.1f points.", edge))
                } else if edge < 0 {
                    evidence -= 14
                    risks.append(String(format: "Independent model is %.1f points below the market.", abs(edge)))
                }
            }
        }

        switch lineStatus {
        case .live:
            freshnessQuality = 10
            evidence += 10
            reasons.append("The exact line is current and live-verified.")
        case .mismatch:
            evidence -= 45
            risks.append("The scored line no longer matches the live market.")
        case .stale:
            freshnessQuality = 1
            evidence -= 35
            risks.append("The connected line is stale.")
        case .unverified:
            freshnessQuality = 3
            evidence -= 8
            risks.append("The exact line could not be live-verified.")
        case .notConnected:
            freshnessQuality = 1
            evidence -= 6
            risks.append("Live multi-book verification is not connected.")
        }

        if let context = eventContext {
            availabilityQuality = 12
            if let venue = context.venue {
                reasons.append("Venue: \(venue).")
            }
            if let weatherText = context.weather, (bet.sport ?? .all).isOutdoorWeatherRelevant {
                reasons.append("Weather context: \(weatherText).")
            }
            if let note = weather.note {
                evidence += Int(weather.points.rounded())
                reasons.append(note)
            }
        } else {
            availabilityQuality = 6
        }

        if let movement {
            historyQuality = 5
            evidence += max(-5, min(5, movement.supportPoints))
            reasons.append(movement.summary)
        } else {
            historyQuality = 1
            risks.append("No meaningful recorded line-movement history yet.")
        }

        if bet.source != .multiBook, let money = bet.moneyPercent {
            publicQuality = 4
            let splitEdge = money - bet.betsPercent
            if splitEdge >= 10 {
                evidence += 4
                reasons.append("\(money)% money vs \(bet.betsPercent)% bets adds minor confirmation.")
            } else if splitEdge <= -8 {
                evidence -= 3
                risks.append("Public money trails ticket share by \(abs(splitEdge)) points.")
            }
        } else {
            publicQuality = 1
        }

        if sources >= 2 {
            evidence += 3
            reasons.append("\(sources) public signal feeds agree on the selection.")
        }

        risks.append("Public betting popularity is supporting evidence only; it does not create the prediction.")
        evidence = clampInt(evidence)

        let components = ConfidenceBreakdown(
            stats: statsQuality,
            market: marketQuality,
            availability: availabilityQuality,
            freshness: freshnessQuality,
            history: historyQuality,
            publicSignal: publicQuality
        )
        let quality = min(100, components.total)
        let bestOdds = liveConsensus?.bestOdds ?? bet.odds
        let ev = OddsMath.expectedValuePercent(probability: model, odds: bestOdds)

        let verdict: PickVerdict
        if lineStatus == .mismatch || lineStatus == .stale {
            verdict = .pass
        } else if let model, let edge,
                  model >= 58,
                  edge >= 4,
                  evidence >= 76,
                  quality >= 70,
                  lineStatus == .live,
                  (liveConsensus?.bookCount ?? 0) >= 2 {
            verdict = .lock
        } else if let model, let edge,
                  model >= 55,
                  edge >= 2,
                  evidence >= 58,
                  quality >= 52,
                  lineStatus == .live {
            verdict = .strong
        } else if model != nil && evidence >= 42 {
            verdict = .consider
        } else {
            verdict = .pass
        }

        return DecisionReport(
            modelProbability: model,
            fairProbability: fair,
            marketProbability: market,
            estimatedEdge: edge,
            expectedValuePercent: ev,
            evidenceScore: evidence,
            dataQuality: quality,
            sourceCount: max(sources, liveConsensus?.bookCount ?? 0),
            liveStatus: lineStatus,
            verdict: verdict,
            components: components,
            reasons: reasons,
            risks: risks
        )
    }

    static func report(
        for prop: PropPick,
        projection: StatProjection?,
        verification: LivePropVerification?,
        contextText: String,
        availability: PlayerAvailabilitySnapshot?,
        liveConfigured: Bool
    ) -> DecisionReport {
        let model = projection?.modelProbability
        let fair = verification?.status == .live ? verification?.fairProbability : prop.impliedProbability
        let market = verification?.averageImpliedProbability ?? prop.impliedProbability
        let lineStatus: LiveLineStatus = {
            if !liveConfigured { return .notConnected }
            return verification?.status ?? .unverified
        }()
        let movement = MarketHistoryStore.movement(for: prop)
        let injuryFlags = ContextAnalyzer.flags(for: prop.playerName, in: contextText)

        var evidence = 0
        var reasons: [String] = []
        var risks: [String] = []
        var statsQuality = 0
        var marketQuality = 0
        var availabilityQuality = 0
        var freshnessQuality = 0
        var historyQuality = 0
        var publicQuality = 0

        if let projection {
            statsQuality = min(40, 22 + projection.sampleSize)
            evidence += 42
            evidence += max(-6, min(12, Int((projection.modelProbability - 50) / 2)))
            reasons.append(String(
                format: "%@ model: %.1f%% (%d games).",
                projection.metricName,
                projection.modelProbability,
                projection.sampleSize
            ))
            reasons.append(String(
                format: "Recent avg %.2f vs %.2f line; recent hit rate %.0f%% (%d games).",
                projection.recentAverage,
                projection.threshold,
                projection.recentHitRate,
                projection.recentSampleSize
            ))
            reasons.append(String(
                format: "Longer-sample avg %.2f; longer-sample hit rate %.0f%%.",
                projection.seasonAverage,
                projection.seasonHitRate
            ))
            if projection.calibratedSampleSize >= 20 {
                reasons.append("Probability is calibration-adjusted from \(projection.calibratedSampleSize) comparable settled picks.")
            } else {
                risks.append("Calibration history is still small, so the probability remains conservatively shrunk.")
            }
        } else {
            risks.append("No verified player game-log projection is available; this prop cannot become a LOCK.")
        }

        if let verification, verification.status == .live, let liveFair = verification.fairProbability {
            marketQuality = min(25, 10 + verification.bookCount * 4)
            evidence += 12 + min(8, verification.bookCount * 2)
            reasons.append(String(
                format: "Exact prop confirmed by %d book%@; no-vig fair probability %.1f%%.",
                verification.bookCount,
                verification.bookCount == 1 ? "" : "s",
                liveFair
            ))
            if let odds = verification.bestOdds {
                reasons.append("Best observed price \(odds)\(verification.bestBook.map { " at \($0)" } ?? "").")
            }
        } else if let verification {
            marketQuality = 4
            risks.append(verification.note)
        } else {
            marketQuality = liveConfigured ? 2 : 0
            risks.append(liveConfigured ? "Deep Check has not live-verified this exact prop yet." : "Live multi-book prop verification is not connected.")
        }

        var edge: Double?
        if let model, let fair {
            edge = model - fair
            if let edge {
                if edge >= 7 {
                    evidence += 20
                    reasons.append(String(format: "Independent model edge: +%.1f percentage points.", edge))
                } else if edge >= 4 {
                    evidence += 14
                    reasons.append(String(format: "Model edge: +%.1f points.", edge))
                } else if edge >= 2 {
                    evidence += 7
                    reasons.append(String(format: "Modest model edge: +%.1f points.", edge))
                } else if edge < 0 {
                    evidence -= 15
                    risks.append(String(format: "Model is %.1f points below market consensus.", abs(edge)))
                }
            }
        }

        var severeAvailability = false
        var cautionAvailability = false

        if let availability {
            switch availability.severity {
            case .clear:
                availabilityQuality = availability.starterConfirmed == true ? 15 : 12
                reasons.append(availability.note)
            case .caution:
                availabilityQuality = 6
                cautionAvailability = true
                evidence -= 18
                risks.append(availability.note)
            case .severe:
                availabilityQuality = 0
                severeAvailability = true
                evidence -= 50
                risks.append(availability.note)
            case .unknown:
                availabilityQuality = 4
                risks.append(availability.note)
            }
        } else if !contextText.isEmpty && injuryFlags.isEmpty {
            availabilityQuality = 7
            reasons.append("No injury warning was detected on the loaded public injury page.")
        } else {
            availabilityQuality = 2
            if !injuryFlags.isEmpty {
                cautionAvailability = true
                evidence -= 25
                risks.append(contentsOf: injuryFlags)
            } else {
                risks.append("Starter/active status has not been Deep Checked.")
            }
        }

        switch lineStatus {
        case .live:
            freshnessQuality = 10
            evidence += 9
        case .mismatch:
            evidence -= 45
            risks.append("Current live prop line does not match the listed line.")
        case .stale:
            freshnessQuality = 1
            evidence -= 35
            risks.append("Live prop line is stale.")
        case .unverified:
            freshnessQuality = 3
            evidence -= 8
        case .notConnected:
            freshnessQuality = 1
            evidence -= 5
        }

        if let movement {
            historyQuality = 5
            evidence += max(-5, min(5, movement.supportPoints))
            reasons.append(movement.summary)
        } else {
            historyQuality = 1
        }

        if let handle = prop.handlePercent, let tickets = prop.betPercent {
            publicQuality = 4
            let splitEdge = handle - tickets
            if splitEdge >= 10 {
                evidence += 4
                reasons.append(String(format: "%.0f%% handle vs %.0f%% tickets adds minor confirmation.", handle, tickets))
            } else if splitEdge <= -8 {
                evidence -= 3
            }
        } else {
            publicQuality = 1
        }

        risks.append("Recent hit rate is context, not the probability by itself; the model also uses the underlying game-log distribution.")
        risks.append("Late role, matchup or lineup changes can invalidate a prop projection.")

        evidence = clampInt(evidence)
        let components = ConfidenceBreakdown(
            stats: statsQuality,
            market: marketQuality,
            availability: availabilityQuality,
            freshness: freshnessQuality,
            history: historyQuality,
            publicSignal: publicQuality
        )
        let quality = min(100, components.total)
        let bestOdds = verification?.bestOdds ?? prop.odds
        let ev = OddsMath.expectedValuePercent(probability: model, odds: bestOdds)

        let verdict: PickVerdict
        if severeAvailability || lineStatus == .mismatch || lineStatus == .stale {
            verdict = .pass
        } else if let model, let edge,
                  model >= 60,
                  edge >= 5,
                  evidence >= 78,
                  quality >= 70,
                  lineStatus == .live,
                  (verification?.bookCount ?? 0) >= 2,
                  !cautionAvailability {
            verdict = .lock
        } else if let model, let edge,
                  model >= 56,
                  edge >= 2,
                  evidence >= 58,
                  quality >= 52,
                  lineStatus == .live,
                  !cautionAvailability {
            verdict = .strong
        } else if model != nil && evidence >= 42 {
            verdict = .consider
        } else {
            verdict = .pass
        }

        return DecisionReport(
            modelProbability: model,
            fairProbability: fair,
            marketProbability: market,
            estimatedEdge: edge,
            expectedValuePercent: ev,
            evidenceScore: evidence,
            dataQuality: quality,
            sourceCount: verification?.bookCount ?? 1,
            liveStatus: lineStatus,
            verdict: verdict,
            components: components,
            reasons: reasons,
            risks: risks
        )
    }

    private static func fairProbability(for bet: PopularBet, board: [PopularBet]) -> Double? {
        guard let target = bet.impliedProbability else { return nil }
        let group = board.filter {
            $0.source == bet.source &&
            MarketKey.sameEvent($0.matchup, bet.matchup) &&
            MarketKey.normalized($0.market) == MarketKey.normalized(bet.market)
        }
        let probabilities = group.compactMap(\.impliedProbability)
        guard probabilities.count >= 2, probabilities.count == group.count else { return nil }
        let total = probabilities.reduce(0, +)
        guard total > 0 else { return nil }
        return target / total * 100
    }

    private static func sourceCount(for bet: PopularBet, board: [PopularBet]) -> Int {
        let matches = board.filter {
            MarketKey.sameEvent($0.matchup, bet.matchup) &&
            MarketKey.sameSelection($0.side, bet.side)
        }
        return Set(matches.map(\.source)).count
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private static func clampInt(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}
