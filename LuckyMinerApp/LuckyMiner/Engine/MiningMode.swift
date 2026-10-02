import Foundation

enum MiningMode: String, CaseIterable, Identifiable {
    case eco = "Eco"
    case balanced = "Balanced"
    case max = "Max"

    var id: String { rawValue }

    func requestedWorkers(coreCount: Int) -> Int {
        let cores = max(1, coreCount)

        switch self {
        case .eco:
            return 1
        case .balanced:
            return max(1, cores / 2)
        case .max:
            return max(1, cores - 1)
        }
    }
}
