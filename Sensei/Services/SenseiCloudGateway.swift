import Foundation

struct CloudChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct CloudChatRequest: Codable, Sendable {
    let model: String
    let messages: [CloudChatMessage]
    let stream: Bool
}

private struct CloudChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

struct SenseiCloudConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String

    static func load() throws -> Self {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "sensei.cloud.baseURL"),
              let baseURL = URL(string: raw),
              !raw.isEmpty else { throw SenseiCloudError.notConfigured }
        guard let apiKey = defaults.string(forKey: "sensei.cloud.apiKey"),
              !apiKey.isEmpty else { throw SenseiCloudError.notConfigured }
        let model = defaults.string(forKey: "sensei.cloud.model")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(baseURL: baseURL, apiKey: apiKey, model: (model?.isEmpty == false ? model! : "auto:smart"))
    }
}

actor SenseiCloudGateway {
    static let shared = SenseiCloudGateway()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }

    func reply(system: String, history: [CloudChatMessage], prompt: String) async throws -> String {
        let config = try SenseiCloudConfiguration.load()
        let endpoint = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(CloudChatRequest(
            model: config.model,
            messages: [CloudChatMessage(role: "system", content: system)] + history + [CloudChatMessage(role: "user", content: prompt)],
            stream: false
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SenseiCloudError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SenseiCloudError.http(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(CloudChatResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw SenseiCloudError.emptyResponse }
        return text
    }
}

enum SenseiCloudError: LocalizedError {
    case notConfigured
    case invalidResponse
    case emptyResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloud AI is not configured yet. Add the FreeLLMAPI /v1 base URL and unified key in SENSEI."
        case .invalidResponse: return "SENSEI received an invalid cloud response."
        case .emptyResponse: return "The cloud model returned an empty answer."
        case let .http(code, body):
            return "Cloud request failed (HTTP \(code)). \(body.prefix(240))"
        }
    }
}
