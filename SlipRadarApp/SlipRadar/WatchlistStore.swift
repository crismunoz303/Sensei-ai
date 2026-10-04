import Foundation
import UserNotifications

enum WatchlistStore {
    private static let storageKey = "SlipRadar.watchlist.v10"

    static func load() -> [WatchItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WatchItem].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    static func contains(id: String) -> Bool {
        load().contains { $0.id == id }
    }

    static func toggle(_ item: WatchItem) {
        var items = load()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
        } else {
            items.append(item)
        }
        save(items)
    }

    static func remove(id: String) {
        var items = load()
        items.removeAll { $0.id == id }
        save(items)
    }

    static func update(
        bet: PopularBet,
        sport: SportFilter,
        report: DecisionReport,
        bestBook: String?
    ) -> [WatchAlert] {
        update(
            id: watchID(sport: sport, event: bet.matchup, market: bet.market, selection: bet.side),
            verdict: report.verdict,
            odds: bet.odds,
            book: bestBook,
            model: report.modelProbability,
            fair: report.fairProbability,
            lineStatus: report.liveStatus
        )
    }

    static func update(
        prop: PropPick,
        sport: SportFilter,
        report: DecisionReport,
        bestOdds: String?,
        bestBook: String?
    ) -> [WatchAlert] {
        update(
            id: watchID(sport: sport, event: prop.event, market: prop.market, selection: prop.line),
            verdict: report.verdict,
            odds: bestOdds ?? prop.odds,
            book: bestBook,
            model: report.modelProbability,
            fair: report.fairProbability,
            lineStatus: report.liveStatus
        )
    }

    static func watchID(sport: SportFilter, event: String, market: String, selection: String) -> String {
        [
            sport.rawValue,
            MarketKey.normalized(event),
            MarketKey.normalized(market),
            MarketKey.normalized(selection)
        ].joined(separator: "|")
    }

    private static func update(
        id: String,
        verdict: PickVerdict,
        odds: String?,
        book: String?,
        model: Double?,
        fair: Double?,
        lineStatus: LiveLineStatus
    ) -> [WatchAlert] {
        var items = load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }

        let previous = items[index]
        var alerts: [WatchAlert] = []

        if let priorVerdict = previous.lastVerdict,
           verdict.rank > priorVerdict.rank,
           verdict == .lock || verdict == .strong {
            alerts.append(WatchAlert(
                title: "SlipRadar upgrade: \(verdict.rawValue)",
                body: "\(previous.selection) improved from \(priorVerdict.rawValue) to \(verdict.rawValue)."
            ))
        }

        if previous.lastLineStatus == .live &&
            (lineStatus == .mismatch || lineStatus == .stale) {
            alerts.append(WatchAlert(
                title: "Watched line changed",
                body: "\(previous.selection) is now \(lineStatus.rawValue). Re-check before using it."
            ))
        }

        if let oldOdds = previous.lastOdds,
           let newOdds = odds,
           oldOdds != newOdds,
           let old = OddsMath.americanValue(from: oldOdds),
           let new = OddsMath.americanValue(from: newOdds),
           new > old + 10 {
            alerts.append(WatchAlert(
                title: "Better price detected",
                body: "\(previous.selection) improved from \(oldOdds) to \(newOdds)\(book.map { " at \($0)" } ?? "")."
            ))
        }

        items[index].lastVerdict = verdict
        items[index].lastOdds = odds
        items[index].lastBook = book
        items[index].lastModelProbability = model
        items[index].lastFairProbability = fair
        items[index].lastLineStatus = lineStatus
        items[index].lastUpdated = Date()
        save(items)

        return alerts
    }

    private static func save(_ items: [WatchItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum SlipRadarNotifications {
    private static let enabledKey = "SlipRadar.alertsEnabled.v10"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    static func deliver(_ alerts: [WatchAlert]) {
        guard enabled else { return }

        for alert in alerts.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}
