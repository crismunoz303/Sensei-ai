import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = SecretStore.loadOddsAPIKey()
    @State private var maxSlipLegs = UserDefaults.standard.integer(forKey: "SlipRadar.maxSlipLegs.v09")
    @State private var dailyRiskUnits = UserDefaults.standard.double(forKey: "SlipRadar.dailyRiskUnits.v09")

    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Live multi-book data") {
                    SecureField("The Odds API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("The key is stored only in this iPhone's Keychain. SlipRadar uses it for live DraftKings, FanDuel, BetMGM and Caesars-market comparisons when available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Link("Get a free API key", destination: URL(string: "https://the-odds-api.com/")!)
                }

                Section("Risk guard") {
                    Stepper(
                        "Max slip legs: \(normalizedMaxLegs)",
                        value: Binding(
                            get: { normalizedMaxLegs },
                            set: { maxSlipLegs = $0 }
                        ),
                        in: 1...10
                    )

                    HStack {
                        Text("Daily risk-unit reminder")
                        Spacer()
                        TextField(
                            "3",
                            value: Binding(
                                get: { normalizedRiskUnits },
                                set: { dailyRiskUnits = $0 }
                            ),
                            format: .number.precision(.fractionLength(0...1))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    }

                    Text("These are guardrails only. SlipRadar does not increase stake size because a pick is labeled LOCK or STRONG.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("v0.9 model policy") {
                    Text("Player/team statistics create the prediction. Live market prices challenge it. Injuries and line verification gate it. Public betting popularity is only a minor confirmation input.")
                        .font(.footnote)
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
                        UserDefaults.standard.set(normalizedMaxLegs, forKey: "SlipRadar.maxSlipLegs.v09")
                        UserDefaults.standard.set(normalizedRiskUnits, forKey: "SlipRadar.dailyRiskUnits.v09")
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
    }

    private var normalizedMaxLegs: Int {
        maxSlipLegs == 0 ? 4 : maxSlipLegs
    }

    private var normalizedRiskUnits: Double {
        dailyRiskUnits == 0 ? 3 : max(0.5, dailyRiskUnits)
    }
}
