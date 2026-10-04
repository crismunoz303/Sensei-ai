import SwiftUI

struct ContentView: View {
    @State private var selectedSport: SportFilter = .all
    @State private var bets: [PopularBet] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var refreshToken = UUID()
    @State private var lastUpdated: Date?

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.055).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                sportBar

                ScrollView {
                    LazyVStack(spacing: 12) {
                        statusPanel

                        if loading && bets.isEmpty {
                            loadingCard
                        } else if bets.isEmpty {
                            emptyCard
                        } else {
                            ForEach(Array(bets.prefix(20).enumerated()), id: \.element.id) { index, bet in
                                betCard(rank: index + 1, bet: bet)
                            }
                        }

                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .refreshable { refresh() }
            }

            WebTextLoader(
                url: selectedSport.sourceURL,
                refreshToken: refreshToken,
                onText: handleText,
                onError: handleError
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .onChange(of: selectedSport) { _, _ in refresh() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SLIPRADAR")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("TODAY'S PUBLIC ACTION")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(Color.green)
            }
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var sportBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SportFilter.allCases) { sport in
                    Button {
                        selectedSport = sport
                    } label: {
                        Text(sport.rawValue)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selectedSport == sport ? .black : .white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                selectedSport == sport ? Color.green : Color.white.opacity(0.07),
                                in: Capsule()
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }

    private var statusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(loading ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(loading ? "Refreshing live public data…" : "\(bets.count) public plays ranked")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
            Text("ACTION NETWORK")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.green).scaleEffect(1.2)
            Text("Reading today's betting board…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(errorMessage ?? "No public betting rows are available yet.")
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
            Button("Try Again", action: refresh)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Color.green, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private func betCard(rank: Int, bet: PopularBet) -> some View {
        HStack(spacing: 14) {
            Text("#\(rank)")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(rank <= 3 ? Color.green : .white.opacity(0.4))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(bet.side)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("PUBLIC SIDE")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }

                Text(bet.matchup)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.67))

                HStack(spacing: 14) {
                    stat("BETS", "\(bet.betsPercent)%")
                    if let money = bet.moneyPercent {
                        stat("MONEY", "\(money)%")
                    }
                    if let diff = bet.splitDifference {
                        stat("DIFF", diff >= 0 ? "+\(diff)%" : "\(diff)%")
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                Text("\(bet.score)")
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundStyle(bet.score >= 70 ? Color.green : .white)
                Text("SCORE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
                Text(bet.startTime)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(rank <= 3 ? Color.green.opacity(0.22) : Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.32))
        }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            Text("Public betting information only — not a sportsbook.")
            Text("Data availability varies by game and source. 21+ where applicable.")
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.32))
        .padding(.top, 12)
    }

    private func refresh() {
        loading = true
        errorMessage = nil
        refreshToken = UUID()
    }

    private func handleText(_ text: String) {
        let parsed = BetTextParser.parse(text)
        DispatchQueue.main.async {
            self.bets = parsed
            self.loading = false
            self.lastUpdated = Date()
            self.errorMessage = parsed.isEmpty ? "No usable public betting rows were found on this board." : nil
        }
    }

    private func handleError(_ error: Error) {
        DispatchQueue.main.async {
            self.loading = false
            self.errorMessage = error.localizedDescription
        }
    }
}
