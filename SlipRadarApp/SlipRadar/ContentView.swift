import SwiftUI

struct ContentView: View {
    @State private var selectedSection: AppSection = .locks
    @State private var selectedSport: SportFilter = .all
    @State private var resultsBySource: [BetSource: [PopularBet]] = [:]
    @State private var props: [PropPick] = []
    @State private var slip: [SlipLeg] = []
    @State private var loadingSources: Set<BetSource> = Set(BetSource.allCases)
    @State private var loadingProps = true
    @State private var refreshToken = UUID()
    @State private var lastUpdated: Date?

    private var locks: [PopularBet] {
        resultsBySource.values
            .flatMap { $0 }
            .filter { $0.isLock }
            .sorted { lhs, rhs in
                if lhs.lockScore == rhs.lockScore {
                    return (lhs.moneyPercent ?? 0) > (rhs.moneyPercent ?? 0)
                }
                return lhs.lockScore > rhs.lockScore
            }
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.055).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                sectionBar

                if selectedSection != .slip {
                    sportBar
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        switch selectedSection {
                        case .locks:
                            locksSection
                        case .props:
                            propsSection
                        case .slip:
                            slipSection
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

            WebTextLoader(
                url: selectedSport.draftKingsPropsURL,
                refreshToken: refreshToken,
                onText: handlePropsText,
                onError: { _ in handlePropsError() }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
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

                Text("LOCKS • PROPS • BUILD")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.4)
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
        .padding(.bottom, 12)
    }

    private var sectionBar: some View {
        HStack(spacing: 8) {
            ForEach(AppSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 5) {
                        Text(section.rawValue)
                        if section == .slip && !slip.isEmpty {
                            Text("\(slip.count)")
                                .font(.system(size: 10, weight: .black))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.18), in: Capsule())
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(selectedSection == section ? .black : .white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        selectedSection == section ? Color.green : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var sportBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SportFilter.allCases) { sport in
                    Button {
                        selectedSport = sport
                    } label: {
                        Text(sport.rawValue)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(selectedSport == sport ? .black : .white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                selectedSport == sport ? Color.green : Color.white.opacity(0.07),
                                in: Capsule()
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var locksSection: some View {
        statusPanel

        if !loadingSources.isEmpty && locks.isEmpty {
            loadingCard("Scanning sportsbook boards…")
        } else if locks.isEmpty {
            emptyCard("NO QUALIFYING LOCKS", "Nothing on the connected public boards passed the lock filter.")
        } else {
            ForEach(Array(locks.prefix(12).enumerated()), id: \.element.id) { index, bet in
                lockCard(rank: index + 1, bet: bet)
            }
        }
    }

    @ViewBuilder
    private var propsSection: some View {
        propStatusPanel

        if loadingProps && props.isEmpty {
            loadingCard("Loading individual player props…")
        } else if props.isEmpty {
            emptyCard("NO PROPS FOUND", "No current public player props were returned for this sport.")
        } else {
            ForEach(props.prefix(30)) { prop in
                propCard(prop)
            }
        }
    }

    @ViewBuilder
    private var slipSection: some View {
        slipHeader

        if slip.isEmpty {
            emptyCard("YOUR SLIP IS EMPTY", "Add game locks or individual props and build your own combination here.")
        } else {
            ForEach(slip) { leg in
                slipCard(leg)
            }

            Button {
                slip.removeAll()
            } label: {
                Text("Clear Slip")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
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

                Text("Action Network • DraftKings")
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

    private var propStatusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(loadingProps ? Color.orange : Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(loadingProps ? "Loading player props…" : "\(props.count) individual props")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("DraftKings public Player Props feed")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private var slipHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("MY SLIP")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                Text("\(slip.count) selected leg\(slip.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private func loadingCard(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.green)
                .scaleEffect(1.2)

            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private func emptyCard(_ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private func lockCard(rank: Int, bet: PopularBet) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("#\(rank)")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color.green)

                Text(bet.side)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)

                Text("LOCK")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green, in: Capsule())

                Spacer()

                Text("\(bet.lockScore)")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color.green)
            }

            Text(bet.matchup)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            Text("\(bet.source.rawValue) • \(bet.market)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))

            Text(bet.lockReason)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.green.opacity(0.9))

            addButton(
                title: "Add to My Slip",
                isAdded: slip.contains(where: { $0.id == betSlipID(bet) })
            ) {
                toggleBet(bet)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func propCard(_ prop: PropPick) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(prop.signalLabel)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(prop.isLock ? .black : Color.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(prop.isLock ? Color.green : Color.green.opacity(0.12), in: Capsule())

                Text(prop.market)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)

                Spacer()

                Text(prop.odds)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color.green)
            }

            Text(prop.line)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text(prop.event)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            Text("\(prop.source) • \(prop.eventDate)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))

            addButton(
                title: "Add Prop to My Slip",
                isAdded: slip.contains(where: { $0.id == prop.id })
            ) {
                toggleProp(prop)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func slipCard(_ leg: SlipLeg) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(leg.signal)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Color.green)
                    Text(leg.title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                }

                Text(leg.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Text(leg.source)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()

            Button {
                slip.removeAll { $0.id == leg.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func addButton(title: String, isAdded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(isAdded ? "Added ✓" : title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isAdded ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isAdded ? Color.green : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            Text("LOCK = SlipRadar's strongest public-data signal, not a guaranteed winner.")
            Text("Props without verified split percentages are labeled POPULAR, not LOCK.")
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.32))
        .padding(.top, 12)
    }

    private func betSlipID(_ bet: PopularBet) -> String {
        [bet.source.rawValue, bet.matchup, bet.market, bet.side].joined(separator: "|")
    }

    private func toggleBet(_ bet: PopularBet) {
        let id = betSlipID(bet)
        if slip.contains(where: { $0.id == id }) {
            slip.removeAll { $0.id == id }
        } else {
            slip.append(SlipLeg(
                id: id,
                title: bet.side,
                subtitle: "\(bet.matchup) • \(bet.market)",
                source: bet.source.rawValue,
                signal: "LOCK"
            ))
        }
    }

    private func toggleProp(_ prop: PropPick) {
        if slip.contains(where: { $0.id == prop.id }) {
            slip.removeAll { $0.id == prop.id }
        } else {
            slip.append(SlipLeg(
                id: prop.id,
                title: prop.line,
                subtitle: "\(prop.event) • \(prop.market)",
                source: prop.source,
                signal: prop.signalLabel
            ))
        }
    }

    private func refresh() {
        resultsBySource = [:]
        props = []
        loadingSources = Set(BetSource.allCases)
        loadingProps = true
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

    private func handlePropsText(_ text: String) {
        let parsed = PropTextParser.parse(text)

        DispatchQueue.main.async {
            props = parsed
            loadingProps = false
            lastUpdated = Date()
        }
    }

    private func handlePropsError() {
        DispatchQueue.main.async {
            props = []
            loadingProps = false
            lastUpdated = Date()
        }
    }
}
