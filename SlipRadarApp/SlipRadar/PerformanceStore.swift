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

    let sport: String?
    let marketProbability: Double?
    let estimatedEdge: Double?
    let playerName: String?
    let threshold: Double?
    let direction: String?
    let modelVersion: String?
    let trackingOrigin: String?
    let entryBook: String?

    var lastSeenOdds: String?
    var lastSeenBook: String?
    var lastSeenFairProbability: Double?
    var lastSeenAt: Date?
    var outcomeSource: String?
}

struct PerformanceSummary {
    let totalTracked: Int
    let settled: Int
    let wins: Int
    let losses: Int
    let pushes: Int
    let winRate: Double?
    let flatStakeROI: Double?
    let averageCLV: Double?
}

struct CalibrationResult {
    let probability: Double
    let sampleSize: Int
    let observedWinRate: Double
}

enum SlipStore {
    private static let storageKey = "SlipRadar.savedSlip.v10"
    private static let legacyKey = "SlipRadar.savedSlip.v09"

    static func load() -> [SlipLeg] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SlipLeg].self, from: data) {
            return decoded
        }
        // Old slip schema is intentionally not force-migrated because v1.0 adds
        // model/version/market fields required for accurate tracking.
        return []
    }

    static func save(_ legs: [SlipLeg]) {
        guard let data = try? JSONEncoder().encode(legs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum PerformanceStore {
    private static let storageKey = "SlipRadar.performance.v10"
    private static let legacyKeys = ["SlipRadar.performance.v09", "SlipRadar.performance.v08"]
    private static var memoryCache: [TrackedPick]?

    static func track(_ leg: SlipLeg, origin: String = "SLIP") {
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
            outcome: .pending,
            sport: leg.sport,
            marketProbability: leg.marketProbability,
            estimatedEdge: leg.marketProbability.flatMap { fair in
                leg.probability.map { $0 - fair }
            },
            playerName: leg.playerName,
            threshold: leg.threshold,
            direction: leg.direction,
            modelVersion: leg.modelVersion,
            trackingOrigin: origin,
            entryBook: leg.bestBook,
            lastSeenOdds: nil,
            lastSeenBook: nil,
            lastSeenFairProbability: nil,
            lastSeenAt: nil,
            outcomeSource: nil
        ))
        save(picks)
    }

    static func trackRecommendation(
        sport: SportFilter,
        title: String,
        event: String,
        market: String,
        source: String,
        odds: String?,
        bestBook: String?,
        modelProbability: Double?,
        marketProbability: Double?,
        edge: Double?,
        evidenceScore: Int,
        verdict: PickVerdict,
        playerName: String?,
        threshold: Double?,
        direction: String?
    ) {
        guard verdict == .lock || verdict == .strong else { return }

        let day = dayKey(Date())
        let id = [
            "AUTO",
            ModelVersion.current,
            sport.rawValue,
            MarketKey.normalized(event),
            MarketKey.normalized(market),
            MarketKey.normalized(title),
            day
        ].joined(separator: "|")

        var picks = load()
        guard !picks.contains(where: { $0.id == id }) else { return }

        picks.append(TrackedPick(
            id: id,
            addedAt: Date(),
            title: title,
            event: event,
            market: market,
            source: source,
            odds: odds,
            estimatedProbability: modelProbability,
            evidenceScore: evidenceScore,
            verdict: verdict.rawValue,
            outcome: .pending,
            sport: sport.rawValue,
            marketProbability: marketProbability,
            estimatedEdge: edge,
            playerName: playerName,
            threshold: threshold,
            direction: direction,
            modelVersion: ModelVersion.current,
            trackingOrigin: "MODEL",
            entryBook: bestBook,
            lastSeenOdds: nil,
            lastSeenBook: nil,
            lastSeenFairProbability: nil,
            lastSeenAt: nil,
            outcomeSource: nil
        ))
        save(picks)
    }

    static func setOutcome(id: String, outcome: PickOutcome, source: String = "Manual") {
        var picks = load()
        guard let index = picks.firstIndex(where: { $0.id == id }) else { return }
        picks[index].outcome = outcome
        picks[index].outcomeSource = source
        save(picks)
    }

    static func updateLatestMarket(
        id: String,
        odds: String?,
        book: String? = nil,
        fairProbability: Double?,
        observedAt: Date = Date()
    ) {
        var picks = load()
        guard let index = picks.firstIndex(where: { $0.id == id }) else { return }
        picks[index].lastSeenOdds = odds
        picks[index].lastSeenBook = book
        picks[index].lastSeenFairProbability = fairProbability
        picks[index].lastSeenAt = observedAt
        save(picks)
    }

    static func updateLatestMatching(
        sport: SportFilter,
        event: String,
        market: String,
        title: String,
        odds: String?,
        book: String?,
        fairProbability: Double?,
        observedAt: Date = Date()
    ) {
        var picks = load()
        let eventKey = MarketKey.normalized(event)
        let marketKey = MarketKey.normalized(market)
        let titleKey = MarketKey.selectionBase(title)

        var changed = false
        for index in picks.indices {
            guard picks[index].sport == sport.rawValue,
                  MarketKey.sameEvent(picks[index].event, event),
                  MarketKey.normalized(picks[index].market) == marketKey,
                  MarketKey.selectionBase(picks[index].title) == titleKey else {
                continue
            }

            picks[index].lastSeenOdds = odds
            picks[index].lastSeenBook = book
            picks[index].lastSeenFairProbability = fairProbability
            picks[index].lastSeenAt = observedAt
            changed = true
        }

        if changed { save(picks) }
        _ = eventKey
    }

    static func load() -> [TrackedPick] {
        if let cached = memoryCache {
            return cached
        }

        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TrackedPick].self, from: data) {
            let sorted = decoded.sorted { $0.addedAt > $1.addedAt }
            memoryCache = sorted
            return sorted
        }

        for key in legacyKeys {
            if let data = UserDefaults.standard.data(forKey: key),
               let decoded = try? JSONDecoder().decode([TrackedPick].self, from: data) {
                let sorted = decoded.sorted { $0.addedAt > $1.addedAt }
                save(sorted)
                return sorted
            }
        }

        memoryCache = []
        return []
    }

    static func summary() -> PerformanceSummary {
        let picks = load()
        let settled = picks.filter { $0.outcome != .pending }
        let wins = settled.filter { $0.outcome == .win }.count
        let losses = settled.filter { $0.outcome == .loss }.count
        let pushes = settled.filter { $0.outcome == .push }.count
        let decisions = wins + losses

        let winRate = decisions > 0 ? Double(wins) / Double(decisions) * 100 : nil
        let roi = roiFor(settled)

        let clv = settled.compactMap { pick -> Double? in
            guard let entry = pick.marketProbability,
                  let closing = pick.lastSeenFairProbability else { return nil }
            return closing - entry
        }
        let averageCLV = clv.isEmpty ? nil : clv.reduce(0, +) / Double(clv.count)

        return PerformanceSummary(
            totalTracked: picks.count,
            settled: settled.count,
            wins: wins,
            losses: losses,
            pushes: pushes,
            winRate: winRate,
            flatStakeROI: roi,
            averageCLV: averageCLV
        )
    }

    static func calibrate(
        rawProbability: Double,
        sport: String? = nil,
        market: String? = nil
    ) -> CalibrationResult? {
        let settled = load().filter {
            ($0.outcome == .win || $0.outcome == .loss) &&
            $0.estimatedProbability != nil &&
            ($0.modelVersion == ModelVersion.current || $0.modelVersion == nil)
        }

        let probabilityBucket: (TrackedPick) -> Bool = { pick in
            guard let probability = pick.estimatedProbability else { return false }
            return abs(probability - rawProbability) <= 7.5
        }

        let marketKey = market.map(MarketKey.normalized)
        let scoped = settled.filter { pick in
            guard probabilityBucket(pick) else { return false }

            let sportMatches = sport == nil || pick.sport == sport
            let marketMatches: Bool = {
                guard let marketKey else { return true }
                let pickKey = MarketKey.normalized(pick.market)
                return pickKey == marketKey || pickKey.contains(marketKey) || marketKey.contains(pickKey)
            }()

            return sportMatches && marketMatches
        }

        let sportOnly = settled.filter { pick in
            probabilityBucket(pick) && (sport == nil || pick.sport == sport)
        }
        let global = settled.filter(probabilityBucket)

        let bucket: [TrackedPick]
        if scoped.count >= 20 {
            bucket = scoped
        } else if sportOnly.count >= 30 {
            bucket = sportOnly
        } else {
            bucket = global
        }

        guard bucket.count >= 20 else { return nil }

        let wins = bucket.filter { $0.outcome == .win }.count
        let observed = Double(wins) / Double(bucket.count) * 100
        let weight = min(0.45, Double(bucket.count) / 150.0)
        let calibrated = rawProbability * (1 - weight) + observed * weight

        return CalibrationResult(
            probability: min(98, max(2, calibrated)),
            sampleSize: bucket.count,
            observedWinRate: observed
        )
    }

    static func calibrationBuckets() -> [CalibrationBucket] {
        let settled = load().filter {
            ($0.outcome == .win || $0.outcome == .loss) &&
            $0.estimatedProbability != nil
        }
        let ranges: [(Double, Double)] = [(50,55),(55,60),(60,65),(65,70),(70,75),(75,100)]

        return ranges.compactMap { lower, upper in
            let group = settled.filter {
                guard let p = $0.estimatedProbability else { return false }
                return p >= lower && p < upper
            }
            guard !group.isEmpty else { return nil }
            let predicted = group.compactMap(\.estimatedProbability).reduce(0,+) / Double(group.count)
            let observed = Double(group.filter { $0.outcome == .win }.count) / Double(group.count) * 100
            return CalibrationBucket(
                id: "\(Int(lower))-\(Int(upper))",
                label: "\(Int(lower))–\(Int(upper))%",
                count: group.count,
                averagePredicted: predicted,
                observedWinRate: observed
            )
        }
    }

    static func breakdownByVerdict() -> [(label: String, count: Int, wins: Int, losses: Int, winRate: Double?)] {
        breakdown(key: { $0.verdict }, labels: PickVerdict.allCases.map(\.rawValue))
    }

    static func breakdownBySport() -> [(label: String, count: Int, wins: Int, losses: Int, winRate: Double?)] {
        let settled = settledDecisions()
        let groups = Dictionary(grouping: settled) { $0.sport ?? "Unknown" }
        return groups.keys.sorted().map { label in row(label, groups[label] ?? []) }
    }

    static func breakdownByMarket() -> [(label: String, count: Int, wins: Int, losses: Int, winRate: Double?)] {
        let settled = settledDecisions()
        let groups = Dictionary(grouping: settled) { MarketKey.normalized($0.market) }
        return groups.keys.sorted().map { key in
            row(key.capitalized, groups[key] ?? [])
        }
    }

    static func backtestSummaries() -> [BacktestSummary] {
        let auto = settledDecisions().filter { $0.trackingOrigin == "MODEL" }

        let presets: [(String, (TrackedPick) -> Bool)] = [
            ("All auto-tracked", { _ in true }),
            ("STRONG+", { ($0.verdict == PickVerdict.strong.rawValue || $0.verdict == PickVerdict.lock.rawValue) }),
            ("LOCK only", { $0.verdict == PickVerdict.lock.rawValue }),
            ("Edge ≥ 3 pts", { ($0.estimatedEdge ?? -999) >= 3 })
        ]

        return presets.map { label, predicate in
            let group = auto.filter(predicate)
            let wins = group.filter { $0.outcome == .win }.count
            let losses = group.filter { $0.outcome == .loss }.count
            let decisions = wins + losses
            return BacktestSummary(
                label: label,
                sampleSize: group.count,
                wins: wins,
                losses: losses,
                winRate: decisions > 0 ? Double(wins) / Double(decisions) * 100 : nil,
                roi: roiFor(group)
            )
        }
    }

    private static func breakdown(
        key: (TrackedPick) -> String,
        labels: [String]
    ) -> [(label: String, count: Int, wins: Int, losses: Int, winRate: Double?)] {
        let settled = settledDecisions()
        return labels.map { label in row(label, settled.filter { key($0) == label }) }
    }

    private static func row(
        _ label: String,
        _ group: [TrackedPick]
    ) -> (label: String, count: Int, wins: Int, losses: Int, winRate: Double?) {
        let wins = group.filter { $0.outcome == .win }.count
        let losses = group.filter { $0.outcome == .loss }.count
        let decisions = wins + losses
        return (label, group.count, wins, losses, decisions > 0 ? Double(wins) / Double(decisions) * 100 : nil)
    }

    private static func settledDecisions() -> [TrackedPick] {
        load().filter { $0.outcome == .win || $0.outcome == .loss }
    }

    private static func roiFor(_ picks: [TrackedPick]) -> Double? {
        var profit = 0.0
        var graded = 0
        for pick in picks {
            guard pick.outcome == .win || pick.outcome == .loss,
                  let odds = pick.odds,
                  let decimal = OddsMath.decimalOdds(from: odds) else { continue }
            graded += 1
            profit += pick.outcome == .win ? decimal - 1 : -1
        }
        return graded > 0 ? profit / Double(graded) * 100 : nil
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func save(_ picks: [TrackedPick]) {
        let sorted = picks.sorted { $0.addedAt > $1.addedAt }
        memoryCache = sorted
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
