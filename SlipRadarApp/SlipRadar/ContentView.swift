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
    @State private var contextText = ""
    @State private var contextLoaded = false
    @State private var performanceToken = UUID()

    private var board: [PopularBet] {
        resultsBySource.values.flatMap { $0 }
    }

    private var scoredBets: [ScoredBet] {
        board
            .map { bet in
                ScoredBet(
                    bet: bet,
                    report: DecisionEngine.report(for: bet, board: board)
                )
            }
            .sorted { lhs, rhs in
                if lhs.report.verdict.rank == rhs.report.verdict.rank {
                    return lhs.report.evidenceScore > rhs.report.evidenceScore
                }
                return lhs.report.verdict.rank > rhs.report.verdict.rank
            }
    }

    private var scoredProps: [ScoredProp] {
        props
            .map { prop in
                ScoredProp(
                    prop: prop,
                    report: DecisionEngine.report(for: prop, contextText: contextText)
                )
            }
            .sorted { lhs, rhs in
                if lhs.report.verdict.rank == rhs.report.verdict.rank {
                    return lhs.report.evidenceScore > rhs.report.evidenceScore
                }
                return lhs.report.verdict.rank > rhs.report.verdict.rank
            }
    }

    private var lockPicks: [ScoredBet] {
        scoredBets.filter { $0.report.verdict == .lock }
    }

    private var teamPicks: [ScoredBet] {
        scoredBets.filter { item in
            let market = item.bet.market.lowercased()
            let isTeamMarket = market.contains("moneyline") || market.contains("spread")
            return isTeamMarket && item.report.verdict != .pass
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

                Text("DECISION ENGINE • v0.8")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.3)
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
                        .foregroundStyle(selectedSection == section ? .black : .white.opacity(0.7))
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
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var locksSection: some View {
        statusPanel

        if !loadingSources.isEmpty && lockPicks.isEmpty {
            loadingCard("Building the decision board…")
        } else if lockPicks.isEmpty {
            emptyCard(
                "PASS — NO VERIFIED LOCKS",
                "Nothing met v0.8's top-tier requirements. SlipRadar would rather pass than manufacture a lock."
            )
        } else {
            ForEach(lockPicks.prefix(12)) { item in
                betCard(item)
            }
        }
    }

    @ViewBuilder
    private var teamsSection: some View {
        statusPanel

        if !loadingSources.isEmpty && teamPicks.isEmpty {
            loadingCard("Scoring whole-team markets…")
        } else if teamPicks.isEmpty {
            emptyCard(
                "NO QUALIFIED TEAM PICKS",
                "No current moneyline or spread has enough verified evidence yet."
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
            loadingCard("Scoring individual player props…")
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
                "Add game, team, or player picks. SlipRadar will estimate combined probability and flag same-event correlation."
            )
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

    @ViewBuilder
    private var performanceSection: some View {
        performanceSummaryCard

        if trackedPicks.isEmpty {
            emptyCard(
                "NO TRACKED PICKS YET",
                "Adding a pick to My Slip starts a local performance record so the model can be audited instead of trusted blindly."
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
                Text(loadingSources.isEmpty ? "\(scoredBets.count) markets scored" : "Scanning sportsbook boards…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Action Network • DraftKings • line history")
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
                Text(loadingProps ? "Loading player props…" : "\(scoredProps.count) props scored")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text(contextLoaded ? "Odds + public injury context loaded" : "Odds loaded • context limited")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(14)
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

    private func betCard(_ item: ScoredBet) -> some View {
        let bet = item.bet
        let report = item.report

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                verdictBadge(report.verdict)

                Text(bet.side)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()
                probabilityBlock(report)
            }

            Text(bet.matchup)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            HStack(spacing: 7) {
                Text(bet.source == .draftKings ? "DraftKings split feed" : bet.source.rawValue)
                Text("•")
                Text(bet.market)
                Text("•")
                Text("Evidence \(report.evidenceScore)/100")
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))

            evidenceBox(report)

            if report.verdict != .pass {
                addButton(
                    title: "Add to My Slip",
                    isAdded: slip.contains(where: { $0.id == betSlipID(bet) })
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

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                verdictBadge(report.verdict)

                Text(prop.market)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()
                probabilityBlock(report)
            }

            Text(prop.line)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text(prop.event)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            HStack(spacing: 7) {
                Text(prop.source)
                Text("•")
                Text(prop.eventDate)
                Text("•")
                Text("Evidence \(report.evidenceScore)/100")
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))

            evidenceBox(report)

            if report.verdict != .pass {
                addButton(
                    title: "Add Prop to My Slip",
                    isAdded: slip.contains(where: { $0.id == prop.id })
                ) {
                    toggleProp(prop, report: report)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
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

    @ViewBuilder
    private func probabilityBlock(_ report: DecisionReport) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let fair = report.fairProbability {
                Text(String(format: "%.1f%%", fair))
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color.green)
                Text("FAIR %")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            } else if let market = report.marketProbability {
                Text(String(format: "%.1f%%", market))
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color.green)
                Text("IMPLIED %")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                Text("—")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white.opacity(0.4))
                Text("NO PRICE")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
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

            ForEach(Array(report.reasons.prefix(4).enumerated()), id: \.offset) { _, reason in
                Text("• \(reason)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !report.risks.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))

                Text("WATCH OUT")
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
        let correlated = hasCorrelatedLegs

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MY SLIP")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(slip.count) LEGS")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color.green)
            }

            if let combined {
                Text(String(format: "Naive independent chance: %.2f%%", combined))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                if probabilities.count != slip.count {
                    Text("Some legs have no probability estimate, so the combined number is incomplete.")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            } else {
                Text("No probability estimate is available yet.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if correlated {
                Text("⚠️ Correlation warning: multiple legs are from the same event. Do not treat the multiplied probability as reliable.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if slip.count >= 2 {
                Text("No obvious same-event correlation detected. Independence is still an approximation.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
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
                        Text(String(format: "%.1f%%", probability))
                    }
                }
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

    private var performanceSummaryCard: some View {
        let summary = PerformanceStore.summary()

        return VStack(alignment: .leading, spacing: 8) {
            Text("MODEL SCORECARD")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)

            HStack(spacing: 18) {
                metric("TRACKED", "\(summary.totalTracked)")
                metric("SETTLED", "\(summary.settled)")

                if let winRate = summary.winRate {
                    metric("WIN RATE", String(format: "%.1f%%", winRate))
                }

                if let roi = summary.flatStakeROI {
                    metric("1U ROI", String(format: "%+.1f%%", roi))
                }
            }

            Text("Results are graded locally. This is forward performance tracking, not proof of future edge.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 4)
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
                    Text(String(format: "• %.1f%% est.", probability))
                }
                if let odds = pick.odds {
                    Text("• \(odds)")
                }
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.42))

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
            Text("FAIR % removes listed market vig when enough opposing prices are available. IMPLIED % does not.")
            Text("Evidence scores are decision-support signals, not guaranteed win probabilities. Verify the current line before wagering.")
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
            return
        }

        let leg = SlipLeg(
            id: id,
            title: bet.side,
            subtitle: "\(bet.matchup) • \(bet.market)",
            source: bet.source.rawValue,
            signal: report.verdict.rawValue,
            event: bet.matchup,
            market: bet.market,
            odds: bet.odds,
            probability: report.fairProbability ?? report.marketProbability,
            evidenceScore: report.evidenceScore
        )

        slip.append(leg)
        PerformanceStore.track(leg)
        performanceToken = UUID()
    }

    private func toggleProp(_ prop: PropPick, report: DecisionReport) {
        if slip.contains(where: { $0.id == prop.id }) {
            slip.removeAll { $0.id == prop.id }
            return
        }

        let leg = SlipLeg(
            id: prop.id,
            title: prop.line,
            subtitle: "\(prop.event) • \(prop.market)",
            source: prop.source,
            signal: report.verdict.rawValue,
            event: prop.event,
            market: prop.market,
            odds: prop.odds,
            probability: report.marketProbability,
            evidenceScore: report.evidenceScore
        )

        slip.append(leg)
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
        refreshToken = UUID()
    }

    private func handleText(_ text: String, source: BetSource) {
        let parsed = BetTextParser.parse(text, source: source)

        DispatchQueue.main.async {
            resultsBySource[source] = parsed
            MarketHistoryStore.record(bets: parsed)
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
            MarketHistoryStore.record(props: parsed)
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
}
