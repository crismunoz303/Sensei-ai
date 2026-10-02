import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var miner: MiningEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusCard
                    statsGrid
                    bestShareCard
                    controls
                    footerNote
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [Color.black, Color(red: 0.04, green: 0.06, blue: 0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Lucky Miner")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REAL SHA-256d")
                .font(.caption.monospaced().bold())
                .foregroundStyle(.orange)

            Text("Bitcoin Lottery Miner")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text("v0.1 runs genuine double-SHA256 work locally. Stratum/pool submission is the next milestone, so this build does not pretend it is earning Bitcoin yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label(
                    miner.isMining ? "HASHING" : "STOPPED",
                    systemImage: miner.isMining ? "bolt.fill" : "stop.circle"
                )
                .font(.headline)
                .foregroundStyle(miner.isMining ? .green : .secondary)

                Spacer()

                Text(miner.thermal.thermalLabel.uppercased())
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(thermalColor)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Thermal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(miner.thermal.thermalLabel)
                        .font(.headline)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(batteryText)
                        .font(.headline.monospacedDigit())
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            stat("HASHRATE", formatHashRate(miner.hashRate))
            stat("TOTAL HASHES", miner.totalHashes.formatted())
            stat("BEST ZERO BITS", "\(miner.bestLeadingZeroBits)")
            stat("SESSION", formatDuration(miner.sessionSeconds))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var bestShareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BEST LOCAL HASH")
                .font(.caption2.monospaced().bold())
                .foregroundStyle(.secondary)
            Text(miner.bestHash)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Picker("Power", selection: $miner.mode) {
                ForEach(MiningMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(miner.isMining)

            Toggle("Automatic thermal protection", isOn: $miner.autoThermalThrottle)
                .tint(.orange)

            Button {
                miner.isMining ? miner.stop() : miner.start()
            } label: {
                HStack {
                    Image(systemName: miner.isMining ? "stop.fill" : "bolt.fill")
                    Text(miner.isMining ? "STOP MINING" : "START HASHING")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(miner.isMining ? .red : .orange)
            .disabled(!miner.isMining && miner.thermal.shouldEmergencyStop)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var footerNote: some View {
        Text("Lottery mining means the chance of finding a Bitcoin block on a phone is extraordinarily small. This app reports real work; it never fabricates earnings or accepted shares.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    private var thermalColor: Color {
        switch miner.thermal.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private var batteryText: String {
        guard miner.thermal.batteryLevel >= 0 else { return "Unknown" }
        return "\(Int(miner.thermal.batteryLevel * 100))%"
    }

    private func formatHashRate(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2f MH/s", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.2f kH/s", value / 1_000)
        }
        return String(format: "%.0f H/s", value)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
