import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject private var diagnostics = SenseiDiagnostics.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let interrupted = diagnostics.suspectedInterruptedLoad {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("LAST LOAD ENDED UNEXPECTEDLY")
                                    .font(.caption.monospaced().weight(.black))
                                    .foregroundStyle(.red)
                                Text("Last checkpoint: \(interrupted.stage)")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text(interrupted.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("This identifies the last completed app checkpoint. It does not label the root cause unless SENSEI actually captured one.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.red.opacity(0.45), lineWidth: 1)
                            )
                        }

                        diagnosticSummary

                        if diagnostics.events.isEmpty {
                            Text("No diagnostic events yet.")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(diagnostics.events) { event in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(event.level)
                                            .font(.caption2.monospaced().weight(.black))
                                            .foregroundStyle(event.level == "ERROR" || event.level == "CRITICAL" ? .red : .secondary)
                                        Spacer()
                                        Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(event.stage)
                                        .font(.caption.monospaced().weight(.bold))
                                        .foregroundStyle(.white)

                                    if let model = event.model {
                                        Text(model)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.red)
                                    }

                                    Text(event.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)

                                    if let bytes = event.residentMemoryBytes {
                                        Text(String(format: "RAM: %.2f GB", Double(bytes) / 1_000_000_000))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 10) {
                                        if let thermal = event.thermalState {
                                            Label(thermal, systemImage: "thermometer.medium")
                                                .foregroundStyle(thermal == "SERIOUS" || thermal == "CRITICAL" ? .red : .secondary)
                                        }
                                        if let lowPower = event.lowPowerMode {
                                            Text(lowPower ? "LOW POWER ON" : "LOW POWER OFF")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.caption2.monospaced().weight(.bold))
                                }
                                .padding(12)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("ERRORS / DIAGNOSTICS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        diagnostics.clear()
                    }
                    .foregroundStyle(.red)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: diagnostics.exportReportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(.red)

                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private var diagnosticSummary: some View {
        let peak = diagnostics.events.compactMap(\.residentMemoryBytes).max()
        let thermal = diagnostics.events.first?.thermalState ?? "UNKNOWN"
        let serious = diagnostics.events.filter { $0.thermalState == "SERIOUS" || $0.thermalState == "CRITICAL" }.count
        let errors = diagnostics.events.filter { $0.level == "ERROR" || $0.level == "CRITICAL" }.count

        return VStack(alignment: .leading, spacing: 9) {
            Text("LIVE HEALTH")
                .font(.caption.monospaced().weight(.black))
                .foregroundStyle(.red)
            HStack {
                metric("THERMAL", thermal)
                Spacer()
                metric("ISSUES", "\(errors)")
                Spacer()
                metric("HOT SAMPLES", "\(serious)")
            }
            if let peak {
                Text(String(format: "Peak observed SENSEI RAM: %.2f GB", Double(peak) / 1_000_000_000))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Thermal and memory values are observations. Diagnostics does not claim a root cause unless the captured evidence establishes one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced().weight(.bold)).foregroundStyle(.white)
        }
    }
}
