import SwiftData
import SwiftUI

/// The trailing inspector: the selected position's details, market data and scenarios.
struct PositionInspector: View {
    let position: Position?  // nil → "No position selected"
    @Binding var selectedScenario: Scenario.ID?
    let onEdit: (Position) -> Void
    let onDelete: (Position) -> Void

    @Environment(MarketStore.self) private var store
    @Environment(\.modelContext) private var context

    var body: some View {
        if let position {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    InspectorHeader(position: position, onEdit: onEdit, onDelete: onDelete)
                    MarketCard(position: position)
                    scenarios(position)
                }
                .padding(16)
            }
            .environment(\.timeZone, eastern)
        } else {
            ContentUnavailableView("No position selected", systemImage: "sidebar.trailing")
        }
    }

    // MARK: Scenarios

    private func scenarios(_ position: Position) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scenarios")
                    .font(.headline)
                Spacer()
                Button {
                    addScenario(to: position)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create a scenario at today’s price and volatility")
                .accessibilityIdentifier("newScenario")
            }
            NowRow(position: position)
            scenarioCards(position)
        }
    }

    @ViewBuilder private func scenarioCards(_ position: Position) -> some View {
        let scenarios = position.sortedScenarios
        if scenarios.isEmpty {
            Text("Create a scenario to see what this position would be worth at another price, date or volatility.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        ForEach(Array(scenarios.enumerated()), id: \.element.id) { index, scenario in
            ScenarioCard(scenario: scenario, position: position, color: Theme.scenarioColor(at: index),
                         isSelected: selectedScenario == scenario.id,
                         onSelect: { toggle(scenario) },
                         onDuplicate: { duplicate(scenario, in: position) },
                         onDelete: { delete(scenario, from: position) })
                .accessibilityIdentifier("scenarioCard-\(index)")
        }
    }

    // MARK: Actions

    /// Expands a collapsed scenario, or collapses the expanded one.
    private func toggle(_ scenario: Scenario) {
        selectedScenario = selectedScenario == scenario.id ? nil : scenario.id
    }

    /// A new scenario at today's price, now and today's IV, with an automatic title.
    private func addScenario(to position: Position) {
        let spot = store.underlyingPrice(for: position)?.value ?? position.strike
        let iv = store.impliedVolatility(for: position) ?? 0.5
        insert(Scenario(name: "", underlyingPrice: (spot * 100).rounded() / 100, date: .now,
                        ivPercent: (iv * 1000).rounded() / 10),
               into: position)
    }

    private func duplicate(_ scenario: Scenario, in position: Position) {
        insert(Scenario(name: "", underlyingPrice: scenario.underlyingPrice, date: scenario.date,
                        ivPercent: scenario.ivPercent),
               into: position)
    }

    /// Saves right away so the scenario's ID is permanent before it is selected.
    private func insert(_ scenario: Scenario, into position: Position) {
        context.insert(scenario)
        position.scenarios.append(scenario)
        try? context.save()
        selectedScenario = scenario.id
    }

    private func delete(_ scenario: Scenario, from position: Position) {
        selectedScenario = nil
        position.scenarios.removeAll { $0.id == scenario.id }
        context.delete(scenario)
        try? context.save()
    }
}

/// "98 days left", "1 day left", "Expires today" or "Expired".
private func daysLeftText(_ position: Position) -> String {
    let countdown = position.countdownText
    return countdown.first?.isNumber == true ? countdown + " left" : countdown
}

/// The position's title, expiration and size, with a menu to edit or delete it.
private struct InspectorHeader: View {
    let position: Position
    let onEdit: (Position) -> Void
    let onDelete: (Position) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(position.title)
                    .font(.title2.weight(.semibold))
                Text("\(position.longExpirationText) · \(daysLeftText(position))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            menu
        }
    }

    private var sizeText: String {
        "\(contractsText(position.contracts)) · avg \(price(position.averagePrice)) · cost \(money(position.costBasis))"
    }

    private var menu: some View {
        Menu {
            Button("Edit Position…") { onEdit(position) }
            Divider()
            Button("Delete Position…", role: .destructive) { onDelete(position) }
        } label: {
            Label("Position actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit or delete this position")
        .accessibilityIdentifier("positionActions")
    }
}

/// Today's market data for the position: prices, quote, IV and break-even. Without a live option quote
/// it shows only what the app can know, and the IV is a field the user fills in.
private struct MarketCard: View {
    let position: Position
    @Environment(MarketStore.self) private var store

    var body: some View {
        Group {
            if let quote = store.quote(for: position) {
                quoteStats(quote)
            } else {
                estimateStats
            }
        }
        .card()
    }

    /// With a live quote: three columns of stats, row gap 12. Built from columns rather than a `Grid` so
    /// that the columns share the width equally but one that needs more room can take it without
    /// truncating or pushing the card wider than the inspector.
    private func quoteStats(_ quote: OptionQuote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            column {
                underlying
                Stat("Bid × Ask", bidAskText(quote))
            }
            column {
                synthetic
                if let iv = quote.impliedVolatility {
                    Stat("Implied vol", percent(iv))
                } else {
                    ivField
                }
            }
            column {
                Stat("Last trade", price(quote.last))
                breakEven
            }
        }
    }

    /// Without a quote: the three stats the app can work out, then the user's own IV with a hint.
    private var estimateStats: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                underlying
                    .frame(maxWidth: .infinity, alignment: .leading)
                synthetic
                    .frame(maxWidth: .infinity, alignment: .leading)
                breakEven
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow(alignment: .bottom) {
                ivField
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Your estimate. Update it from your broker when it moves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridCellColumns(2)
            }
        }
    }

    private func column(@ViewBuilder _ stats: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stats()
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var underlying: some View {
        let spot = store.underlyingPrice(for: position)
        return Stat("Underlying", price(spot?.value)) {
            if spot?.source == .hyperliquid {
                Tag("HL")
            }
        }
    }

    private var synthetic: some View {
        Stat("Synthetic", price(store.syntheticValue(for: position)))
    }

    private var breakEven: some View {
        Stat("Break-even", price(position.breakEven))
    }

    /// The IV to use without a live one, typed as a percentage ("62.7%"). It is saved in `lastIV` when the
    /// user presses Return or leaves the field; clearing it (or a value that isn't positive) saves nil.
    private var ivField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Implied vol")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Implied vol", value: savedIV, format: percentFieldFormat, prompt: Text("e.g. 60"))
                .fieldStyle(width: 70)
                .accessibilityLabel("Implied volatility")
                .accessibilityIdentifier("positionIV")
                // A new field per position, so an unfinished edit is never saved to the next position.
                .id(position.id)
        }
    }

    private var savedIV: Binding<Double?> {
        Binding(get: { position.lastIV },
                set: { position.lastIV = ($0 ?? 0) > 0 ? $0 : nil })
    }

    private func bidAskText(_ quote: OptionQuote) -> String {
        guard quote.bid != nil || quote.ask != nil else { return "–" }
        return "\(price(quote.bid)) × \(price(quote.ask))"
    }
}

/// The position valued right now, above the saved scenarios. Not clickable.
private struct NowRow: View {
    let position: Position
    @Environment(MarketStore.self) private var store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Theme.now)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            VStack(alignment: .leading, spacing: 2) {
                Text("Now")
                    .font(.body.weight(.medium))
                Text(detailText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let profit {
                PnLStack(profit: profit, fraction: profit / position.costBasis)
            }
            // Keeps the P&L on the same trailing edge as the scenario cards, which end with a chevron.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .hidden()
        }
        .card(padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var profit: Double? {
        position.costBasis > 0 ? store.profit(for: position) : nil
    }

    /// "$42.83 · IV 62.7% · 98 days left", or why the position can't be valued yet (the price first).
    private var detailText: String {
        guard let spot = store.underlyingPrice(for: position)?.value else { return missingPriceText }
        guard let iv = store.impliedVolatility(for: position) else {
            return "Set an implied volatility above to value this position."
        }
        return "\(price(spot)) · IV \(percent(iv)) · \(daysLeftText(position))"
    }

    /// Without Alpaca keys and without a Hyperliquid symbol no price can come; otherwise one is on its way.
    private var missingPriceText: String {
        if store.hasAlpacaKeys || !position.hyperliquidSymbol.isEmpty {
            return "Waiting for a price."
        }
        return "No live price for \(position.underlying) — it isn’t listed on Hyperliquid. Alpaca keys add prices for any ticker; scenarios work either way."
    }

    private var spokenSummary: String {
        guard let profit else { return "Now, \(detailText)" }
        let word = profit < 0 ? "loss" : "gain"
        return "Now, \(detailText), \(word) \(money(abs(profit))), \(percent(abs(profit / position.costBasis)))"
    }
}
