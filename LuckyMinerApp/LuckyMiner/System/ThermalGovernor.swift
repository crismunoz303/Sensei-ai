import Foundation
import UIKit

@MainActor
final class ThermalGovernor: ObservableObject {
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var batteryLevel: Float = UIDevice.current.batteryLevel
    @Published private(set) var batteryState: UIDevice.BatteryState = UIDevice.current.batteryState
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let nc = NotificationCenter.default

        observers.append(
            nc.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        )

        observers.append(
            nc.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        )

        observers.append(
            nc.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        )

        observers.append(
            nc.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        )
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func refresh() {
        thermalState = ProcessInfo.processInfo.thermalState
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func allowedWorkers(requested: Int) -> Int {
        switch thermalState {
        case .nominal:
            return lowPowerMode ? min(requested, 1) : requested
        case .fair:
            return max(1, Int(Double(requested) * 0.65))
        case .serious:
            return 1
        case .critical:
            return 0
        @unknown default:
            return 1
        }
    }

    var statusText: String {
        switch thermalState {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Warm — throttling"
        case .serious:
            return "Hot — heavy throttle"
        case .critical:
            return "Critical — mining stopped"
        @unknown default:
            return "Unknown"
        }
    }
}
