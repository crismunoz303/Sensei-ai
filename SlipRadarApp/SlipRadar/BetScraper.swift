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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
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
    static func parse(_ text: String) -> [PopularBet] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

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

            var startTime = ""
            var betSplit: (Int, Int)?
            var moneySplit: (Int, Int)?
            var cursor = index + 1
            let upperBound = min(lines.count, index + 8)

            while cursor < upperBound {
                let candidate = lines[cursor]
                let candidateNS = candidate as NSString
                let candidateRange = NSRange(location: 0, length: candidateNS.length)

                if startTime.isEmpty,
                   timeRegex.firstMatch(in: candidate, range: candidateRange) != nil {
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
                let chooseFirst = betSplit.0 >= betSplit.1
                let betPct = chooseFirst ? betSplit.0 : betSplit.1
                let moneyPct = moneySplit.map { chooseFirst ? $0.0 : $0.1 }
                let diff = moneyPct.map { $0 - betPct }

                bets.append(PopularBet(
                    matchup: "\(team1) vs \(team2)",
                    side: chooseFirst ? abbr1 : abbr2,
                    startTime: startTime.isEmpty ? "Today" : startTime,
                    betsPercent: betPct,
                    moneyPercent: moneyPct,
                    splitDifference: diff
                ))
            }

            index = max(index + 1, cursor - 1)
        }

        let unique = Dictionary(grouping: bets, by: { $0.matchup + $0.side })
            .compactMap { $0.value.first }

        return unique.sorted {
            if $0.betsPercent == $1.betsPercent {
                return $0.score > $1.score
            }
            return $0.betsPercent > $1.betsPercent
        }
    }
}
