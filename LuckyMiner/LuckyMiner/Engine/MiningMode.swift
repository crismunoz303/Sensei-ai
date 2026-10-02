import Foundation

enum MiningMode: String, CaseIterable, Identifiable {
    case eco = "Eco"
    case balanced = "Balanced"
    case max = "Max"

    var id: String { rawValue }

    var workerCount: Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        switch self {
        case .eco: return 1
        case .balanced: return max(1, min(2, cores / 2))
        case .max: return max(1, cores - 1)
        }
    }

    var dutyCycle: Double {
        switch self {
        case .eco: return 0.35
        case .balanced: return 0.65
        case .max: return 1.0
        }
    }
}
