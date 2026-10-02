import SwiftUI

struct ContentView: View {
    @StateObject private var governor = ThermalGovernor()
    @StateObject private var miner = MiningEngine()
    @StateObject private var stratum = StratumClient()

    @AppStorage("miningMode") private var modeRaw = MiningMode.balanced.rawValue
    @AppStorage("poolHost") private var poolHost = ""
    @AppStorage("poolPort") private var poolPort = 3333
    @AppStorage("poolUser") private var poolUser = ""
    @AppStorage("poolPassword") private var poolPassword = "x"

    private var mode: MiningMode {
        MiningMode(rawValue: modeRaw) ?? .balanced
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    stats
                    thermalCard
                    poolCard
                    controls
                    disclosure
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Lucky Miner")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "bitcoinsign.circle.fill")
                .font(.system(size: 58, weight: .semibold))

            Text(miner.isRunning ? formatRate(miner.hashRate) : "READY")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text(miner.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 22)
        )
    }

    private var stats: some View {
        HStack(spacing: 12) {
            stat("Hashes", value: compact(miner.totalHashes))
            stat("Best", value: "(miner.bestZeroBits) bits")
            stat("Workers", value: "(miner.workerCount)")
        }
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var thermalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Phone protection",
                systemImage: "thermometer.medium"
            )
            .font(.headline)

            HStack {
                Text("Thermal")
                Spacer()
                Text(governor.statusText)
                    .foregroundStyle(thermalColor)
            }

            HStack {
                Text("Battery")
                Spacer()
                Text(
                    governor.batteryLevel >= 0
                        ? "(Int(governor.batteryLevel * 100))%"
                        : "—"
                )
            }

            HStack {
                Text("Low Power Mode")
                Spacer()
                Text(governor.lowPowerMode ? "On" : "Off")
            }
        }
        .font(.subheadline)
        .padding()
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var poolCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Stratum V1", systemImage: "network")
                    .font(.headline)

                Spacer()

                Text(poolState)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stratumColor)
            }

            TextField("Pool host", text: $poolHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField(
                    "Port",
                    value: $poolPort,
                    format: .number
                )
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)

                TextField(
                    "Worker / BTC username",
                    text: $poolUser
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(
                    stratum.state == .authorized
                        ? "Disconnect"
                        : "Test pool connection"
                ) {
                    if stratum.state == .authorized {
                        stratum.disconnect()
                    } else {
                        stratum.connect(
                            PoolConfiguration(
                                host: poolHost,
                                port: UInt16(clamping: poolPort),
                                username: poolUser,
                                password: poolPassword
                            )
                        )
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                if stratum.currentDifficulty > 0 {
                    Text(
                        "Diff (stratum.currentDifficulty, specifier: "%.3g")"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            Text(
                "v0.1 performs a real subscribe/authorize handshake. Pool job hashing + share submission is the next milestone and is not faked here."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Power", selection: $modeRaw) {
                ForEach(MiningMode.allCases) { item in
                    Text(item.rawValue)
                        .tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Button {
                if miner.isRunning {
                    miner.stop()
                } else {
                    miner.start(
                        mode: mode,
                        governor: governor
                    )
                }
            } label: {
                Label(
                    miner.isRunning
                        ? "STOP HASHING"
                        : "START HASHING",
                    systemImage: miner.isRunning
                        ? "stop.fill"
                        : "bolt.fill"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(
                miner.isRunning
                    ? .red
                    : .accentColor
            )
        }
    }

    private var disclosure: some View {
        Text(
            "This is a lottery-style Bitcoin miner. An iPhone is extraordinarily unlikely to find a Bitcoin block. v0.1 never displays simulated BTC earnings or fake accepted shares. Keep the app in the foreground while hashing; iOS may suspend CPU work in the background."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }

    private var thermalColor: Color {
        switch governor.thermalState {
        case .nominal:
            return .green
        case .fair:
            return .yellow
        case .serious, .critical:
            return .red
        @unknown default:
            return .orange
        }
    }

    private var poolState: String {
        switch stratum.state {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .subscribed:
            return "Subscribed"
        case .authorized:
            return "Authorized"
        case .failed:
            return "Failed"
        }
    }

    private var stratumColor: Color {
        if case .authorized = stratum.state {
            return .green
        }

        if case .failed = stratum.state {
            return .red
        }

        return .secondary
    }

    private func formatRate(_ rate: Double) -> String {
        if rate >= 1_000_000 {
            return String(
                format: "%.2f MH/s",
                rate / 1_000_000
            )
        }

        if rate >= 1_000 {
            return String(
                format: "%.2f kH/s",
                rate / 1_000
            )
        }

        return String(
            format: "%.0f H/s",
            rate
        )
    }

    private func compact(_ value: UInt64) -> String {
        if value >= 1_000_000_000 {
            return String(
                format: "%.2fB",
                Double(value) / 1_000_000_000
            )
        }

        if value >= 1_000_000 {
            return String(
                format: "%.2fM",
                Double(value) / 1_000_000
            )
        }

        if value >= 1_000 {
            return String(
                format: "%.1fK",
                Double(value) / 1_000
            )
        }

        return "(value)"
    }
}
