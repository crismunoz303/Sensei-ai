import SwiftUI

struct ContentView: View {
    @State private var selectedSection: AppSection = .locks
    @State private var selectedSport: SportFilter = .all
    @State private var resultsBySource: [BetSource: [PopularBet]] = [:]
    @State private var props: [PropPick] = []
    @State private var slip: [SlipLeg]

    @State private var loadingSources: Set<BetSource> = Set(BetSource.allCases)
    @State private var loadingProps = true
    @State private var refreshToken = UUID()
    @State private var lastUpdated: Date?

    @State private var contextText = ""
    @State private var contextLoaded = false

    @State private var apiKey = SecretStore.loadOddsAPIKey()
    @State private var liveTeamConsensus: [LiveMarketConsensus] = []
    @State private var liveTeamLoading = false
    @State private var liveTeamError: String?

    @State private var teamProjections: [String: TeamProjection] = [:]
    @State private var propProjections: [String: StatProjection] = [:]
    @State private var propProjectionLoading: Set<String> = []
    @State private var propVerifications: [String: LivePropVerification] = [:]
    @State private var propVerificationLoading: Set<String> = []

    @State private var showSettings = false
    @State private var performanceToken = UUID()
    @State private var autoGrading = false

    init() {
        _slip = State(initialValue: SlipStore.load())
    }

    private var board: [PopularBet] {
        resultsBySource.values.flatMap { $0 }
    }

    private var liveConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selectedSport.oddsAPISportKey != nil
    }

    private var scoredBets: [ScoredBet] {
        board
            .map { bet in
                let live = LiveOddsService.matchConsensus(for: bet, in: liveTeamConsensus)
                let projection = teamProjections[MarketKey.normalized(bet.matchup)]
                return ScoredBet(
                    bet: bet,
                    report: DecisionEngine.report(
                        for: bet,
                        board: board,
                        liveConsensus: live,
                        teamProjection: projection,
                        liveConfigured: liveConfigured
                    )
                )
            }
            .sorted(by: scoredBetSort)
    }

    private var scoredProps: [ScoredProp] {
        props
            .map { prop in
                ScoredProp(
                    prop: prop,
                    report: DecisionEngine.report(
                        for: prop,
                        projection: propProjections[prop.id],
                        verification: propVerifications[prop.id],
                        contextText: contextText,
                        liveConfigured: liveConfigured
                    )
                )
            }
            .sorted(by: scoredPropSort)
    }

    private var lockPicks: [ScoredBet] {
        scoredBets.filter { $0.report.verdict == .lock }
    }

    private var nearMisses: [ScoredBet] {
        scoredBets.filter {
            $0.report.verdict == .strong || $0.report.verdict == .consider
        }
    }

    private var teamPicks: [ScoredBet] {
        scoredBets.filter { item in
            let market = item.bet.market.lowercased()
            let teamMarket = market.contains("moneyline") ||
                market.contains("spread") ||
                market.contains("total") ||
                market == "side"
            return teamMarket && item.report.verdict != .pass
        }
    }

    private var trackedPicks: [TrackedPick] {
        let _ = performanceToken
        return PerformanceStore.load()
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.055).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                sectionBar

                if selectedSection != .slip && selectedSection != .performance {
                    sportBar
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if selectedSection != .performance {
                            liveDataPanel
                        }

                        switch selectedSection {
                        case .locks:
                            locksSection
                        case .teams:
                            teamsSection
                        case .props:
                            propsSection
                        case .slip:
                            slipSection
                        case .performance:
                            performanceSection
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

            if let contextURL = selectedSport.contextURL {
                WebTextLoader(
                    url: contextURL,
                    refreshToken: refreshToken,
                    onText: handleContextText,
                    onError: { _ in handleContextError() }
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView {
                apiKey = SecretStore.loadOddsAPIKey()
                refreshLiveLayers()
            }
        }
        .onChange(of: selectedSport) { _, _ in
            refresh()
        }
        .onChange(of: selectedSection) { _, section in
            if section == .performance {
                Task { await autoGradePending() }
            }
        }
    }

    private func sourceURL(_ source: BetSource) -> URL {
        switch source {
        case .action: return selectedSport.actionURL
        case .draftKings: return selectedSport.draftKingsURL
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SLIPRADAR")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("LIVE STAT MODEL • v0.9")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Color.green)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08), in: Circle())
            }

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var sectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
                        .foregroundStyle(selectedSection == section ? .black : .white.opacity(0.72))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            selectedSection == section ? Color.green : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
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
        .padding(.bottom, 4)
    }

    private var liveDataPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(livePanelColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(livePanelTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)

                Text(livePanelSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !liveConfigured && selectedSport != .all {
                Button("Connect") { showSettings = true }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.green)
            }
        }
        .padding(13)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
        .padding(.top, 4)
    }

    private var livePanelColor: Color {
        if selectedSport == .all { return .orange }
        if !liveConfigured { return .orange }
        if liveTeamLoading { return .orange }
        if liveTeamError != nil { return .red }
        return .green
    }

    private var livePanelTitle: String {
        if selectedSport == .all { return "Select a sport for the full v0.9 model" }
        if !liveConfigured { return "Live multi-book verification is off" }
        if liveTeamLoading { return "Refreshing live multi-book market…" }
        if liveTeamError != nil { return "Live market refresh had an error" }
        return "\(liveTeamConsensus.count) live consensus outcomes loaded"
    }

    private var livePanelSubtitle: String {
        if selectedSport == .all {
            return "All still shows public boards; sport-specific selection enables ESPN statistical modeling and multi-book validation."
        }
        if !liveConfigured {
            return "Add a free The Odds API key in Settings. Stats modeling still runs without it."
        }
        if let error = liveTeamError { return error }
        if let newest = liveTeamConsensus.map(\.lastUpdated).max() {
            return "DraftKings • FanDuel • BetMGM • Caesars when available • updated \(newest.formatted(date: .omitted, time: .shortened))"
        }
        return "Connected — waiting for current markets."
    }

    @ViewBuilder
    private var locksSection: some View {
        statusPanel

        if !loadingSources.isEmpty && scoredBets.isEmpty {
            loadingCard("Building statistical + market decision board…")
        } else if lockPicks.isEmpty {
            emptyCard(
                "PASS — NO VERIFIED LOCKS",
                "Nothing currently meets the independent-model, live-line and evidence thresholds. SlipRadar will not manufacture a lock."
            )

            if !nearMisses.isEmpty {
                sectionLabel("CLOSEST QUALIFIERS", "These are not locks. The card explains what is missing.")
                ForEach(nearMisses.prefix(3)) { item in
                    betCard(item)
                }
            }
        } else {
            sectionLabel("VERIFIED LOCKS", "Statistics lead; live market data validates.")
            ForEach(lockPicks.prefix(10)) { item in
                betCard(item)
            }

            if !nearMisses.isEmpty {
                sectionLabel("NEAR MISSES", "Useful research, but below the LOCK threshold.")
                ForEach(nearMisses.prefix(3)) { item in
                    betCard(item)
                }
            }
        }
    }

    @ViewBuilder
    private var teamsSection: some View {
        statusPanel

        if !loadingSources.isEmpty && teamPicks.isEmpty {
            loadingCard("Building whole-team projections…")
        } else if teamPicks.isEmpty {
            emptyCard(
                "NO QUALIFIED TEAM PICKS",
                "No current team market has enough statistical edge and live-line quality."
            )
        } else {
            ForEach(teamPicks.prefix(20)) { item in
                betCard(item)
            }
        }
    }

    @ViewBuilder
    private var propsSection: some View {
        propStatusPanel

        if loadingProps && props.isEmpty {
            loadingCard("Loading and modeling player props…")
        } else if scoredProps.isEmpty {
            emptyCard(
                "NO PROPS FOUND",
                "No current public player props were returned for this sport."
            )
        } else {
            ForEach(scoredProps.prefix(30)) { item in
                propCard(item)
            }
        }
    }

    @ViewBuilder
    private var slipSection: some View {
        slipSummaryCard

        if slip.isEmpty {
            emptyCard(
                "YOUR SLIP IS EMPTY",
                "Add qualified game, team or player picks. SlipRadar will flag correlation and the weakest leg."
            )
        } else {
            ForEach(slip) { leg in
                slipCard(leg)
            }

            Button {
                slip.removeAll()
                SlipStore.save(slip)
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

    @ViewBuilder
    private var performanceSection: some View {
        performanceSummaryCard
        performanceBreakdownCard

        if autoGrading {
            inlineLoading("Checking finished team bets against final scores…")
        }

        if trackedPicks.isEmpty {
            emptyCard(
                "NO TRACKED PICKS YET",
                "Adding a pick to My Slip records the exact recommendation so the model can be audited over time."
            )
        } else {
            ForEach(trackedPicks.prefix(50)) { pick in
                performanceCard(pick)
            }
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(loadingSources.isEmpty ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(loadingSources.isEmpty ? "\(scoredBets.count) markets scored" : "Scanning public boards…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("\(teamProjections.count) independent team models • public popularity capped as minor evidence")
                    .font(.system(size: 10))
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
    }

    private var propStatusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(loadingProps ? Color.orange : Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(loadingProps ? "Loading player props…" : "\(scoredProps.count) props scored")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("\(propProjections.count) recent-game projections • \(propVerifications.count) live-line checks • injuries \(contextLoaded ? "loaded" : "limited")")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private func sectionLabel(_ title: String, _ subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.8))
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
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

    private func betCard(_ item: ScoredBet) -> some View {
        let bet = item.bet
        let report = item.report
        let live = LiveOddsService.matchConsensus(for: bet, in: liveTeamConsensus)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                verdictBadge(report.verdict)

                Text(bet.side)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()

                liveStatusBadge(report.liveStatus)
            }

            Text(bet.matchup)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            probabilityGrid(report)

            HStack(spacing: 6) {
                Text(bet.source == .draftKings ? "DraftKings split feed" : bet.source.rawValue)
                Text("•")
                Text(bet.market)
                if let live {
                    Text("•")
                    Text("\(live.bookCount) live books")
                }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.43))

            evidenceBox(report)

            if report.verdict != .pass {
                addButton(
                    title: "Add to My Slip",
                    isAdded: slip.contains(where: { $0.id == betSlipID(bet) }),
                    disabled: slipIsAtLimit && !slip.contains(where: { $0.id == betSlipID(bet) })
                ) {
                    toggleBet(bet, report: report)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func propCard(_ item: ScoredProp) -> some View {
        let prop = item.prop
        let report = item.report
        let loadingProjection = propProjectionLoading.contains(prop.id)
        let loadingVerification = propVerificationLoading.contains(prop.id)
        let verification = propVerifications[prop.id]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                verdictBadge(report.verdict)

                Text(prop.market)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()

                liveStatusBadge(report.liveStatus)
            }

            Text(prop.line)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text(prop.event)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            probabilityGrid(report)

            if loadingProjection {
                inlineLoading("Building recent-game statistical model…")
            } else if propProjections[prop.id] == nil {
                Text("STAT MODEL UNAVAILABLE — this prop cannot become a LOCK.")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.orange)
            }

            if loadingVerification {
                inlineLoading("Checking the exact prop across live books…")
            } else if let verification {
                Text(verification.note)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(verification.status == .live ? Color.green.opacity(0.9) : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                verifyPropButton(prop)
            }

            evidenceBox(report)

            if report.verdict != .pass {
                addButton(
                    title: "Add Prop to My Slip",
                    isAdded: slip.contains(where: { $0.id == prop.id }),
                    disabled: slipIsAtLimit && !slip.contains(where: { $0.id == prop.id })
                ) {
                    toggleProp(prop, report: report)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func verifyPropButton(_ prop: PropPick) -> some View {
        Button {
            if liveConfigured {
                verifyProp(prop)
            } else {
                showSettings = true
            }
        } label: {
            HStack {
                Image(systemName: liveConfigured ? "checkmark.shield" : "link")
                Text(liveConfigured ? "Verify exact line across books" : "Connect live multi-book data")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.green)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func inlineLoading(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().tint(.green).scaleEffect(0.8)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func verdictBadge(_ verdict: PickVerdict) -> some View {
        Text(verdict.rawValue)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(verdict == .lock ? .black : .white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(verdictColor(verdict), in: Capsule())
    }

    private func verdictColor(_ verdict: PickVerdict) -> Color {
        switch verdict {
        case .lock: return .green
        case .strong: return .green.opacity(0.5)
        case .consider: return .orange.opacity(0.55)
        case .pass: return .red.opacity(0.55)
        }
    }

    private func liveStatusBadge(_ status: LiveLineStatus) -> some View {
        Text(status.rawValue)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(status == .live ? Color.green : status == .mismatch ? Color.red : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.055), in: Capsule())
    }

    private func probabilityGrid(_ report: DecisionReport) -> some View {
        HStack(spacing: 8) {
            probabilityCell("MODEL", report.modelProbability)
            probabilityCell("FAIR", report.fairProbability)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.estimatedEdge.map { String(format: "%+.1f", $0) } ?? "—")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle((report.estimatedEdge ?? 0) > 0 ? Color.green : .white)
                Text("EDGE")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(report.evidenceScore)")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                Text("EVIDENCE")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
    }

    private func probabilityCell(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(label == "MODEL" && value != nil ? Color.green : .white)
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func evidenceBox(_ report: DecisionReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("WHY THIS PICK")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.45))

                Spacer()

                Text("QUALITY \(report.dataQuality)/100")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.55))
            }

            if report.reasons.isEmpty {
                Text("• Not enough independent evidence to support this selection.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                ForEach(Array(report.reasons.prefix(5).enumerated()), id: \.offset) { _, reason in
                    Text("• \(reason)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !report.risks.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))

                Text("WHY IT COULD FAIL")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.orange)

                ForEach(Array(report.risks.prefix(4).enumerated()), id: \.offset) { _, risk in
                    Text("• \(risk)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var slipSummaryCard: some View {
        let probabilities = slip.compactMap { $0.probability }
        let combined = probabilities.isEmpty ? nil : probabilities.reduce(1.0) { partial, value in
            partial * (value / 100.0)
        } * 100.0
        let weakest = slip.min(by: { $0.evidenceScore < $1.evidenceScore })

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MY SLIP")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(slip.count)/\(maxSlipLegs) LEGS")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(slipIsAtLimit ? Color.orange : Color.green)
            }

            if let combined {
                Text(String(format: "Naive independent chance: %.2f%%", combined))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("No probability estimate is available yet.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if let weakest {
                Text("Weakest evidence leg: \(weakest.title) — \(weakest.evidenceScore)/100")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            if hasCorrelatedLegs {
                Text("⚠️ Same-event correlation detected. The multiplied probability above should not be treated as a true combined probability.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if slip.count >= 2 {
                Text("No obvious same-event correlation detected. Independence is still only an approximation.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Text("Risk guard: max \(maxSlipLegs) legs • daily reminder \(dailyRiskUnitsString) units.")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private var maxSlipLegs: Int {
        let stored = UserDefaults.standard.integer(forKey: "SlipRadar.maxSlipLegs.v09")
        return stored == 0 ? 4 : stored
    }

    private var dailyRiskUnits: Double {
        let stored = UserDefaults.standard.double(forKey: "SlipRadar.dailyRiskUnits.v09")
        return stored == 0 ? 3 : stored
    }

    private var dailyRiskUnitsString: String {
        dailyRiskUnits.rounded() == dailyRiskUnits
            ? String(Int(dailyRiskUnits))
            : String(format: "%.1f", dailyRiskUnits)
    }

    private var slipIsAtLimit: Bool {
        slip.count >= maxSlipLegs
    }

    private var hasCorrelatedLegs: Bool {
        for i in slip.indices {
            for j in slip.indices where j > i {
                if MarketKey.sameEvent(slip[i].event, slip[j].event) {
                    return true
                }
            }
        }
        return false
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

                HStack(spacing: 6) {
                    Text(leg.source)
                    Text("•")
                    Text("Evidence \(leg.evidenceScore)/100")
                    if let probability = leg.probability {
                        Text("•")
                        Text(String(format: "%.1f%% model", probability))
                    }
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()

            Button {
                slip.removeAll { $0.id == leg.id }
                SlipStore.save(slip)
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

    private var performanceSummaryCard: some View {
        let summary = PerformanceStore.summary()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MODEL SCORECARD")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)

                Spacer()

                if autoGrading {
                    ProgressView().tint(.green)
                } else {
                    Button("Auto Grade") {
                        Task { await autoGradePending() }
                    }
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color.green)
                }
            }

            HStack(spacing: 18) {
                metric("TRACKED", "\(summary.totalTracked)")
                metric("SETTLED", "\(summary.settled)")
                if let winRate = summary.winRate {
                    metric("WIN RATE", String(format: "%.1f%%", winRate))
                }
                if let roi = summary.flatStakeROI {
                    metric("1U ROI", String(format: "%+.1f%%", roi))
                }
                if let clv = summary.averageCLV {
                    metric("CLV EST.", String(format: "%+.1f pts", clv))
                }
            }

            Text("Team results can auto-grade from final scores. Player props keep manual grading when a reliable result match is unavailable. Calibration waits for 20+ comparable settled picks.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private var performanceBreakdownCard: some View {
        let rows = PerformanceStore.breakdownByVerdict().filter { $0.count > 0 }

        return VStack(alignment: .leading, spacing: 8) {
            Text("BY VERDICT")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.5))

            if rows.isEmpty {
                Text("No settled results yet.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(row.wins)-\(row.losses)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.65))
                        Text(row.winRate.map { String(format: "%.1f%%", $0) } ?? "—")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color.green)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    private func performanceCard(_ pick: TrackedPick) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(pick.verdict)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color.green)

                Text(pick.title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()

                Text(pick.outcome.rawValue.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(outcomeColor(pick.outcome))
            }

            Text("\(pick.event) • \(pick.market)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 8) {
                Text("Evidence \(pick.evidenceScore)/100")
                if let probability = pick.estimatedProbability {
                    Text(String(format: "• %.1f%% model", probability))
                }
                if let odds = pick.odds {
                    Text("• \(odds)")
                }
                Text("• \(pick.addedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.42))

            if let latest = pick.lastSeenFairProbability {
                Text(String(format: "Latest market fair %.1f%%%@", latest, pick.marketProbability.map { String(format: " • CLV est. %+.1f pts", latest - $0) } ?? ""))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }

            if let source = pick.outcomeSource, pick.outcome != .pending {
                Text("Graded: \(source)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if pick.outcome == .pending {
                HStack(spacing: 8) {
                    gradeButton("Win", pick: pick, outcome: .win)
                    gradeButton("Loss", pick: pick, outcome: .loss)
                    gradeButton("Push", pick: pick, outcome: .push)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func gradeButton(_ title: String, pick: TrackedPick, outcome: PickOutcome) -> some View {
        Button {
            PerformanceStore.setOutcome(id: pick.id, outcome: outcome)
            performanceToken = UUID()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func outcomeColor(_ outcome: PickOutcome) -> Color {
        switch outcome {
        case .pending: return .white.opacity(0.45)
        case .win: return .green
        case .loss: return .red
        case .push: return .orange
        }
    }

    private func addButton(
        title: String,
        isAdded: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(isAdded ? "Added ✓" : disabled ? "Risk guard: slip is full" : title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isAdded ? .black : disabled ? .orange : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    isAdded ? Color.green : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .disabled(disabled)
    }

    private var footer: some View {
        VStack(spacing: 5) {
            Text("MODEL % is built from independent recent performance when verified data is available. FAIR % is the de-vigged market estimate when live opposing prices are available.")
            Text("No wager is guaranteed. A missing model, stale/mismatched line, or serious availability warning blocks a LOCK.")
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.32))
        .padding(.top, 12)
    }

    private func betSlipID(_ bet: PopularBet) -> String {
        [bet.source.rawValue, bet.matchup, bet.market, bet.side].joined(separator: "|")
    }

    private func toggleBet(_ bet: PopularBet, report: DecisionReport) {
        let id = betSlipID(bet)

        if slip.contains(where: { $0.id == id }) {
            slip.removeAll { $0.id == id }
            SlipStore.save(slip)
            return
        }

        guard !slipIsAtLimit else { return }

        let live = LiveOddsService.matchConsensus(for: bet, in: liveTeamConsensus)
        let leg = SlipLeg(
            id: id,
            title: bet.side,
            subtitle: "\(bet.matchup) • \(bet.market)",
            source: bet.source.rawValue,
            signal: report.verdict.rawValue,
            sport: selectedSport.rawValue,
            event: bet.matchup,
            market: bet.market,
            odds: live?.bestOdds ?? bet.odds,
            probability: report.modelProbability ?? report.fairProbability,
            marketProbability: report.fairProbability,
            evidenceScore: report.evidenceScore,
            playerName: nil,
            threshold: nil,
            direction: nil,
            addedAt: Date()
        )

        slip.append(leg)
        SlipStore.save(slip)
        PerformanceStore.track(leg)
        performanceToken = UUID()
    }

    private func toggleProp(_ prop: PropPick, report: DecisionReport) {
        if slip.contains(where: { $0.id == prop.id }) {
            slip.removeAll { $0.id == prop.id }
            SlipStore.save(slip)
            return
        }

        guard !slipIsAtLimit else { return }

        let verification = propVerifications[prop.id]
        let leg = SlipLeg(
            id: prop.id,
            title: prop.line,
            subtitle: "\(prop.event) • \(prop.market)",
            source: prop.source,
            signal: report.verdict.rawValue,
            sport: selectedSport.rawValue,
            event: prop.event,
            market: prop.market,
            odds: verification?.bestOdds ?? prop.odds,
            probability: report.modelProbability ?? report.fairProbability,
            marketProbability: report.fairProbability,
            evidenceScore: report.evidenceScore,
            playerName: prop.playerName.isEmpty ? nil : prop.playerName,
            threshold: prop.threshold,
            direction: prop.direction,
            addedAt: Date()
        )

        slip.append(leg)
        SlipStore.save(slip)
        PerformanceStore.track(leg)
        performanceToken = UUID()
    }

    private func refresh() {
        resultsBySource = [:]
        props = []
        loadingSources = Set(BetSource.allCases)
        loadingProps = true
        contextText = ""
        contextLoaded = selectedSport.contextURL == nil

        teamProjections = [:]
        propProjections = [:]
        propProjectionLoading = []
        propVerifications = [:]
        propVerificationLoading = []

        liveTeamConsensus = []
        liveTeamError = nil

        apiKey = SecretStore.loadOddsAPIKey()
        refreshToken = UUID()
        refreshLiveLayers()
    }

    private func refreshLiveLayers() {
        guard liveConfigured else {
            liveTeamLoading = false
            liveTeamConsensus = []
            return
        }

        liveTeamLoading = true
        liveTeamError = nil

        let sport = selectedSport
        let key = apiKey

        Task {
            do {
                let result = try await LiveOddsService.fetchTeamConsensus(sport: sport, apiKey: key)
                await MainActor.run {
                    if selectedSport == sport {
                        liveTeamConsensus = result
                        liveTeamLoading = false

                        for bet in board {
                            if let live = LiveOddsService.matchConsensus(for: bet, in: result) {
                                PerformanceStore.updateLatestMarket(
                                    id: betSlipID(bet),
                                    odds: live.bestOdds,
                                    fairProbability: live.fairProbability,
                                    observedAt: live.lastUpdated
                                )
                            }
                        }
                        performanceToken = UUID()
                    }
                }
            } catch {
                await MainActor.run {
                    if selectedSport == sport {
                        liveTeamConsensus = []
                        liveTeamLoading = false
                        liveTeamError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func verifyProp(_ prop: PropPick) {
        guard liveConfigured else {
            showSettings = true
            return
        }

        propVerificationLoading.insert(prop.id)
        let sport = selectedSport
        let key = apiKey

        Task {
            do {
                let result = try await LiveOddsService.verifyProp(prop, sport: sport, apiKey: key)
                await MainActor.run {
                    propVerifications[prop.id] = result
                    propVerificationLoading.remove(prop.id)
                    PerformanceStore.updateLatestMarket(
                        id: prop.id,
                        odds: result.bestOdds,
                        fairProbability: result.fairProbability,
                        observedAt: result.checkedAt
                    )
                    performanceToken = UUID()
                }
            } catch {
                await MainActor.run {
                    propVerifications[prop.id] = LivePropVerification(
                        status: .unverified,
                        event: prop.event,
                        market: prop.market,
                        player: prop.playerName,
                        direction: prop.direction,
                        requestedPoint: prop.threshold,
                        livePoint: nil,
                        fairProbability: nil,
                        averageImpliedProbability: nil,
                        bestOdds: nil,
                        bookCount: 0,
                        books: [],
                        checkedAt: Date(),
                        note: "Live verification failed: \(error.localizedDescription)"
                    )
                    propVerificationLoading.remove(prop.id)
                }
            }
        }
    }

    @MainActor
    private func autoGradePending() async {
        guard !autoGrading else { return }

        let pending = PerformanceStore.load().filter {
            $0.outcome == .pending && $0.playerName == nil
        }
        guard !pending.isEmpty else { return }

        autoGrading = true
        defer {
            autoGrading = false
            performanceToken = UUID()
        }

        for pick in pending.prefix(20) {
            if let outcome = await ResultAutoGrader.grade(pick) {
                PerformanceStore.setOutcome(
                    id: pick.id,
                    outcome: outcome,
                    source: "Auto • ESPN final score"
                )
            }
        }
    }

    private func handleText(_ text: String, source: BetSource) {
        let parsed = BetTextParser.parse(text, source: source)

        DispatchQueue.main.async {
            resultsBySource[source] = parsed
            MarketHistoryStore.record(bets: parsed)
            loadingSources.remove(source)
            lastUpdated = Date()
            scheduleTeamProjectionLoad()
        }
    }

    private func handleError(source: BetSource) {
        DispatchQueue.main.async {
            resultsBySource[source] = []
            loadingSources.remove(source)
            lastUpdated = Date()
        }
    }

    private func scheduleTeamProjectionLoad() {
        guard selectedSport != .all, selectedSport != .soccer else { return }

        let sport = selectedSport
        let matchups = Array(Set(board.map(\.matchup)))
            .filter { teamProjections[MarketKey.normalized($0)] == nil }
            .prefix(8)

        guard !matchups.isEmpty else { return }

        Task {
            await withTaskGroup(of: (String, TeamProjection?).self) { group in
                for matchup in matchups {
                    group.addTask {
                        let projection = await StatProjectionService.teamProjection(
                            for: matchup,
                            sport: sport
                        )
                        return (matchup, projection)
                    }
                }

                for await (matchup, projection) in group {
                    guard let projection else { continue }
                    await MainActor.run {
                        if selectedSport == sport {
                            teamProjections[MarketKey.normalized(matchup)] = projection
                        }
                    }
                }
            }
        }
    }

    private func handlePropsText(_ text: String) {
        let parsed = PropTextParser.parse(text)

        DispatchQueue.main.async {
            props = parsed
            MarketHistoryStore.record(props: parsed)
            loadingProps = false
            lastUpdated = Date()
            schedulePropProjectionLoad(parsed)
        }
    }

    private func schedulePropProjectionLoad(_ parsed: [PropPick]) {
        guard selectedSport.supportsPlayerGameLogs else { return }

        let sport = selectedSport
        let candidates = Array(parsed.prefix(16))
            .filter { propProjections[$0.id] == nil && !propProjectionLoading.contains($0.id) }

        guard !candidates.isEmpty else { return }

        candidates.forEach { propProjectionLoading.insert($0.id) }

        Task {
            await withTaskGroup(of: (String, StatProjection?).self) { group in
                for prop in candidates {
                    group.addTask {
                        let projection = await StatProjectionService.playerProjection(
                            for: prop,
                            sport: sport
                        )
                        return (prop.id, projection)
                    }
                }

                for await (id, projection) in group {
                    await MainActor.run {
                        propProjectionLoading.remove(id)
                        if selectedSport == sport, let projection {
                            propProjections[id] = projection
                        }
                    }
                }
            }
        }
    }

    private func handlePropsError() {
        DispatchQueue.main.async {
            props = []
            loadingProps = false
            lastUpdated = Date()
        }
    }

    private func handleContextText(_ text: String) {
        DispatchQueue.main.async {
            contextText = text
            contextLoaded = true
        }
    }

    private func handleContextError() {
        DispatchQueue.main.async {
            contextText = ""
            contextLoaded = false
        }
    }

    private func scoredBetSort(_ lhs: ScoredBet, _ rhs: ScoredBet) -> Bool {
        if lhs.report.verdict.rank == rhs.report.verdict.rank {
            return lhs.report.evidenceScore > rhs.report.evidenceScore
        }
        return lhs.report.verdict.rank > rhs.report.verdict.rank
    }

    private func scoredPropSort(_ lhs: ScoredProp, _ rhs: ScoredProp) -> Bool {
        if lhs.report.verdict.rank == rhs.report.verdict.rank {
            return lhs.report.evidenceScore > rhs.report.evidenceScore
        }
        return lhs.report.verdict.rank > rhs.report.verdict.rank
    }
}
