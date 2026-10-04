import SwiftUI
import WebKit

struct WebTextLoader: UIViewRepresentable {
    let url: URL
    let refreshToken: UUID
    let onText: (String) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isHidden = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let key = url.absoluteString + refreshToken.uuidString
        guard context.coordinator.lastLoadKey != key else { return }
        context.coordinator.lastLoadKey = key
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadKey: String?
        private let onText: (String) -> Void
        private let onError: (Error) -> Void

        init(onText: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
            self.onText = onText
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, error in
                    if let error {
                        self.onError(error)
                        return
                    }
                    guard let text = result as? String, !text.isEmpty else {
                        self.onError(SlipRadarError.invalidPage)
                        return
                    }
                    self.onText(text)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError(error)
        }
    }
}

enum BetTextParser {
    static func parse(_ text: String, source: BetSource) -> [PopularBet] {
        switch source {
        case .action:
            return parseAction(text)
        case .draftKings:
            return parseDraftKings(text)
        }
    }

    private static func cleanLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func percent(_ value: String) -> Int? {
        let cleaned = value.replacingOccurrences(of: "%", with: "")
        return Int(cleaned)
    }

    private static func parseAction(_ text: String) -> [PopularBet] {
        let lines = cleanLines(text)

        let matchupRegex = try! NSRegularExpression(
            pattern: #"^(.+?)\s+([A-Z]{2,4})\s+\d+\s+(.+?)\s+([A-Z]{2,4})\s+\d+$"#
        )
        let percentRegex = try! NSRegularExpression(pattern: #"^(\d{1,3})%(\d{1,3})%$"#)
        let timeRegex = try! NSRegularExpression(pattern: #"^(\d{1,2}:\d{2}\s*(AM|PM)|Final|END.*|\d+(ST|ND|RD|TH).*)$"#, options: [.caseInsensitive])

        var bets: [PopularBet] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)

            guard let match = matchupRegex.firstMatch(in: line, range: range) else {
                index += 1
                continue
            }

            let team1 = ns.substring(with: match.range(at: 1))
            let abbr1 = ns.substring(with: match.range(at: 2))
            let team2 = ns.substring(with: match.range(at: 3))
            let abbr2 = ns.substring(with: match.range(at: 4))

            var startTime = "Today"
            var betSplit: (Int, Int)?
            var moneySplit: (Int, Int)?
            var cursor = index + 1
            let upperBound = min(lines.count, index + 10)

            while cursor < upperBound {
                let candidate = lines[cursor]
                let candidateNS = candidate as NSString
                let candidateRange = NSRange(location: 0, length: candidateNS.length)

                if timeRegex.firstMatch(in: candidate, range: candidateRange) != nil {
                    startTime = candidate
                } else if let p = percentRegex.firstMatch(in: candidate, range: candidateRange) {
                    let first = Int(candidateNS.substring(with: p.range(at: 1))) ?? 0
                    let second = Int(candidateNS.substring(with: p.range(at: 2))) ?? 0
                    if betSplit == nil {
                        betSplit = (first, second)
                    } else if moneySplit == nil {
                        moneySplit = (first, second)
                    }
                }
                cursor += 1
            }

            if let betSplit {
                for firstSide in [true, false] {
                    let betPct = firstSide ? betSplit.0 : betSplit.1
                    let moneyPct = moneySplit.map { firstSide ? $0.0 : $0.1 }
                    let diff = moneyPct.map { $0 - betPct }

                    bets.append(PopularBet(
                        source: .action,
                        matchup: "\(team1) vs \(team2)",
                        side: firstSide ? abbr1 : abbr2,
                        market: "Side",
                        startTime: startTime,
                        betsPercent: betPct,
                        moneyPercent: moneyPct,
                        splitDifference: diff
                    ))
                }
            }

            index += 1
        }

        return dedupe(bets)
    }

    private static func parseDraftKings(_ text: String) -> [PopularBet] {
        let lines = cleanLines(text)
        var results: [PopularBet] = []
        var index = 0

        while index < lines.count {
            let matchup = lines[index]
            guard matchup.contains(" @ ") || matchup.contains(" vs ") else {
                index += 1
                continue
            }

            var end = index + 1
            while end < lines.count {
                let line = lines[end]
                if end > index + 1 && (line.contains(" @ ") || line.contains(" vs ")) {
                    break
                }
                end += 1
            }

            let segment = Array(lines[index..<end])
            let startTime = segment.dropFirst().first(where: { $0.contains("/") && ($0.uppercased().contains("AM") || $0.uppercased().contains("PM")) }) ?? "Today"

            for marketName in ["Moneyline", "Spread", "Run Line", "Total"] {
                guard let marketIndex = segment.firstIndex(of: marketName) else { continue }
                let normalizedMarket = marketName == "Run Line" ? "Spread" : marketName
                let marketEnd = segment[(marketIndex + 1)...].firstIndex(where: { ["Moneyline", "Spread", "Run Line", "Total"].contains($0) }) ?? segment.endIndex
                let marketLines = Array(segment[(marketIndex + 1)..<marketEnd])
                results.append(contentsOf: parseDraftKingsMarket(
                    marketLines,
                    matchup: matchup,
                    startTime: startTime,
                    market: normalizedMarket
                ))
            }

            index = end
        }

        return dedupe(results)
    }

    private static func parseDraftKingsMarket(
        _ lines: [String],
        matchup: String,
        startTime: String,
        market: String
    ) -> [PopularBet] {
        var results: [PopularBet] = []
        var i = 0
        let ignored = Set(["Odds", "% Handle", "% Bets"])

        while i + 3 < lines.count {
            let option = lines[i]
            if ignored.contains(option) {
                i += 1
                continue
            }

            let money = percent(lines[i + 2])
            let bets = percent(lines[i + 3])

            if let money, let bets, (0...100).contains(money), (0...100).contains(bets) {
                results.append(PopularBet(
                    source: .draftKings,
                    matchup: matchup,
                    side: option,
                    market: market,
                    startTime: startTime,
                    betsPercent: bets,
                    moneyPercent: money,
                    splitDifference: money - bets
                ))
                i += 4
            } else {
                i += 1
            }
        }

        return results
    }

    private static func dedupe(_ bets: [PopularBet]) -> [PopularBet] {
        let grouped = Dictionary(grouping: bets) { bet in
            "\(bet.source.rawValue)|\(bet.matchup)|\(bet.market)|\(bet.side)"
        }
        return grouped.values.compactMap { $0.first }
    }
}
