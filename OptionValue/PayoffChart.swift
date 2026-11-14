import Charts
import SwiftUI

/// The chart card: the selected position's P&L by underlying price — now, in each scenario and at expiry.
struct PayoffChart: View {
    let position: Position?  // nil → "Select a position"
    let selectedScenario: Scenario.ID?

    var body: some View {
        Group {
            if let position {
                PayoffChartContent(position: position, selectedScenario: selectedScenario)
            } else {
                ContentUnavailableView("Select a position", systemImage: "chart.xyaxis.line")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

/// One line on the chart: its name, look and sampled P&L.
private struct Curve: Identifiable {
    let id: String
    let color: Color
    let lineWidth: CGFloat
    var dash: [CGFloat] = []
    let points: [PnLPoint]
}

/// The position's P&L in dollars at one underlying price.
private struct PnLPoint {
    let spot: Double
    let pnl: Double
}

/// One line of the hover tooltip.
private struct TooltipRow: Identifiable {
    let id: String
    let label: String
    let color: Color
    var dashed = false
    let pnl: Double
}

/// Header, legend and chart for one position.
private struct PayoffChartContent: View {
    @Environment(MarketStore.self) private var store
    let position: Position
    let selectedScenario: Scenario.ID?

    @State private var hoverPrice: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chart(curves)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("P&L by underlying price, \(position.title)")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("payoffChart")
    }

    // MARK: Header and legend

    /// Title and caption on the left, legend on the right; the legend moves under the title when narrow.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                titleBlock
                Spacer(minLength: 0)
                legend
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                legend
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("P&L by underlying price")
                .font(.headline)
            Text("\(position.title) · \(contractsText(position.contracts))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            if hasNowCurve {
                LegendItem(label: "Now", color: Theme.now)
            }
            ForEach(legendScenarios, id: \.id) { scenario in
                LegendItem(label: scenario.title, color: color(of: scenario))
            }
            if scenarios.count > legendScenarios.count {
                Text("+\(scenarios.count - legendScenarios.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LegendItem(label: "At expiry", color: Theme.expiry, dashed: true)
        }
    }

    /// At most three scenarios; the selected one is always among them.
    private var legendScenarios: [Scenario] {
        let firstThree = Array(scenarios.prefix(3))
        guard let selected, !firstThree.contains(where: { $0.id == selected.id }) else { return firstThree }
        return Array(scenarios.prefix(2)) + [selected]
    }

    // MARK: Chart

    private func chart(_ curves: [Curve]) -> some View {
        let bounds = pnlBounds(curves)
        // Empty bands above and below the curves keep the "Now" and "Strike" labels clear of every line.
        let band = (bounds.upperBound - bounds.lowerBound) * 0.12
        return Chart {
            RuleMark(y: .value("P&L", 0))
                .foregroundStyle(Color.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))

            strikeRule(bounds)
            if let spot {
                nowRule(spot, bounds)
            }

            ForEach(curves) { curve in
                ForEach(curve.points, id: \.spot) { point in
                    LineMark(x: .value("Underlying price", point.spot),
                             y: .value("P&L", point.pnl),
                             series: .value("Curve", curve.id))
                        .foregroundStyle(curve.color)
                        .lineStyle(StrokeStyle(lineWidth: curve.lineWidth, lineCap: .round,
                                               lineJoin: .round, dash: curve.dash))
                }
            }

            ForEach(scenarios, id: \.id) { scenario in
                scenarioPoint(scenario)
            }

            if let hoverPrice {
                hoverRule(hoverPrice)
            }
        }
        .chartXScale(domain: priceRange)
        .chartYScale(domain: (bounds.lowerBound - band)...(bounds.upperBound + band))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Self.gridColor)
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Self.gridColor)
                AxisValueLabel(format: .currency(code: "USD").locale(usLocale).precision(.fractionLength(0)))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Self.gridColor)
                AxisValueLabel(format: .currency(code: "USD").locale(usLocale).notation(.compactName))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            hoverArea(proxy)
        }
    }

    /// Dotted line at the strike, labelled in the empty band under the curves.
    private func strikeRule(_ bounds: ClosedRange<Double>) -> some ChartContent {
        RuleMark(x: .value("Strike", position.strike),
                 yStart: .value("P&L", bounds.lowerBound), yEnd: .value("P&L", bounds.upperBound))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
            .annotation(position: .bottom, spacing: 4) {
                Text("Strike \(position.strikeText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.secondary)
            }
    }

    /// Dashed line at today's underlying price, labelled in the empty band above the curves.
    private func nowRule(_ spot: Double, _ bounds: ClosedRange<Double>) -> some ChartContent {
        RuleMark(x: .value("Now", spot),
                 yStart: .value("P&L", bounds.lowerBound), yEnd: .value("P&L", bounds.upperBound))
            .foregroundStyle(Color.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .annotation(position: .top, spacing: 4) {
                Text("Now \(price(spot))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.secondary)
            }
    }

    /// A dot at the scenario's price; the selected one also shows its P&L.
    private func scenarioPoint(_ scenario: Scenario) -> some ChartContent {
        let pnl = scenarioPnL(scenario, at: scenario.underlyingPrice)
        let isSelected = scenario.id == selectedScenario
        return PointMark(x: .value("Underlying price", scenario.underlyingPrice), y: .value("P&L", pnl))
            .foregroundStyle(color(of: scenario).opacity(isSelected ? 1 : 0.55))
            .symbolSize(70)
            .annotation(position: labelSide, spacing: 4) {
                if isSelected {
                    Text(signedMoney(pnl))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.pnlColor(pnl))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Self.labelBackground, in: Capsule())
                }
            }
    }

    /// The selected scenario's P&L sits above the curve on its falling side, where no other curve passes:
    /// up-left of the dot for calls (curves rise to the right), up-right for puts.
    private var labelSide: AnnotationPosition {
        position.optionType == .call ? .topLeading : .topTrailing
    }

    // MARK: Hover

    /// Tracks the pointer over the plot and turns its position into an underlying price.
    private func hoverArea(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame,
                              let spot = proxy.value(atX: location.x - geometry[plotFrame].origin.x, as: Double.self),
                              priceRange.contains(spot)
                        else {
                            hoverPrice = nil
                            return
                        }
                        hoverPrice = spot
                    case .ended:
                        hoverPrice = nil
                    }
                }
        }
    }

    /// A thin line at the hovered price with the tooltip beside it, on whichever side has more room.
    private func hoverRule(_ spot: Double) -> some ChartContent {
        let onRightHalf = spot > (priceRange.lowerBound + priceRange.upperBound) / 2
        return RuleMark(x: .value("Hovered price", spot))
            .foregroundStyle(Color.secondary.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .annotation(position: onRightHalf ? .leading : .trailing, alignment: .top, spacing: 8,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                tooltip(spot)
            }
    }

    private func tooltip(_ spot: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(price(spot))
                .font(.caption.weight(.semibold).monospacedDigit())
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(tooltipRows(at: spot)) { row in
                    GridRow {
                        Swatch(color: row.color, dashed: row.dashed)
                        Text(row.label)
                            .lineLimit(1)
                            .frame(maxWidth: 160, alignment: .leading)
                            .foregroundStyle(Color.secondary)
                        Text(signedMoney(row.pnl))
                            .monospacedDigit()
                            .foregroundStyle(Theme.pnlColor(row.pnl))
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                }
            }
        }
        .fixedSize()  // the annotation would otherwise squeeze it and truncate the values
        .padding(8)
        .background(Self.labelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    private func tooltipRows(at spot: Double) -> [TooltipRow] {
        var rows: [TooltipRow] = []
        if hasNowCurve, let pnl = nowPnL(at: spot) {
            rows.append(TooltipRow(id: "now", label: "Now", color: Theme.now, pnl: pnl))
        }
        if let selected {
            rows.append(TooltipRow(id: "scenario", label: selected.title, color: color(of: selected),
                                   pnl: scenarioPnL(selected, at: spot)))
        }
        rows.append(TooltipRow(id: "expiry", label: "At expiry", color: Theme.expiry, dashed: true,
                               pnl: expiryPnL(at: spot)))
        return rows
    }

    // MARK: Curves

    /// Drawn back to front: at expiry, the other scenarios, now, then the selected scenario on top.
    private var curves: [Curve] {
        var result = [Curve(id: "expiry", color: Theme.expiry, lineWidth: 1.5, dash: [4, 4],
                            points: samples { expiryPnL(at: $0) })]
        for scenario in scenarios where scenario.id != selectedScenario {
            result.append(Curve(id: "\(scenario.id.hashValue)", color: color(of: scenario).opacity(0.55),
                                lineWidth: 1.5, points: samples { scenarioPnL(scenario, at: $0) }))
        }
        if hasNowCurve {
            result.append(Curve(id: "now", color: Theme.now, lineWidth: 2.5,
                                points: samples { nowPnL(at: $0) ?? 0 }))
        }
        if let selected {
            result.append(Curve(id: "selected", color: color(of: selected), lineWidth: 2.5,
                                points: samples { scenarioPnL(selected, at: $0) }))
        }
        return result
    }

    /// 100 evenly spaced prices across the range, plus the strike so the expiry kink is sharp.
    private func samples(_ pnl: (Double) -> Double) -> [PnLPoint] {
        let range = priceRange
        var spots = (0..<100).map { range.lowerBound + (range.upperBound - range.lowerBound) * Double($0) / 99 }
        if !spots.contains(position.strike) {
            spots.append(position.strike)
            spots.sort()
        }
        return spots.map { PnLPoint(spot: $0, pnl: pnl($0)) }
    }

    /// Lowest and highest P&L on any curve, always including zero (break-even).
    private func pnlBounds(_ curves: [Curve]) -> ClosedRange<Double> {
        let values: [Double] = curves.flatMap { $0.points.map(\.pnl) } + [0]
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        return high > low ? low...high : (low - 1)...(high + 1)
    }

    // MARK: Valuation

    private var spot: Double? { store.underlyingPrice(for: position)?.value }
    private var impliedVolatility: Double? { store.impliedVolatility(for: position) }

    /// The "Now" curve needs both a price and an IV.
    private var hasNowCurve: Bool { spot != nil && impliedVolatility != nil }

    private var priceRange: ClosedRange<Double> {
        Theme.priceRange(for: position, spot: spot, iv: impliedVolatility)
    }

    private var scenarios: [Scenario] { position.sortedScenarios }
    private var selected: Scenario? { scenarios.first { $0.id == selectedScenario } }

    private func color(of scenario: Scenario) -> Color { Theme.color(for: scenario, in: position) }

    /// Position P&L in dollars for an option value per share.
    private func positionPnL(_ optionValue: Double) -> Double {
        (optionValue - position.averagePrice) * position.shares
    }

    private func nowPnL(at spot: Double) -> Double? {
        impliedVolatility.map { positionPnL(store.value(of: position, spot: spot, at: .now, vol: $0)) }
    }

    private func scenarioPnL(_ scenario: Scenario, at spot: Double) -> Double {
        positionPnL(store.value(of: position, spot: spot, at: scenario.date, vol: scenario.ivPercent / 100))
    }

    private func expiryPnL(at spot: Double) -> Double {
        positionPnL(intrinsicValue(type: position.optionType, spot: spot, strike: position.strike))
    }

    /// Spoken by VoiceOver for the whole card.
    private var accessibilitySummary: String {
        var parts: [String] = []
        if hasNowCurve, let spot, let pnl = nowPnL(at: spot) {
            parts.append("Now \(signedMoney(pnl)) at \(price(spot))")
        }
        for scenario in scenarios {
            parts.append("\(scenario.title) \(signedMoney(scenarioPnL(scenario, at: scenario.underlyingPrice)))")
        }
        parts.append("Break-even at expiry \(price(position.breakEven))")
        return parts.joined(separator: ", ")
    }

    // MARK: Style

    private static let gridColor = Color.gray.opacity(0.2)
    private static let labelBackground = Color(nsColor: .windowBackgroundColor)
}

/// A legend entry: a short line swatch and a caption.
private struct LegendItem: View {
    let label: String
    let color: Color
    var dashed = false

    var body: some View {
        HStack(spacing: 6) {
            Swatch(color: color, dashed: dashed)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A 14 × 3 line sample in a curve's color; dashed for "At expiry".
private struct Swatch: View {
    let color: Color
    var dashed = false

    var body: some View {
        if dashed {
            HStack(spacing: 2) {
                Capsule().fill(color).frame(width: 6, height: 3)
                Capsule().fill(color).frame(width: 6, height: 3)
            }
        } else {
            Capsule().fill(color).frame(width: 14, height: 3)
        }
    }
}
