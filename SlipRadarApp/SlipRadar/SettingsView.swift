import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = SecretStore.loadOddsAPIKey()
    @State private var maxSlipLegs: Int = {
        let current = UserDefaults.standard.integer(forKey: "SlipRadar.maxSlipLegs.v10")
        if current != 0 { return current }
        let legacy = UserDefaults.standard.integer(forKey: "SlipRadar.maxSlipLegs.v09")
        return legacy == 0 ? 4 : legacy
    }()

    @State private var dailyRiskUnits: Double = {
        let current = UserDefaults.standard.double(forKey: "SlipRadar.dailyRiskUnits.v10")
        if current != 0 { return current }
        let legacy = UserDefaults.standard.double(forKey: "SlipRadar.dailyRiskUnits.v09")
        return legacy == 0 ? 3 : legacy
    }()

    @State private var alertsEnabled = SlipRadarNotifications.enabled

    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Live multi-book data") {
                    SecureField("The Odds API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Stored only in this iPhone's Keychain. SlipRadar uses it for current DraftKings, FanDuel, BetMGM and Caesars comparisons when available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Link("Get a free API key", destination: URL(string: "https://the-odds-api.com/")!)
                }

                Section("Watch alerts") {
                    Toggle("Meaningful alerts", isOn: $alertsEnabled)

                    Text("Alerts are limited to material changes detected when SlipRadar refreshes: a watched line improves to STRONG/LOCK, becomes stale/mismatched, or a materially better price appears. This build does not claim continuous background monitoring while the app is closed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Risk guard") {
                    Stepper("Max slip legs: \(maxSlipLegs)", value: $maxSlipLegs, in: 1...10)

                    HStack {
                        Text("Daily risk-unit reminder")
                        Spacer()
                        TextField(
                            "3",
                            value: $dailyRiskUnits,
                            format: .number.precision(.fractionLength(0...1))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    }

                    Text("These are local guardrails only. SlipRadar does not increase stake size because a pick is labeled LOCK or STRONG.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("v1.0 model policy") {
                    Text("Player/team statistics create the prediction. Live no-vig market prices challenge it. Line freshness, availability, lineup context, weather where relevant, movement and model history gate confidence. Public betting popularity is intentionally minor.")
                        .font(.footnote)

                    Text("Model version: \(ModelVersion.current)")
                        .font(.footnote.weight(.semibold))
                }
            }
            .navigationTitle("SlipRadar Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        SecretStore.saveOddsAPIKey(apiKey)
                        UserDefaults.standard.set(maxSlipLegs, forKey: "SlipRadar.maxSlipLegs.v10")
                        UserDefaults.standard.set(max(0.5, dailyRiskUnits), forKey: "SlipRadar.dailyRiskUnits.v10")
                        SlipRadarNotifications.setEnabled(alertsEnabled)
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
    }
}
