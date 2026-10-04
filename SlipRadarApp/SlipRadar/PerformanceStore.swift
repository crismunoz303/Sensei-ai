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

struct CalibrationResult {
    let probability: Double
    let sampleSize: Int
    let observedWinRate: Double
}

enum SlipStore {
    private static let storageKey = "SlipRadar.savedSlip.v09"

    static func load() -> [SlipLeg] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SlipLeg].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ legs: [SlipLeg]) {
        guard let data = try? JSONEncoder().encode(legs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum PerformanceStore {
    private static let storageKey = "SlipRadar.performance.v09"
    private static let legacyStorageKey = "SlipRadar.performance.v08"

    static func track(_ leg: SlipLeg) {
        var picks = load()
        guard !picks.contains(where: { $0.id == leg.id }) else { return }

        picks.append(TrackedPick(
            id: leg.id,
            addedAt: leg.addedAt,
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
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TrackedPick].self, from: data) {
            return decoded.sorted { $0.addedAt > $1.addedAt }
        }

        if let legacy = UserDefaults.standard.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode([TrackedPick].self, from: legacy) {
            save(decoded)
            return decoded.sorted { $0.addedAt > $1.addedAt }
        }

        return []
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
                  let decimal = OddsMath.decimalOdds(from: odds) else {
                continue
            }

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

    static func calibrate(rawProbability: Double) -> CalibrationResult? {
        let settled = load().filter {
            ($0.outcome == .win || $0.outcome == .loss) &&
            $0.estimatedProbability != nil
        }

        let bucket = settled.filter { pick in
            guard let probability = pick.estimatedProbability else { return false }
            return abs(probability - rawProbability) <= 7.5
        }

        guard bucket.count >= 10 else { return nil }

        let wins = bucket.filter { $0.outcome == .win }.count
        let observed = Double(wins) / Double(bucket.count) * 100.0

        let dataWeight = min(0.55, Double(bucket.count) / 100.0)
        let calibrated = rawProbability * (1.0 - dataWeight) + observed * dataWeight

        return CalibrationResult(
            probability: min(99, max(1, calibrated)),
            sampleSize: bucket.count,
            observedWinRate: observed
        )
    }

    static func breakdownByVerdict() -> [(label: String, count: Int, wins: Int, losses: Int, winRate: Double?)] {
        let settled = load().filter { $0.outcome == .win || $0.outcome == .loss }
        return PickVerdict.allCases.map { verdict in
            let group = settled.filter { $0.verdict == verdict.rawValue }
            let wins = group.filter { $0.outcome == .win }.count
            let losses = group.filter { $0.outcome == .loss }.count
            let rate = group.isEmpty ? nil : Double(wins) / Double(group.count) * 100.0
            return (verdict.rawValue, group.count, wins, losses, rate)
        }
    }

    private static func save(_ picks: [TrackedPick]) {
        guard let data = try? JSONEncoder().encode(picks) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
