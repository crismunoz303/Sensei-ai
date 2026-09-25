import Foundation

struct WebSearchResult: Identifiable, Sendable {
    let id: Int
    let title: String
    let url: URL
    let snippet: String
}

enum WebResearchError: LocalizedError {
    case invalidQuery
    case badResponse
    case noResults

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "SENSEI could not build a valid web search."
        case .badResponse: return "The web search service returned an invalid response."
        case .noResults: return "No usable web results were found."
        }
    }
}

actor WebResearchService {
    static let shared = WebResearchService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1"
        ]
        return URLSession(configuration: config)
    }()

    func search(_ query: String, limit: Int = 5) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        else { throw WebResearchError.invalidQuery }

        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { throw WebResearchError.invalidQuery }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { throw WebResearchError.badResponse }

        let results = parseDuckDuckGoHTML(html, limit: max(1, min(limit, 8)))
        guard !results.isEmpty else { throw WebResearchError.noResults }
        return results
    }

    func contextBlock(for results: [WebSearchResult]) -> String {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let entries = results.map { result in
            """
            [\(result.id)] \(result.title)
            URL: \(result.url.absoluteString)
            Snippet: \(result.snippet)
            """
        }.joined(separator: "\n\n")

        return """
        WEB RESEARCH
        Search time: \(now)
        Treat these as external web search results, not guaranteed truth. Prefer agreement across sources, distinguish uncertainty, and cite claims using [1], [2], etc. Never claim you visited a source beyond the text supplied here.

        \(entries)
        """
    }

    private func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [WebSearchResult] {
        let pattern = #"<a[^>]*class=["'][^"']*result__a[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var output: [WebSearchResult] = []
        var seen = Set<String>()

        for match in matches {
            guard output.count < limit,
                  match.numberOfRanges >= 3
            else { break }

            let rawHref = ns.substring(with: match.range(at: 1))
            let rawTitle = ns.substring(with: match.range(at: 2))
            guard let resolved = resolveDuckDuckGoURL(rawHref),
                  ["http", "https"].contains(resolved.scheme?.lowercased() ?? ""),
                  !seen.contains(resolved.absoluteString)
            else { continue }

            seen.insert(resolved.absoluteString)
            let title = cleanHTML(rawTitle)
            let snippet = findSnippet(near: match.range.location, html: html)
            guard !title.isEmpty else { continue }

            output.append(
                WebSearchResult(
                    id: output.count + 1,
                    title: title,
                    url: resolved,
                    snippet: snippet.isEmpty ? "No search snippet available." : snippet
                )
            )
        }
        return output
    }

    private func findSnippet(near location: Int, html: String) -> String {
        let ns = html as NSString
        let start = min(max(location, 0), ns.length)
        let length = min(5000, ns.length - start)
        guard length > 0 else { return "" }
        let window = ns.substring(with: NSRange(location: start, length: length))
        let pattern = #"<a[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</a>|<div[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</div>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: window, range: NSRange(window.startIndex..., in: window))
        else { return "" }

        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            let captured = (window as NSString).substring(with: match.range(at: index))
            return String(cleanHTML(captured).prefix(700))
        }
        return ""
    }

    private func resolveDuckDuckGoURL(_ raw: String) -> URL? {
        let decoded = decodeHTMLEntities(raw)
        guard let url = URL(string: decoded) else { return nil }
        if let host = url.host?.lowercased(),
           host.contains("duckduckgo.com"),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let targetURL = URL(string: target) {
            return targetURL
        }
        return url
    }

    private func cleanHTML(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeHTMLEntities(withoutTags)
            .replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
