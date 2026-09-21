import Foundation

enum LocalModelOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case qwen35_9b
    case gemma4_e4b
    case qwen35_4b

    var id: String { rawValue }

    var name: String {
        switch self {
        case .qwen35_9b: "Qwen3.5 9B"
        case .gemma4_e4b: "Gemma 4 E4B"
        case .qwen35_4b: "Qwen3.5 4B"
        }
    }

    var tier: String {
        switch self {
        case .qwen35_9b: "MAX"
        case .gemma4_e4b: "STRONG"
        case .qwen35_4b: "FAST"
        }
    }

    var repositoryID: String {
        switch self {
        case .qwen35_9b:
            "mlx-community/Qwen3.5-9B-MLX-4bit"
        case .gemma4_e4b:
            "mlx-community/gemma-4-e4b-it-4bit"
        case .qwen35_4b:
            "mlx-community/Qwen3.5-4B-MLX-4bit"
        }
    }

    var approximateDownload: String {
        switch self {
        case .qwen35_9b: "~6.0 GB"
        case .gemma4_e4b: "~5.2 GB"
        case .qwen35_4b: "~3.1 GB"
        }
    }

    var detail: String {
        switch self {
        case .qwen35_9b:
            "Highest-quality local candidate. SENSEI prepares a language-only runtime from the downloaded checkpoint so its unused vision tower is not loaded into memory."
        case .gemma4_e4b:
            "Independent Gemma-family reviewer for SENSEI TEAM. Kept separate from the proven Qwen primary so collaboration adds model-family diversity."
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
