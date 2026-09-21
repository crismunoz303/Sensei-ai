import Foundation

enum LocalModelOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case qwen35_9b
    case qwen3_8b
    case qwen35_4b

    var id: String { rawValue }

    var name: String {
        switch self {
        case .qwen35_9b: "Qwen3.5 9B"
        case .qwen3_8b: "Qwen3 8B"
        case .qwen35_4b: "Qwen3.5 4B"
        }
    }

    var tier: String {
        switch self {
        case .qwen35_9b: "MAX"
        case .qwen3_8b: "STRONG"
        case .qwen35_4b: "FAST"
        }
    }

    var repositoryID: String {
        switch self {
        case .qwen35_9b:
            "mlx-community/Qwen3.5-9B-MLX-4bit"
        case .qwen3_8b:
            "mlx-community/Qwen3-8B-4bit"
        case .qwen35_4b:
            "mlx-community/Qwen3.5-4B-MLX-4bit"
        }
    }

    var approximateDownload: String {
        switch self {
        case .qwen35_9b: "~6.0 GB"
        case .qwen3_8b: "~4.6 GB"
        case .qwen35_4b: "~3.1 GB"
        }
    }

    var detail: String {
        switch self {
        case .qwen35_9b:
            "Highest-quality candidate, but its ~6 GB 4-bit weights exceed the safe local loading budget on 8 GB-class iPhones. SENSEI will preserve the download instead of attempting a load that can make iOS terminate the app."
        case .qwen3_8b:
            "Strong, mature text model and the strongest supported local option for 8 GB-class iPhones."
        case .qwen35_4b:
            "Newer architecture with a much smaller footprint. Best candidate when speed and thermals matter."
        }
    }
}

struct ModelBenchmarkSnapshot: Sendable {
    let model: LocalModelOption
    let loadSeconds: Double
    let responseSeconds: Double
    let reasoningPassed: Bool
    let response: String
}
