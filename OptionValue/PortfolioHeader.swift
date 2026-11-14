import SwiftUI

/// Summary tiles: market value, unrealized P&L, cost basis and market status.
/// Four tiles in a row, or 2 × 2 when the page is narrow. Totals only include priced positions.
struct PortfolioHeader: View {
    let positions: [Position]

    @Environment(MarketStore.self) private var store

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                marketValueTile
                profitTile
                costTile
                marketTile
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    marketValueTile
                    profitTile
                }
                GridRow {
                    costTile
                    marketTile
                }
            }
        }
    }

    // MARK: Tiles

    private var marketValueTile: some View {
        SummaryTile(label: "Market value", value: money(totalValue), detail: pricedText)
    }

    private var profitTile: some View {
        SummaryTile(label: "Unrealized P&L", value: signedMoney(totalProfit),
                    detail: signedPercent(profitFraction), color: Theme.pnlColor(totalProfit))
    }

    private var costTile: some View {
        SummaryTile(label: "Cost basis", value: money(totalCost),
                    detail: contractsText(pricedPositions.reduce(0) { $0 + $1.contracts }))
    }

    private var marketTile: some View {
        SummaryTile(label: "Market", value: store.session.label, detail: updatedText, dot: sessionColor)
    }

    // MARK: Totals (priced positions only)

    private var pricedPositions: [Position] {
        positions.filter { store.marketValue(for: $0) != nil }
    }

    /// Nil until at least one position has a value.
    private var totalValue: Double? {
        let values = positions.compactMap { store.marketValue(for: $0) }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var totalCost: Double? {
        pricedPositions.isEmpty ? nil : pricedPositions.reduce(0) { $0 + $1.costBasis }
    }

    private var totalProfit: Double? {
        guard let totalValue, let totalCost else { return nil }
        return totalValue - totalCost
    }

    private var profitFraction: Double? {
        guard let totalProfit, let totalCost, totalCost > 0 else { return nil }
        return totalProfit / totalCost
    }

    // MARK: Detail lines

    /// "3 positions", "1 position", or "2 of 3 priced" while some have no value yet.
    private var pricedText: String {
        let priced = pricedPositions.count
        if priced < positions.count {
            return "\(priced) of \(positions.count) priced"
        }
        return positions.count == 1 ? "1 position" : "\(positions.count) positions"
    }

    private var updatedText: String {
        if let lastUpdated = store.lastUpdated {
            return "Updated \(timeText(lastUpdated)) ET"
        }
        return store.isRefreshing ? "Updating…" : "Not updated yet"
    }

    /// Green while the regular session is open, orange in pre-market and after hours, gray when closed.
    private var sessionColor: Color {
        switch store.session {
        case .regular: .green
        case .pre, .post: .orange
        case .closed: .secondary
        }
    }
}

/// One summary card: a quiet label, a big value and a caption detail line.
/// `color` tints the value and detail (P&L); `dot` puts a status dot before the value (market session).
private struct SummaryTile: View {
    let label: String
    let value: String
    let detail: String
    var color: Color?
    var dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 8, height: 8)
                }
                Text(value)
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(.default, value: value)
            }
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(color ?? .secondary)
                .lineLimit(1)
        }
        // The ideal width decides when the row wraps to 2 × 2: four tiles need about 684 pt.
        .frame(minWidth: 0, idealWidth: 130, maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}
