import Foundation

struct MarketMovement {
    let summary: String
    let supportPoints: Int
}

struct MarketHistoryPoint: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let lineValue: Double?
    let probability: Double?
    let odds: String?
}

private struct MarketSnapshot: Codable {
    let key: String
    let timestamp: Date
    let lineValue: Double?
    let probability: Double?
    let odds: String?
}

enum MarketHistoryStore {
    private static let storageKey = "SlipRadar.marketSnapshots.v08"

    static func record(bets: [PopularBet]) {
        var snapshots = load()
        let now = Date()

        for bet in bets {
            append(
                MarketSnapshot(
                    key: MarketKey.betHistoryKey(bet),
                    timestamp: now,
                    lineValue: numericLine(from: bet.side),
                    probability: bet.impliedProbability,
                    odds: bet.odds
                ),
                to: &snapshots
            )
        }

        save(trim(snapshots))
    }

    static func record(props: [PropPick]) {
        var snapshots = load()
        let now = Date()

        for prop in props {
            append(
                MarketSnapshot(
                    key: MarketKey.propHistoryKey(prop),
                    timestamp: now,
                    lineValue: numericLine(from: prop.line),
                    probability: prop.impliedProbability,
                    odds: prop.odds
                ),
                to: &snapshots
            )
        }

        save(trim(snapshots))
    }

    static func movement(for bet: PopularBet) -> MarketMovement? {
        movement(key: MarketKey.betHistoryKey(bet))
    }

    static func movement(for prop: PropPick) -> MarketMovement? {
        movement(key: MarketKey.propHistoryKey(prop))
    }

    static func history(for bet: PopularBet, limit: Int = 6) -> [MarketHistoryPoint] {
        history(key: MarketKey.betHistoryKey(bet), limit: limit)
    }

    static func history(for prop: PropPick, limit: Int = 6) -> [MarketHistoryPoint] {
        history(key: MarketKey.propHistoryKey(prop), limit: limit)
    }

    private static func history(key: String, limit: Int) -> [MarketHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
        return load()
            .filter { $0.key == key && $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(max(1, limit))
            .enumerated()
            .map { index, snapshot in
                MarketHistoryPoint(
                    id: "\(snapshot.key)|\(snapshot.timestamp.timeIntervalSince1970)|\(index)",
                    timestamp: snapshot.timestamp,
                    lineValue: snapshot.lineValue,
                    probability: snapshot.probability,
                    odds: snapshot.odds
                )
            }
    }

    private static func movement(key: String) -> MarketMovement? {
        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
        let items = load()
            .filter { $0.key == key && $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }

        guard items.count >= 2, let first = items.first, let last = items.last else { return nil }

        var pieces: [String] = []
        var support = 0

        if let firstProb = first.probability, let lastProb = last.probability {
            let delta = lastProb - firstProb
            if abs(delta) >= 0.8 {
                pieces.append(String(format: "Market-implied probability moved %+.1f points since the first scan.", delta))
            }
            if delta >= 2.0 {
                support += 5
            } else if delta <= -2.0 {
                support -= 4
            }
        }

        if let firstLine = first.lineValue, let lastLine = last.lineValue, abs(lastLine - firstLine) >= 0.5 {
            pieces.append(String(format: "Line moved from %.1f to %.1f.", firstLine, lastLine))
        }

        guard !pieces.isEmpty else { return nil }
        return MarketMovement(summary: pieces.joined(separator: " "), supportPoints: support)
    }

    private static func append(_ snapshot: MarketSnapshot, to snapshots: inout [MarketSnapshot]) {
        if let last = snapshots.last(where: { $0.key == snapshot.key }) {
            let sameValues = last.lineValue == snapshot.lineValue &&
                last.probability == snapshot.probability &&
                last.odds == snapshot.odds
            if sameValues && snapshot.timestamp.timeIntervalSince(last.timestamp) < 300 {
                return
            }
        }
        snapshots.append(snapshot)
    }

    private static func numericLine(from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?"#) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: range)
        guard let match = matches.last else { return nil }
        return Double(ns.substring(with: match.range))
    }

    private static func load() -> [MarketSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MarketSnapshot].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func save(_ snapshots: [MarketSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func trim(_ snapshots: [MarketSnapshot]) -> [MarketSnapshot] {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        return Array(snapshots.filter { $0.timestamp >= cutoff }.suffix(1200))
    }
}
