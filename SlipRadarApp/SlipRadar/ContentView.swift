import SwiftUI

struct ContentView: View {
    @State private var selectedSport: SportFilter = .all
    @State private var resultsBySource: [BetSource: [PopularBet]] = [:]
    @State private var loadingSources: Set<BetSource> = Set(BetSource.allCases)
    @State private var refreshToken = UUID()
    @State private var lastUpdated: Date?

    private var locks: [PopularBet] {
        resultsBySource.values
            .flatMap { $0 }
            .filter { $0.isLock }
            .sorted { lhs, rhs in
                if lhs.lockScore == rhs.lockScore {
                    return lhs.moneyPercent ?? 0 > rhs.moneyPercent ?? 0
                }
                return lhs.lockScore > rhs.lockScore
            }
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.055).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                sportBar

                ScrollView {
                    LazyVStack(spacing: 12) {
                        statusPanel

                        if !loadingSources.isEmpty && locks.isEmpty {
                            loadingCard
                        } else if locks.isEmpty {
                            emptyCard
                        } else {
                            ForEach(Array(locks.prefix(12).enumerated()), id: \.element.id) { index, bet in
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

            ForEach(BetSource.allCases) { source in
                WebTextLoader(
                    url: sourceURL(source),
                    refreshToken: refreshToken,
                    onText: { text in handleText(text, source: source) },
                    onError: { _ in handleError(source: source) }
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: selectedSport) { _, _ in
            refresh()
        }
    }

    private func sourceURL(_ source: BetSource) -> URL {
        switch source {
        case .action:
            return selectedSport.actionURL
        case .draftKings:
            return selectedSport.draftKingsURL
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SLIPRADAR")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("MULTI-BOOK LOCKS")
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
                .fill(loadingSources.isEmpty ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(loadingSources.isEmpty ? "\(locks.count) locks across sources" : "Scanning sportsbook boards…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text(sourceStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            if let lastUpdated {
                Text(lastUpdated.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private var sourceStatusText: String {
        let loaded = BetSource.allCases.filter { resultsBySource[$0] != nil }
        if loaded.isEmpty {
            return "Action Network + DraftKings"
        }
        return loaded.map { $0.rawValue }.joined(separator: " • ")
    }

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.green)
                .scaleEffect(1.2)

            Text("Checking public money and bet splits…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.slash")
                .font(.system(size: 28))
                .foregroundStyle(.orange)

            Text("NO QUALIFYING LOCKS")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(.white)

            Text("The connected public sportsbook boards did not produce a play strong enough for the lock filter.")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.62))

            Button("Scan Again", action: refresh)
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
        HStack(spacing: 12) {
            rankView(rank)
            betDetails(bet)
            Spacer()
            scoreView(bet)
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(rank <= 3 ? Color.green.opacity(0.28) : Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    private func rankView(_ rank: Int) -> some View {
        Text("#\(rank)")
            .font(.system(size: 14, weight: .black, design: .rounded))
            .foregroundStyle(rank <= 3 ? Color.green : Color.white.opacity(0.4))
            .frame(width: 32)
    }

    private func betDetails(_ bet: PopularBet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(bet.side)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text("LOCK")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }

            Text(bet.matchup)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(bet.source.rawValue.uppercased())
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green, in: Capsule())

                Text(bet.market.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Text(bet.lockReason)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.green.opacity(0.88))

            statsRow(bet)
        }
    }

    private func statsRow(_ bet: PopularBet) -> some View {
        HStack(spacing: 12) {
            stat("BETS", "\(bet.betsPercent)%")

            if let money = bet.moneyPercent {
                stat("MONEY", "\(money)%")
            }

            if let diff = bet.splitDifference {
                let diffText = diff >= 0 ? "+\(diff)%" : "\(diff)%"
                stat("DIFF", diffText)
            }
        }
    }

    private func scoreView(_ bet: PopularBet) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("\(bet.lockScore)")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(Color.green)

            Text("SCORE")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))

            Text(bet.startTime)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.trailing)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.32))
        }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            Text("LOCK means SlipRadar's strongest public-data signal — never a guaranteed winner.")
            Text("Public sources currently connected: Action Network and DraftKings. Internal sportsbook data is only used when publicly exposed.")
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.32))
        .padding(.top, 12)
    }

    private func refresh() {
        resultsBySource = [:]
        loadingSources = Set(BetSource.allCases)
        refreshToken = UUID()
    }

    private func handleText(_ text: String, source: BetSource) {
        let parsed = BetTextParser.parse(text, source: source)

        DispatchQueue.main.async {
            resultsBySource[source] = parsed
            loadingSources.remove(source)
            lastUpdated = Date()
        }
    }

    private func handleError(source: BetSource) {
        DispatchQueue.main.async {
            resultsBySource[source] = []
            loadingSources.remove(source)
            lastUpdated = Date()
        }
    }
}
