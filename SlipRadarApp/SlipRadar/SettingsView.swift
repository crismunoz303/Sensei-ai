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

    @State private var defaultUnitsPerLeg: Double = {
        let stored = UserDefaults.standard.double(forKey: "SlipRadar.defaultUnitsPerLeg.v10")
        return stored == 0 ? 1.0 : stored
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

                    Text("Stored only in this iPhone's Keychain. SlipRadar requests the US region so it can compare every US sportsbook returned by the live-odds provider, then highlights the best observed price.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("The free API quota is protected with caching and on-demand prop verification. A full All-sports scan can still consume multiple credits, so repeated manual refreshes are intentionally cached.")
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

                    HStack {
                        Text("Default units when adding a leg")
                        Spacer()
                        Stepper(
                            String(format: "%.2f", defaultUnitsPerLeg),
                            value: $defaultUnitsPerLeg,
                            in: 0.25...3.0,
                            step: 0.25
                        )
                        .labelsHidden()
                        Text(String(format: "%.2f", defaultUnitsPerLeg))
                            .frame(width: 44, alignment: .trailing)
                    }

                    Text("These are user-controlled tracking guardrails only. SlipRadar does not recommend larger stake sizes because a pick is labeled LOCK or STRONG.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("v1.0 model policy") {
                    Text("Player/team statistics create the prediction. Live no-vig prices across available US books challenge it. Line freshness, availability, lineup context, weather where relevant, movement and model history gate confidence. Public betting popularity is intentionally minor. Unsupported advanced inputs are labeled LIMITED instead of guessed.")
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
                        UserDefaults.standard.set(min(3.0, max(0.25, defaultUnitsPerLeg)), forKey: "SlipRadar.defaultUnitsPerLeg.v10")
                        SlipRadarNotifications.setEnabled(alertsEnabled)
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
    }
}
