import SwiftUI

struct ContentView: View {
    @State private var selectedSection: AppSection = .locks
    @State private var selectedSport: SportFilter = .all

    @State private var resultsBySource: [BetSource: [PopularBet]] = [:]
    @State private var props: [PropPick] = []
    @State private var slip: [SlipLeg] = SlipStore.load()

    @State private var loadingSources: Set<BetSource> = Set(BetSource.publicFeeds)
    @State private var loadingProps = true
    @State private var refreshToken = UUID()
    @State private var lastUpdated: Date?

    @State private var contextText = ""
    @State private var contextLoaded = false

    @State private var apiKey = SecretStore.loadOddsAPIKey()
    @State private var liveTeamConsensus: [LiveMarketConsensus] = []
    @State private var liveTeamLoading = false
    @State private var liveTeamError: String?

    @State private var allLiveBySport: [SportFilter: [LiveMarketConsensus]] = [:]
    @State private var allBoard: [PopularBet] = []
    @State private var allBoardLoading = false
    @State private var allBoardError: String?

    @State private var teamProjections: [String: TeamProjection] = [:]
    @State private var teamProjectionLoading: Set<String> = []
    @State private var teamModelAttempts = 0
    @State private var teamModelFailures: [String: String] = [:]

    @State private var propProjections: [String: StatProjection] = [:]
    @State private var propProjectionLoading: Set<String> = []
    @State private var propVerifications: [String: LivePropVerification] = [:]
    @State private var propVerificationLoading: Set<String> = []
    @State private var propAvailability: [String: PlayerAvailabilitySnapshot] = [:]

    @State private var eventContextsBySport: [SportFilter: [EventContextSnapshot]] = [:]
    @State private var contextLoadingSports: Set<SportFilter> = []

    @State private var showSettings = false
    @State private var performanceToken = UUID()
    @State private var watchToken = UUID()
    @State private var autoGrading = false

    private var publicBoard: [PopularBet] {
        resultsBySource.values.flatMap { $0 }
    }

    private var board: [PopularBet] {
        if selectedSport == .all, !allBoard.isEmpty {
            return allBoard
        }
        return publicBoard.map { bet in
            var copy = bet
            copy.sport = selectedSport == .all ? bet.sport : selectedSport
            return copy
        }
    }

    private var liveConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scoredBets: [ScoredBet] {
        board.map { bet in
            let sport = bet.sport ?? selectedSport
            let live = LiveOddsService.matchConsensus(for: bet, in: liveConsensus(for: sport))
            let projection = teamProjections[projectionKey(sport, bet.matchup)]
            let context = EventContextService.matchContext(
                event: bet.matchup,
                sport: sport,
                contexts: eventContextsBySport[sport] ?? []
            )
            let sameSportBoard = board.filter { ($0.sport ?? selectedSport) == sport }

            return ScoredBet(
                sport: sport,
                bet: bet,
                report: DecisionEngine.report(
                    for: bet,
                    board: sameSportBoard,
                    liveConsensus: live,
                    teamProjection: projection,
                    eventContext: context,
                    liveConfigured: liveConfigured
                )
            )
        }
        .sorted(by: scoredBetSort)
    }

    private var scoredProps: [ScoredProp] {
        props.map { prop in
            let sport = prop.sport ?? selectedSport
            return ScoredProp(
                sport: sport,
                prop: prop,
                report: DecisionEngine.report(
                    for: prop,
                    projection: propProjections[propKey(sport, prop)],
                    verification: propVerifications[propKey(sport, prop)],
                    contextText: contextText,
                    availability: propAvailability[propKey(sport, prop)],
                    liveConfigured: liveConfigured
                )
            )
        }
        .sorted(by: scoredPropSort)
    }

    private var teamPicks: [ScoredBet] {
        scoredBets.filter { item in
            let market = item.bet.market.lowercased()
            return market.contains("moneyline") ||
                market.contains("spread") ||
                market.contains("total") ||
                market == "side"
        }
    }

    private var trackedPicks: [TrackedPick] {
        let _ = performanceToken
        return PerformanceStore.load()
    }

    private var watchItems: [WatchItem] {
        let _ = watchToken
        return WatchlistStore.load()
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.055).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                sectionBar

                if selectedSection != .slip &&
                    selectedSection != .performance &&
                    selectedSection != .watch &&
                    selectedSection != .health {
                    sportBar
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if selectedSection != .performance &&
                            selectedSection != .watch &&
                            selectedSection != .health {
                            liveDataPanel
                        }

                        switch selectedSection {
                        case .locks:
                            bestSection
                        case .teams:
                            teamsSection
                        case .props:
                            propsSection
                        case .watch:
                            watchSection
                        case .slip:
                            slipSection
                        case .performance:
                            performanceSection
                        case .health:
                            healthSection
                        }

                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .refreshable {
                    refresh()
                }
            }

            ForEach(BetSource.publicFeeds) { source in
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

            if selectedSport != .all {
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
        }
        .sheet(isPresented: $showSettings) {
            SettingsView {
                apiKey = SecretStore.loadOddsAPIKey()
                refreshLiveLayers()
            }
        }
        .task {
            refreshLiveLayers()
            if selectedSport != .all {
                loadEventContexts(for: [selectedSport])
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
        case .multiBook: return selectedSport.actionURL
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SLIPRADAR")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("FULL MODEL • v1.0 • \(ModelVersion.current)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.0)
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
                                    .font(.system(size: 9, weight: .black))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.18), in: Capsule())
                            }
                            if section == .watch && !watchItems.isEmpty {
                                Text("\(watchItems.count)")
                                    .font(.system(size: 9, weight: .black))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.18), in: Capsule())
                            }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(selectedSection == section ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 17)
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
        .padding(.bottom, 10)
    }

    private var liveDataPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedSport == .all {
                HStack(spacing: 10) {
                    Circle()
                        .fill(!allBoard.isEmpty ? Color.green : liveConfigured ? Color.orange : Color.red)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(allBoardLoading ? "Building full All-sports board…" :
                            !allBoard.isEmpty ? "\(allBoard.count) live cross-sport lines loaded" :
                            "All-sports live model is limited")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)

                        Text(!allBoard.isEmpty
                             ? "\(allLiveBySport.count) active sports • sport-specific models run per line"
                             : liveConfigured
                             ? (allBoardError ?? "Live All board has not loaded yet.")
                             : "Connect The Odds API in Settings for full All-sports modeling.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Circle()
                        .fill(!liveTeamConsensus.isEmpty ? Color.green : liveConfigured ? Color.orange : Color.red)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(liveTeamLoading ? "Refreshing multi-book market…" :
                            !liveTeamConsensus.isEmpty ? "\(liveTeamConsensus.count) live consensus outcomes" :
                            liveConfigured ? "Live market unavailable" : "Live multi-book verification is off")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)

                        Text(!liveTeamConsensus.isEmpty
                             ? "DraftKings • FanDuel • BetMGM • Caesars when available"
                             : liveTeamError ?? (liveConfigured ? "No current live outcomes returned." : "Add The Odds API key in Settings."))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer()
                }
            }

            HStack(spacing: 7) {
                statusChip("STATS", active: teamProjectionsForCurrentSport > 0)
                statusChip("LIVE BOOKS", active: selectedSport == .all ? !allBoard.isEmpty : !liveTeamConsensus.isEmpty)
                statusChip("CONTEXT", active: currentContextCount > 0)
                if selectedSport != .all {
                    statusChip("INJURIES", active: contextLoaded)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    @ViewBuilder
    private var bestSection: some View {
        statusPanel

        if (selectedSport == .all && allBoardLoading && scoredBets.isEmpty) ||
            (!loadingSources.isEmpty && scoredBets.isEmpty) {
            loadingCard("Building ranked statistical + market board…")
        } else if scoredBets.isEmpty {
            emptyCard(
                "NO LINES AVAILABLE",
                "No current team-market lines were returned for this selection."
            )
        } else {
            if !scoredBets.contains(where: { $0.report.verdict == .lock }) {
                compactNotice(
                    "NO VERIFIED LOCKS",
                    "Showing every available line ranked best → worst. PASS stays PASS."
                )
            }

            sectionLabel(
                "RANKED BOARD",
                "LOCK → STRONG → CONSIDER → PASS; ties use edge, live quality, data quality and evidence."
            )

            ForEach(Array(scoredBets.enumerated()), id: \.element.id) { index, item in
                betCard(item, rank: index + 1)
            }
        }
    }

    @ViewBuilder
    private var teamsSection: some View {
        statusPanel

        if teamPicks.isEmpty && !loadingSources.isEmpty {
            loadingCard("Building whole-team projections…")
        } else if teamPicks.isEmpty {
            emptyCard("NO TEAM LINES", "No current moneyline, spread or total lines were returned.")
        } else {
            sectionLabel("ALL TEAM LINES", "Every team market, ranked strongest to weakest.")
            ForEach(Array(teamPicks.enumerated()), id: \.element.id) { index, item in
                betCard(item, rank: index + 1)
            }
        }
    }

    @ViewBuilder
    private var propsSection: some View {
        if selectedSport == .all {
            emptyCard(
                "SELECT A SPORT FOR PROPS",
                "The All tab ranks live team markets across sports. Select NFL, NBA, MLB, etc. for sport-specific player models and prop Deep Checks."
            )
        } else {
            propStatusPanel

            if loadingProps && props.isEmpty {
                loadingCard("Loading and modeling player props…")
            } else if scoredProps.isEmpty {
                emptyCard("NO PROPS FOUND", "No current public player props were returned for this sport.")
            } else {
                sectionLabel("RANKED PROPS", "All available props, best → worst. Deep Check adds live books + lineup validation.")
                ForEach(Array(scoredProps.enumerated()), id: \.element.id) { index, item in
                    propCard(item, rank: index + 1)
                }
            }
        }
    }

    @ViewBuilder
    private var watchSection: some View {
        if watchItems.isEmpty {
            emptyCard(
                "WATCHLIST EMPTY",
                "Add any team line or prop to Watch. SlipRadar will flag meaningful verdict, line-status and price changes when the app refreshes."
            )
        } else {
            sectionLabel("WATCHLIST", "Meaningful changes only; notification alerts are optional in Settings.")
            ForEach(watchItems) { item in
                watchCard(item)
            }
        }
    }

    @ViewBuilder
    private var slipSection: some View {
        slipSummaryCard

        if slip.isEmpty {
            emptyCard(
                "YOUR SLIP IS EMPTY",
                "Add any line you want to compare. PASS/CONSIDER legs remain visibly labeled."
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

        if autoGrading {
            inlineLoading("Checking finished games/player logs…")
        }

        calibrationCard
        backtestCard
        breakdownCard(title: "BY VERDICT", rows: PerformanceStore.breakdownByVerdict())
        breakdownCard(title: "BY SPORT", rows: PerformanceStore.breakdownBySport())
        breakdownCard(title: "BY MARKET", rows: PerformanceStore.breakdownByMarket())

        if trackedPicks.isEmpty {
            emptyCard(
                "NO TRACKED PICKS YET",
                "v1.0 automatically tracks LOCK/STRONG recommendations and also records lines you add to My Slip."
            )
        } else {
            sectionLabel("TRACKED HISTORY", "MODEL = automatic model snapshot • SLIP = manually saved leg.")
            ForEach(trackedPicks.prefix(80)) { pick in
                performanceCard(pick)
            }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        sectionLabel("SOURCE HEALTH", "No silent failures: each major data layer reports its current state.")

        ForEach(sourceHealthItems) { item in
            healthCard(item)
        }

        if !teamModelFailures.isEmpty {
            sectionLabel("STAT MODEL FAILURES", "Recent unresolved matchups; these lines are confidence-capped.")
            ForEach(Array(teamModelFailures.sorted(by: { $0.key < $1.key }).prefix(12)), id: \.key) { key, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                    Text(value)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL VERSION")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.45))
            Text(ModelVersion.current)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.green)
            Text("Tracked predictions keep their model version so future logic changes do not get mixed silently.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(scoredBets.isEmpty ? Color.orange : Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(scoredBets.count) lines ranked")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("\(teamProjectionsForCurrentSport) independent team models • popularity capped as minor evidence")
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
                Text(loadingProps ? "Loading player props…" : "\(scoredProps.count) props ranked")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("\(propProjections.count) game-log projections • \(propVerifications.count) live checks • lineup Deep Check on demand")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private func betCard(_ item: ScoredBet, rank: Int) -> some View {
        let bet = item.bet
        let report = item.report
        let live = LiveOddsService.matchConsensus(for: bet, in: liveConsensus(for: item.sport))
        let watched = WatchlistStore.contains(id: WatchlistStore.watchID(
            sport: item.sport,
            event: bet.matchup,
            market: bet.market,
            selection: bet.side
        ))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                rankBadge(rank)
                verdictBadge(report.verdict)

                Text(bet.side)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()
                liveStatusBadge(report.liveStatus)
            }

            HStack {
                Text(item.sport.rawValue)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.green)
                Text(bet.matchup)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            probabilityGrid(report)

            if let live {
                Text("Best line: \(live.bestOdds) • \(live.bestBook) • \(live.bookCount) books")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green.opacity(0.85))
            }

            confidenceBreakdown(report)
            evidenceBox(report)

            HStack(spacing: 8) {
                watchButton(isWatched: watched) {
                    toggleWatch(item)
                }

                addButton(
                    title: "Add to My Slip",
                    isAdded: slip.contains(where: { $0.id == betSlipID(item.sport, bet) }),
                    disabled: slipIsAtLimit && !slip.contains(where: { $0.id == betSlipID(item.sport, bet) })
                ) {
                    toggleBet(item)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func propCard(_ item: ScoredProp, rank: Int) -> some View {
        let prop = item.prop
        let report = item.report
        let key = propKey(item.sport, prop)
        let watched = WatchlistStore.contains(id: WatchlistStore.watchID(
            sport: item.sport,
            event: prop.event,
            market: prop.market,
            selection: prop.line
        ))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                rankBadge(rank)
                verdictBadge(report.verdict)

                Text(prop.market)
                    .font(.system(size: 15, weight: .black))
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

            if let verification = propVerifications[key],
               let odds = verification.bestOdds {
                Text("Best line: \(odds)\(verification.bestBook.map { " • \($0)" } ?? "") • \(verification.bookCount) books")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green.opacity(0.85))
            }

            confidenceBreakdown(report)
            evidenceBox(report)

            if propVerificationLoading.contains(key) || propProjectionLoading.contains(key) {
                inlineLoading("Deep checking stats, line and availability…")
            } else {
                Button {
                    deepCheck(item)
                } label: {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                        Text("Deep Check • Stats + Books + Lineup")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            HStack(spacing: 8) {
                watchButton(isWatched: watched) {
                    toggleWatch(item)
                }

                addButton(
                    title: "Add to My Slip",
                    isAdded: slip.contains(where: { $0.id == prop.id }),
                    disabled: slipIsAtLimit && !slip.contains(where: { $0.id == prop.id })
                ) {
                    toggleProp(item)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func probabilityGrid(_ report: DecisionReport) -> some View {
        HStack(spacing: 8) {
            probabilityCell("MODEL", report.modelProbability)
            probabilityCell("FAIR", report.fairProbability)
            probabilityCell("EDGE", report.estimatedEdge, signed: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.expectedValuePercent.map { String(format: "%+.1f%%", $0) } ?? "—")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle((report.expectedValuePercent ?? 0) > 0 ? Color.green : .white)
                Text("EV")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
    }

    private func probabilityCell(_ label: String, _ value: Double?, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map {
                signed ? String(format: "%+.1f", $0) : String(format: "%.1f%%", $0)
            } ?? "—")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(label == "MODEL" && value != nil ? Color.green : .white)
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confidenceBreakdown(_ report: DecisionReport) -> some View {
        DisclosureGroup {
            VStack(spacing: 6) {
                componentRow("Stats", report.components.stats, 40)
                componentRow("Market", report.components.market, 25)
                componentRow("Availability", report.components.availability, 15)
                componentRow("Freshness", report.components.freshness, 10)
                componentRow("History", report.components.history, 5)
                componentRow("Public signal", report.components.publicSignal, 5)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("CONFIDENCE BREAKDOWN")
                    .font(.system(size: 9, weight: .black))
                Spacer()
                Text("\(report.dataQuality)/100")
                    .font(.system(size: 9, weight: .black))
            }
            .foregroundStyle(.white.opacity(0.55))
        }
        .tint(.white.opacity(0.5))
        .padding(11)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private func componentRow(_ label: String, _ value: Int, _ max: Int) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text("\(value)/\(max)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func evidenceBox(_ report: DecisionReport) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                if report.reasons.isEmpty {
                    Text("• Not enough independent evidence to support this selection.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                } else {
                    ForEach(Array(report.reasons.prefix(7).enumerated()), id: \.offset) { _, reason in
                        Text("• \(reason)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !report.risks.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    Text("WATCH OUT")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.orange)

                    ForEach(Array(report.risks.prefix(7).enumerated()), id: \.offset) { _, risk in
                        Text("• \(risk)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("WHY THIS RANK")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("EVIDENCE \(report.evidenceScore)")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .tint(.white.opacity(0.5))
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var slipSummaryCard: some View {
        let probabilities = slip.compactMap(\.probability)
        let combined = probabilities.isEmpty ? nil : probabilities.reduce(1.0) { $0 * ($1 / 100) } * 100
        let weakest = slip.min(by: { $0.evidenceScore < $1.evidenceScore })

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MY SLIP")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(slip.count)/\(maxSlipLegs) LEGS")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.green)
            }

            if let combined {
                Text(String(format: "Naive independent estimate: %.2f%%", combined))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            if let weakest {
                Text("Weakest leg: \(weakest.title) • \(weakest.signal) • evidence \(weakest.evidenceScore)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            ForEach(Array(slipWarnings.enumerated()), id: \.offset) { _, warning in
                Text("⚠️ \(warning)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Daily risk reminder: \(dailyRiskUnitsString) units max (local guardrail).")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private var slipWarnings: [String] {
        var warnings: [String] = []
        for i in slip.indices {
            for j in slip.indices where j > i {
                let lhs = slip[i]
                let rhs = slip[j]
                if MarketKey.sameEvent(lhs.event, rhs.event) {
                    warnings.append("\(lhs.title) and \(rhs.title) share the same event; multiplied probabilities may be correlated.")
                }
                if MarketKey.sameEvent(lhs.event, rhs.event) &&
                    MarketKey.normalized(lhs.market) == MarketKey.normalized(rhs.market) &&
                    MarketKey.selectionBase(lhs.title) != MarketKey.selectionBase(rhs.title) {
                    warnings.append("Potential conflicting exposure in \(lhs.event): \(lhs.title) vs \(rhs.title).")
                }
            }
        }
        return Array(Set(warnings)).sorted()
    }

    private func slipCard(_ leg: SlipLeg) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(leg.signal)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(signalColor(leg.signal))
                    Text(leg.title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                }

                Text(leg.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 6) {
                    Text(leg.sport)
                    if let book = leg.bestBook {
                        Text("• \(book)")
                    }
                    if let odds = leg.odds {
                        Text("• \(odds)")
                    }
                    if let probability = leg.probability {
                        Text(String(format: "• %.1f%% model", probability))
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
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

    private func watchCard(_ item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.sport.rawValue)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.green)
                Text(item.selection)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    WatchlistStore.remove(id: item.id)
                    watchToken = UUID()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.8))
                }
            }

            Text("\(item.event) • \(item.market)")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 7) {
                Text(item.lastVerdict?.rawValue ?? "WAITING")
                Text("•")
                Text(item.lastLineStatus?.rawValue ?? "UNSCANNED")
                if let odds = item.lastOdds {
                    Text("• \(odds)")
                }
                if let book = item.lastBook {
                    Text("• \(book)")
                }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))

            if let model = item.lastModelProbability, let fair = item.lastFairProbability {
                Text(String(format: "Model %.1f%% • Fair %.1f%% • Edge %+.1f", model, fair, model - fair))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }

            if let updated = item.lastUpdated {
                Text("Last checked \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
    }

    private var performanceSummaryCard: some View {
        let summary = PerformanceStore.summary()

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MODEL SCORECARD")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                    Text("Model version \(ModelVersion.current)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.38))
                }

                Spacer()

                if autoGrading {
                    ProgressView().tint(.green)
                } else {
                    Button("Auto Grade") {
                        Task { await autoGradePending() }
                    }
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.green)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
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
            }

            Text("LOCK/STRONG model recommendations are auto-recorded so model performance is not biased toward only the bets you choose.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.48))
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
    }

    private var calibrationCard: some View {
        let buckets = PerformanceStore.calibrationBuckets()

        return VStack(alignment: .leading, spacing: 9) {
            Text("CALIBRATION")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.5))

            if buckets.isEmpty {
                Text("Needs at least settled predictions in probability buckets. v1.0 will build this history automatically.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
            } else {
                ForEach(buckets) { bucket in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(bucket.label)
                            Spacer()
                            Text(String(format: "pred %.1f%% • actual %.1f%% • n=%d", bucket.averagePredicted, bucket.observedWinRate, bucket.count))
                        }
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(Color.green.opacity(0.55))
                                    .frame(width: geo.size.width * CGFloat(min(1.0, bucket.observedWinRate / 100.0)))
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var backtestCard: some View {
        let rows = PerformanceStore.backtestSummaries()

        return VStack(alignment: .leading, spacing: 8) {
            Text("RECORDED-HISTORY BACKTEST")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.5))

            Text("Replays only predictions SlipRadar actually recorded going forward; it does not invent historical lines.")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("n=\(row.sampleSize)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(row.winRate.map { String(format: "%.1f%%", $0) } ?? "—")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.green)
                    if let roi = row.roi {
                        Text(String(format: "%+.1f%% ROI", roi))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func breakdownCard(
        title: String,
        rows: [(label: String, count: Int, wins: Int, losses: Int, winRate: Double?)]
    ) -> some View {
        let visible = rows.filter { $0.count > 0 }

        return VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.5))

            if visible.isEmpty {
                Text("No settled results yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(Array(visible.prefix(12).enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(row.wins)-\(row.losses)")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(row.winRate.map { String(format: "%.1f%%", $0) } ?? "—")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.green)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func performanceCard(_ pick: TrackedPick) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pick.trackingOrigin ?? "LEG")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white.opacity(0.45))

                Text(pick.verdict)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(signalColor(pick.verdict))

                Text(pick.title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()

                Text(pick.outcome.rawValue.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(outcomeColor(pick.outcome))
            }

            Text("\(pick.sport ?? "Unknown") • \(pick.event) • \(pick.market)")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 7) {
                if let p = pick.estimatedProbability {
                    Text(String(format: "%.1f%% model", p))
                }
                if let edge = pick.estimatedEdge {
                    Text(String(format: "• edge %+.1f", edge))
                }
                if let odds = pick.odds {
                    Text("• \(odds)")
                }
                if let book = pick.entryBook {
                    Text("• \(book)")
                }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.43))

            if let closing = pick.lastSeenFairProbability {
                Text(String(
                    format: "Latest fair %.1f%%%@",
                    closing,
                    pick.marketProbability.map { String(format: " • CLV est. %+.1f pts", closing - $0) } ?? ""
                ))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.43))
            }

            Text("Model \(pick.modelVersion ?? "legacy") • \(pick.addedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.32))

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
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
    }

    private var sourceHealthItems: [SourceHealthItem] {
        var items: [SourceHealthItem] = []

        items.append(SourceHealthItem(
            id: "public",
            name: "Public betting boards",
            state: !loadingSources.isEmpty ? .loading : publicBoard.isEmpty ? .failed : .healthy,
            detail: !loadingSources.isEmpty ? "Loading Action/DraftKings public pages." : "\(publicBoard.count) parsed public lines.",
            lastUpdated: lastUpdated
        ))

        let liveCount = selectedSport == .all ? allBoard.count : liveTeamConsensus.count
        let liveError = selectedSport == .all ? allBoardError : liveTeamError
        items.append(SourceHealthItem(
            id: "live",
            name: "Multi-book live odds",
            state: !liveConfigured ? .off :
                (selectedSport == .all ? allBoardLoading : liveTeamLoading) ? .loading :
                liveCount > 0 ? .healthy : liveError == nil ? .limited : .failed,
            detail: !liveConfigured ? "No API key connected." :
                liveCount > 0 ? "\(liveCount) current outcomes/lines loaded." :
                (liveError ?? "No live lines returned."),
            lastUpdated: lastUpdated
        ))

        let resolved = teamProjectionsForCurrentSport
        items.append(SourceHealthItem(
            id: "stats",
            name: "Independent team stats",
            state: !teamProjectionLoading.isEmpty ? .loading :
                resolved > 0 ? (teamModelFailures.isEmpty ? .healthy : .limited) :
                teamModelAttempts > 0 ? .failed : .limited,
            detail: "\(resolved) models resolved • \(teamModelFailures.count) failed • \(teamModelAttempts) attempts.",
            lastUpdated: lastUpdated
        ))

        items.append(SourceHealthItem(
            id: "props",
            name: "Player game logs",
            state: selectedSport == .all ? .off :
                !propProjectionLoading.isEmpty ? .loading :
                !propProjections.isEmpty ? .healthy :
                props.isEmpty ? .limited : .failed,
            detail: selectedSport == .all ? "Choose a sport for player props." :
                "\(propProjections.count) player projections from \(props.count) parsed props.",
            lastUpdated: lastUpdated
        ))

        items.append(SourceHealthItem(
            id: "injury",
            name: "Injury / lineup context",
            state: selectedSport == .all ? .limited : contextLoaded ? .healthy : .limited,
            detail: selectedSport == .all ? "Loaded on sport-specific views / prop Deep Check." :
                contextLoaded ? "Public injury page loaded; Deep Check adds event roster validation." : "Public injury page unavailable.",
            lastUpdated: lastUpdated
        ))

        items.append(SourceHealthItem(
            id: "event",
            name: "Venue / weather context",
            state: contextLoadingSports.isEmpty ? (currentContextCount > 0 ? .healthy : .limited) : .loading,
            detail: "\(currentContextCount) current event contexts loaded; outdoor totals use weather only as a small modifier.",
            lastUpdated: lastUpdated
        ))

        items.append(SourceHealthItem(
            id: "alerts",
            name: "Watch alerts",
            state: SlipRadarNotifications.enabled ? .healthy : .off,
            detail: SlipRadarNotifications.enabled ? "Meaningful local alerts enabled." : "Alerts disabled; Watch still updates in-app on refresh.",
            lastUpdated: nil
        ))

        return items
    }

    private func healthCard(_ item: SourceHealthItem) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(healthColor(item.state))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(item.state.rawValue)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(healthColor(item.state))
                }

                Text(item.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sectionLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white.opacity(0.82))
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func compactNotice(_ title: String, _ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
    }

    private func loadingCard(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(.green).scaleEffect(1.1)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
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

    private func inlineLoading(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().tint(.green).scaleEffect(0.8)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func rankBadge(_ rank: Int) -> some View {
        Text("#\(rank)")
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: Capsule())
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

    private func signalColor(_ signal: String) -> Color {
        if signal == PickVerdict.lock.rawValue { return .green }
        if signal == PickVerdict.strong.rawValue { return .green.opacity(0.7) }
        if signal == PickVerdict.consider.rawValue { return .orange }
        return .red.opacity(0.8)
    }

    private func liveStatusBadge(_ status: LiveLineStatus) -> some View {
        Text(status.rawValue)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(status == .live ? Color.green : status == .mismatch ? Color.red : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.055), in: Capsule())
    }

    private func statusChip(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(active ? .black : .white.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(active ? Color.green : Color.white.opacity(0.07), in: Capsule())
    }

    private func watchButton(isWatched: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: isWatched ? "eye.fill" : "eye")
                Text(isWatched ? "Watching" : "Watch")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isWatched ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isWatched ? Color.green : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private func addButton(
        title: String,
        isAdded: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(isAdded ? "Added ✓" : disabled ? "Slip full" : title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isAdded ? .black : disabled ? .orange : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isAdded ? Color.green : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        }
        .disabled(disabled)
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

    private func outcomeColor(_ outcome: PickOutcome) -> Color {
        switch outcome {
        case .pending: return .white.opacity(0.45)
        case .win: return .green
        case .loss: return .red
        case .push: return .orange
        }
    }

    private func healthColor(_ state: SourceHealthState) -> Color {
        switch state {
        case .healthy: return .green
        case .limited, .loading: return .orange
        case .failed: return .red
        case .off: return .white.opacity(0.35)
        }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            Text("Stats create the opinion → live books challenge it → availability/context gate it → tracked results calibrate it.")
            Text("MODEL %, FAIR %, EDGE and EV are estimates, not guarantees. PASS can still rank #1 when the board is weak.")
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.32))
        .padding(.top, 12)
    }

    private var maxSlipLegs: Int {
        let stored = UserDefaults.standard.integer(forKey: "SlipRadar.maxSlipLegs.v10")
        return stored == 0 ? 4 : stored
    }

    private var dailyRiskUnits: Double {
        let stored = UserDefaults.standard.double(forKey: "SlipRadar.dailyRiskUnits.v10")
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

    private var teamProjectionsForCurrentSport: Int {
        if selectedSport == .all {
            return teamProjections.keys.filter { !$0.hasPrefix("All|") }.count
        }
        return teamProjections.keys.filter { $0.hasPrefix(selectedSport.rawValue + "|") }.count
    }

    private var currentContextCount: Int {
        if selectedSport == .all {
            return eventContextsBySport.values.reduce(0) { $0 + $1.count }
        }
        return eventContextsBySport[selectedSport]?.count ?? 0
    }

    private func projectionKey(_ sport: SportFilter, _ matchup: String) -> String {
        "\(sport.rawValue)|\(MarketKey.normalized(matchup))"
    }

    private func propKey(_ sport: SportFilter, _ prop: PropPick) -> String {
        "\(sport.rawValue)|\(prop.id)"
    }

    private func liveConsensus(for sport: SportFilter) -> [LiveMarketConsensus] {
        if selectedSport == .all {
            return allLiveBySport[sport] ?? []
        }
        return sport == selectedSport ? liveTeamConsensus : []
    }

    private func betSlipID(_ sport: SportFilter, _ bet: PopularBet) -> String {
        [sport.rawValue, bet.source.rawValue, bet.matchup, bet.market, bet.side].joined(separator: "|")
    }

    private func toggleBet(_ item: ScoredBet) {
        let bet = item.bet
        let report = item.report
        let id = betSlipID(item.sport, bet)

        if slip.contains(where: { $0.id == id }) {
            slip.removeAll { $0.id == id }
            SlipStore.save(slip)
            return
        }

        guard !slipIsAtLimit else { return }

        let live = LiveOddsService.matchConsensus(for: bet, in: liveConsensus(for: item.sport))
        let leg = SlipLeg(
            id: id,
            title: bet.side,
            subtitle: "\(bet.matchup) • \(bet.market)",
            source: bet.source.rawValue,
            signal: report.verdict.rawValue,
            sport: item.sport.rawValue,
            event: bet.matchup,
            market: bet.market,
            odds: live?.bestOdds ?? bet.odds,
            bestBook: live?.bestBook,
            probability: report.modelProbability,
            marketProbability: report.fairProbability,
            expectedValuePercent: report.expectedValuePercent,
            evidenceScore: report.evidenceScore,
            playerName: nil,
            threshold: nil,
            direction: nil,
            modelVersion: ModelVersion.current,
            addedAt: Date()
        )

        slip.append(leg)
        SlipStore.save(slip)
        PerformanceStore.track(leg)
        performanceToken = UUID()
    }

    private func toggleProp(_ item: ScoredProp) {
        let prop = item.prop
        let report = item.report
        let key = propKey(item.sport, prop)

        if slip.contains(where: { $0.id == prop.id }) {
            slip.removeAll { $0.id == prop.id }
            SlipStore.save(slip)
            return
        }

        guard !slipIsAtLimit else { return }

        let verification = propVerifications[key]
        let leg = SlipLeg(
            id: prop.id,
            title: prop.line,
            subtitle: "\(prop.event) • \(prop.market)",
            source: prop.source,
            signal: report.verdict.rawValue,
            sport: item.sport.rawValue,
            event: prop.event,
            market: prop.market,
            odds: verification?.bestOdds ?? prop.odds,
            bestBook: verification?.bestBook,
            probability: report.modelProbability,
            marketProbability: report.fairProbability,
            expectedValuePercent: report.expectedValuePercent,
            evidenceScore: report.evidenceScore,
            playerName: prop.playerName.isEmpty ? nil : prop.playerName,
            threshold: prop.threshold,
            direction: prop.direction,
            modelVersion: ModelVersion.current,
            addedAt: Date()
        )

        slip.append(leg)
        SlipStore.save(slip)
        PerformanceStore.track(leg)
        performanceToken = UUID()
    }

    private func toggleWatch(_ item: ScoredBet) {
        let bet = item.bet
        let live = LiveOddsService.matchConsensus(for: bet, in: liveConsensus(for: item.sport))
        let watch = WatchItem(
            id: WatchlistStore.watchID(sport: item.sport, event: bet.matchup, market: bet.market, selection: bet.side),
            kind: .team,
            sport: item.sport,
            event: bet.matchup,
            market: bet.market,
            selection: bet.side,
            playerName: nil,
            threshold: nil,
            direction: nil,
            createdAt: Date(),
            lastVerdict: item.report.verdict,
            lastOdds: live?.bestOdds ?? bet.odds,
            lastBook: live?.bestBook,
            lastModelProbability: item.report.modelProbability,
            lastFairProbability: item.report.fairProbability,
            lastLineStatus: item.report.liveStatus,
            lastUpdated: Date()
        )
        WatchlistStore.toggle(watch)
        watchToken = UUID()
    }

    private func toggleWatch(_ item: ScoredProp) {
        let prop = item.prop
        let verification = propVerifications[propKey(item.sport, prop)]
        let watch = WatchItem(
            id: WatchlistStore.watchID(sport: item.sport, event: prop.event, market: prop.market, selection: prop.line),
            kind: .prop,
            sport: item.sport,
            event: prop.event,
            market: prop.market,
            selection: prop.line,
            playerName: prop.playerName.isEmpty ? nil : prop.playerName,
            threshold: prop.threshold,
            direction: prop.direction,
            createdAt: Date(),
            lastVerdict: item.report.verdict,
            lastOdds: verification?.bestOdds ?? prop.odds,
            lastBook: verification?.bestBook,
            lastModelProbability: item.report.modelProbability,
            lastFairProbability: item.report.fairProbability,
            lastLineStatus: item.report.liveStatus,
            lastUpdated: Date()
        )
        WatchlistStore.toggle(watch)
        watchToken = UUID()
    }

    private func refresh() {
        resultsBySource = [:]
        props = []
        loadingSources = Set(BetSource.publicFeeds)
        loadingProps = selectedSport != .all
        contextText = ""
        contextLoaded = selectedSport == .all

        liveTeamConsensus = []
        liveTeamError = nil
        allLiveBySport = [:]
        allBoard = []
        allBoardError = nil

        teamProjections = [:]
        teamProjectionLoading = []
        teamModelAttempts = 0
        teamModelFailures = [:]

        propProjections = [:]
        propProjectionLoading = []
        propVerifications = [:]
        propVerificationLoading = []
        propAvailability = [:]

        eventContextsBySport = [:]
        contextLoadingSports = []

        apiKey = SecretStore.loadOddsAPIKey()
        refreshToken = UUID()
        lastUpdated = Date()

        refreshLiveLayers()

        if selectedSport != .all {
            loadEventContexts(for: [selectedSport])
        }
    }

    private func refreshLiveLayers() {
        guard liveConfigured else {
            liveTeamLoading = false
            allBoardLoading = false
            liveTeamConsensus = []
            allBoard = []
            return
        }

        let key = apiKey

        if selectedSport == .all {
            allBoardLoading = true
            allBoardError = nil

            Task {
                do {
                    let boards = try await LiveOddsService.fetchAllActiveTeamBoards(apiKey: key)
                    let bets = boards.flatMap { sport, consensus in
                        LiveOddsService.makeBets(from: consensus, sport: sport)
                    }

                    await MainActor.run {
                        allLiveBySport = boards
                        allBoard = bets
                        allBoardLoading = false
                        lastUpdated = Date()

                        scheduleTeamProjectionLoad()
                        loadEventContexts(for: Array(boards.keys))
                        refreshTrackedMarkets()
                        updateTrackingAndWatchlist()
                    }
                } catch {
                    await MainActor.run {
                        allBoard = []
                        allLiveBySport = [:]
                        allBoardLoading = false
                        allBoardError = error.localizedDescription
                    }
                }
            }
        } else {
            liveTeamLoading = true
            liveTeamError = nil
            let sport = selectedSport

            Task {
                do {
                    let result = try await LiveOddsService.fetchTeamConsensus(sport: sport, apiKey: key)
                    await MainActor.run {
                        if selectedSport == sport {
                            liveTeamConsensus = result
                            liveTeamLoading = false
                            lastUpdated = Date()
                            refreshTrackedMarkets()
                            updateTrackingAndWatchlist()
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
    }

    private func handleText(_ text: String, source: BetSource) {
        var parsed = BetTextParser.parse(text, source: source)
        if selectedSport != .all {
            parsed = parsed.map { bet in
                var copy = bet
                copy.sport = selectedSport
                return copy
            }
        }

        DispatchQueue.main.async {
            resultsBySource[source] = parsed
            MarketHistoryStore.record(bets: parsed)
            loadingSources.remove(source)
            lastUpdated = Date()

            if selectedSport != .all {
                scheduleTeamProjectionLoad()
            }
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
        let sport = selectedSport
        var parsed = PropTextParser.parse(text)
        parsed = parsed.map { prop in
            var copy = prop
            copy.sport = sport
            return copy
        }

        DispatchQueue.main.async {
            props = parsed
            MarketHistoryStore.record(props: parsed)
            loadingProps = false
            lastUpdated = Date()
            schedulePropProjectionLoad(parsed, sport: sport)
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

    private func scheduleTeamProjectionLoad() {
        let candidates: [(SportFilter, String)] = {
            let unique = Dictionary(grouping: board) { bet in
                projectionKey(bet.sport ?? selectedSport, bet.matchup)
            }
            return unique.values.compactMap { group in
                guard let bet = group.first else { return nil }
                let sport = bet.sport ?? selectedSport
                guard sport != .all, sport != .soccer else { return nil }
                let key = projectionKey(sport, bet.matchup)
                guard teamProjections[key] == nil, !teamProjectionLoading.contains(key) else { return nil }
                return (sport, bet.matchup)
            }
        }()

        let limit = selectedSport == .all ? 36 : 14
        let work = Array(candidates.prefix(limit))
        guard !work.isEmpty else { return }

        for (sport, matchup) in work {
            teamProjectionLoading.insert(projectionKey(sport, matchup))
            teamModelAttempts += 1
        }

        Task {
            await withTaskGroup(of: (SportFilter, String, TeamProjection?).self) { group in
                for (sport, matchup) in work {
                    group.addTask {
                        let projection = await StatProjectionService.teamProjection(for: matchup, sport: sport)
                        return (sport, matchup, projection)
                    }
                }

                for await (sport, matchup, projection) in group {
                    await MainActor.run {
                        let key = projectionKey(sport, matchup)
                        teamProjectionLoading.remove(key)

                        if let projection {
                            teamProjections[key] = projection
                            teamModelFailures.removeValue(forKey: "\(sport.rawValue) • \(matchup)")
                        } else {
                            teamModelFailures["\(sport.rawValue) • \(matchup)"] =
                                "Team IDs/schedule samples could not produce a verified projection."
                        }
                    }
                }
            }

            await MainActor.run {
                updateTrackingAndWatchlist()
            }
        }
    }

    private func schedulePropProjectionLoad(_ parsed: [PropPick], sport: SportFilter) {
        guard sport.supportsPlayerGameLogs else { return }

        let candidates = Array(parsed.prefix(24)).filter { prop in
            let key = propKey(sport, prop)
            return propProjections[key] == nil && !propProjectionLoading.contains(key)
        }
        guard !candidates.isEmpty else { return }

        candidates.forEach { propProjectionLoading.insert(propKey(sport, $0)) }

        Task {
            await withTaskGroup(of: (String, StatProjection?).self) { group in
                for prop in candidates {
                    group.addTask {
                        let projection = await StatProjectionService.playerProjection(for: prop, sport: sport)
                        return (propKey(sport, prop), projection)
                    }
                }

                for await (key, projection) in group {
                    await MainActor.run {
                        propProjectionLoading.remove(key)
                        if let projection {
                            propProjections[key] = projection
                        }
                    }
                }
            }

            await MainActor.run {
                updateTrackingAndWatchlist()
            }
        }
    }

    private func deepCheck(_ item: ScoredProp) {
        let sport = item.sport
        let prop = item.prop
        let key = propKey(sport, prop)
        guard !propVerificationLoading.contains(key) else { return }

        propVerificationLoading.insert(key)

        Task {
            let existingProjection = propProjections[key]

            async let availabilityTask = EventContextService.playerAvailability(
                playerName: prop.playerName,
                event: prop.event,
                sport: sport
            )

            let projection: StatProjection?
            if let existingProjection {
                projection = existingProjection
            } else {
                projection = await StatProjectionService.playerProjection(for: prop, sport: sport)
            }

            let verification: LivePropVerification?
            if liveConfigured {
                verification = try? await LiveOddsService.verifyProp(prop, sport: sport, apiKey: apiKey)
            } else {
                verification = nil
            }

            let availability = await availabilityTask

            await MainActor.run {
                if let projection {
                    propProjections[key] = projection
                }
                propAvailability[key] = availability

                if let verification {
                    propVerifications[key] = verification
                    PerformanceStore.updateLatestMatching(
                        sport: sport,
                        event: prop.event,
                        market: prop.market,
                        title: prop.line,
                        odds: verification.bestOdds,
                        book: verification.bestBook,
                        fairProbability: verification.fairProbability,
                        observedAt: verification.checkedAt
                    )
                }

                propVerificationLoading.remove(key)
                performanceToken = UUID()
                updateTrackingAndWatchlist()
            }
        }
    }

    private func loadEventContexts(for sports: [SportFilter]) {
        let unique = Array(Set(sports.filter { $0 != .all }))
        guard !unique.isEmpty else { return }

        for sport in unique where !contextLoadingSports.contains(sport) {
            contextLoadingSports.insert(sport)

            Task {
                let contexts = (try? await EventContextService.fetchContexts(sport: sport)) ?? []
                await MainActor.run {
                    eventContextsBySport[sport] = contexts
                    contextLoadingSports.remove(sport)
                }
            }
        }
    }

    private func refreshTrackedMarkets() {
        for item in scoredBets {
            let live = LiveOddsService.matchConsensus(for: item.bet, in: liveConsensus(for: item.sport))
            PerformanceStore.updateLatestMatching(
                sport: item.sport,
                event: item.bet.matchup,
                market: item.bet.market,
                title: item.bet.side,
                odds: live?.bestOdds ?? item.bet.odds,
                book: live?.bestBook,
                fairProbability: item.report.fairProbability,
                observedAt: live?.lastUpdated ?? Date()
            )
        }
        performanceToken = UUID()
    }

    private func updateTrackingAndWatchlist() {
        var alerts: [WatchAlert] = []

        for item in scoredBets {
            let live = LiveOddsService.matchConsensus(for: item.bet, in: liveConsensus(for: item.sport))

            PerformanceStore.trackRecommendation(
                sport: item.sport,
                title: item.bet.side,
                event: item.bet.matchup,
                market: item.bet.market,
                source: item.bet.source.rawValue,
                odds: live?.bestOdds ?? item.bet.odds,
                bestBook: live?.bestBook,
                modelProbability: item.report.modelProbability,
                marketProbability: item.report.fairProbability,
                edge: item.report.estimatedEdge,
                evidenceScore: item.report.evidenceScore,
                verdict: item.report.verdict,
                playerName: nil,
                threshold: nil,
                direction: nil
            )

            alerts.append(contentsOf: WatchlistStore.update(
                bet: item.bet,
                sport: item.sport,
                report: item.report,
                bestBook: live?.bestBook
            ))
        }

        for item in scoredProps {
            let verification = propVerifications[propKey(item.sport, item.prop)]

            PerformanceStore.trackRecommendation(
                sport: item.sport,
                title: item.prop.line,
                event: item.prop.event,
                market: item.prop.market,
                source: item.prop.source,
                odds: verification?.bestOdds ?? item.prop.odds,
                bestBook: verification?.bestBook,
                modelProbability: item.report.modelProbability,
                marketProbability: item.report.fairProbability,
                edge: item.report.estimatedEdge,
                evidenceScore: item.report.evidenceScore,
                verdict: item.report.verdict,
                playerName: item.prop.playerName.isEmpty ? nil : item.prop.playerName,
                threshold: item.prop.threshold,
                direction: item.prop.direction
            )

            alerts.append(contentsOf: WatchlistStore.update(
                prop: item.prop,
                sport: item.sport,
                report: item.report,
                bestOdds: verification?.bestOdds,
                bestBook: verification?.bestBook
            ))
        }

        if !alerts.isEmpty {
            SlipRadarNotifications.deliver(alerts)
        }

        performanceToken = UUID()
        watchToken = UUID()
    }

    @MainActor
    private func autoGradePending() async {
        guard !autoGrading else { return }
        let pending = PerformanceStore.load().filter { $0.outcome == .pending }
        guard !pending.isEmpty else { return }

        autoGrading = true
        defer {
            autoGrading = false
            performanceToken = UUID()
        }

        for pick in pending.prefix(30) {
            if let outcome = await ResultAutoGrader.grade(pick) {
                PerformanceStore.setOutcome(
                    id: pick.id,
                    outcome: outcome,
                    source: pick.playerName == nil ? "Auto • ESPN final score" : "Auto • ESPN game log"
                )
            }
        }
    }

    private func scoredBetSort(_ lhs: ScoredBet, _ rhs: ScoredBet) -> Bool {
        let l = lhs.report
        let r = rhs.report

        if l.verdict.rank != r.verdict.rank { return l.verdict.rank > r.verdict.rank }

        let lEdge = l.estimatedEdge ?? -999
        let rEdge = r.estimatedEdge ?? -999
        if abs(lEdge - rEdge) > 0.01 { return lEdge > rEdge }

        if l.liveStatus.rank != r.liveStatus.rank { return l.liveStatus.rank > r.liveStatus.rank }
        if l.dataQuality != r.dataQuality { return l.dataQuality > r.dataQuality }
        return l.evidenceScore > r.evidenceScore
    }

    private func scoredPropSort(_ lhs: ScoredProp, _ rhs: ScoredProp) -> Bool {
        let l = lhs.report
        let r = rhs.report

        if l.verdict.rank != r.verdict.rank { return l.verdict.rank > r.verdict.rank }

        let lEdge = l.estimatedEdge ?? -999
        let rEdge = r.estimatedEdge ?? -999
        if abs(lEdge - rEdge) > 0.01 { return lEdge > rEdge }

        if l.liveStatus.rank != r.liveStatus.rank { return l.liveStatus.rank > r.liveStatus.rank }
        if l.dataQuality != r.dataQuality { return l.dataQuality > r.dataQuality }
        return l.evidenceScore > r.evidenceScore
    }
}
