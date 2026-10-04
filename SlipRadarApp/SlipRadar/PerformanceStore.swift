import Foundation

enum PickOutcome: String, Codable, CaseIterable {
    case pending = "Pending"
    case win = "Win"
    case loss = "Loss"
    case push = "Push"
}

struct TrackedPick: Identifiable, Codable {
    let id: String
    let addedAt: Date
    let title: String
    let event: String
    let market: String
    let source: String
    let odds: String?
    let estimatedProbability: Double?
    let evidenceScore: Int
    let verdict: String
    var outcome: PickOutcome
}

struct PerformanceSummary {
    let totalTracked: Int
    let settled: Int
    let wins: Int
    let losses: Int
    let pushes: Int
    let winRate: Double?
    let flatStakeROI: Double?
}

enum PerformanceStore {
    private static let storageKey = "SlipRadar.performance.v08"

    static func track(_ leg: SlipLeg) {
        var picks = load()
        guard !picks.contains(where: { $0.id == leg.id }) else { return }

        picks.append(TrackedPick(
            id: leg.id,
            addedAt: Date(),
            title: leg.title,
            event: leg.event,
            market: leg.market,
            source: leg.source,
            odds: leg.odds,
            estimatedProbability: leg.probability,
            evidenceScore: leg.evidenceScore,
            verdict: leg.signal,
            outcome: .pending
        ))
        save(picks)
    }

    static func setOutcome(id: String, outcome: PickOutcome) {
        var picks = load()
        guard let index = picks.firstIndex(where: { $0.id == id }) else { return }
        picks[index].outcome = outcome
        save(picks)
    }

    static func load() -> [TrackedPick] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TrackedPick].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.addedAt > $1.addedAt }
    }

    static func summary() -> PerformanceSummary {
        let picks = load()
        let settledPicks = picks.filter { $0.outcome != .pending }
        let wins = settledPicks.filter { $0.outcome == .win }.count
        let losses = settledPicks.filter { $0.outcome == .loss }.count
        let pushes = settledPicks.filter { $0.outcome == .push }.count
        let decisions = wins + losses
        let winRate = decisions > 0 ? Double(wins) / Double(decisions) * 100.0 : nil

        var profit = 0.0
        var gradedWithOdds = 0

        for pick in settledPicks {
            guard pick.outcome != .push,
                  let odds = pick.odds,
                  let decimal = OddsMath.decimalOdds(from: odds) else { continue }

            gradedWithOdds += 1
            if pick.outcome == .win {
                profit += decimal - 1.0
            } else if pick.outcome == .loss {
                profit -= 1.0
            }
        }

        let roi = gradedWithOdds > 0 ? profit / Double(gradedWithOdds) * 100.0 : nil

        return PerformanceSummary(
            totalTracked: picks.count,
            settled: settledPicks.count,
            wins: wins,
            losses: losses,
            pushes: pushes,
            winRate: winRate,
            flatStakeROI: roi
        )
    }

    private static func save(_ picks: [TrackedPick]) {
        guard let data = try? JSONEncoder().encode(picks) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
