import SwiftUI

/// One saved scenario, collapsed to a header or expanded with its sliders.
struct ScenarioCard: View {
    @Bindable var scenario: Scenario
    let position: Position
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void  // toggles selection
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @Environment(MarketStore.self) private var store
    /// Captured once, so the date slider's range holds still while dragging.
    @State private var now = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isSelected {
                Divider()
                expandedBody
            }
        }
        .card(padding: 12)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.5)
            }
        }
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityElement(children: isSelected ? .contain : .combine)
    }

    // MARK: Valuation

    /// Option value per share in this scenario.
    private var optionValue: Double { store.value(of: scenario, for: position) }
    private var positionValue: Double { optionValue * position.shares }
    private var profit: Double { positionValue - position.costBasis }
    private var profitFraction: Double? {
        position.costBasis > 0 ? profit / position.costBasis : nil
    }

    // MARK: Header

    /// Collapsed, the whole header expands the card. Expanded, the title is a text field and
    /// the trailing P&L and chevron collapse it.
    @ViewBuilder private var header: some View {
        if isSelected {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                dot
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $scenario.name, prompt: Text(scenario.autoTitle))
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier("scenarioName")
                    summary
                }
                .layoutPriority(1)
                Button(action: onSelect) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Spacer(minLength: 0)
                        profitColumn
                        chevron
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse")
                .accessibilityLabel("Collapse, \(spokenSummary)")
            }
        } else {
            Button(action: onSelect) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    dot
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scenario.title)
                            .font(.body.weight(.medium))
                        summary
                    }
                    Spacer(minLength: 8)
                    profitColumn
                    chevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenSummary)
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
    }

    /// The full summary, or without the time of day when the inspector is too narrow for it.
    private var summary: some View {
        ViewThatFits(in: .horizontal) {
            Text(scenario.summary)
            Text("\(price(scenario.underlyingPrice)) · \(monthDayText(scenario.date)) · IV \(percent(scenario.ivPercent / 100))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var profitColumn: some View {
        PnLStack(profit: profit, fraction: profitFraction)
            .fixedSize()
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isSelected ? 90 : 0))
    }

    private var spokenSummary: String {
        let word = profit < 0 ? "loss" : "gain"
        let fraction = profitFraction.map { ", " + percent(abs($0)) } ?? ""
        return "\(scenario.title), \(scenario.summary), \(word) \(money(abs(profit)))\(fraction)"
    }

    // MARK: Expanded body

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            priceControl
            dateControl
            volatilityControl
            stats
            footer
        }
    }

    private var priceControl: some View {
        VStack(spacing: 4) {
            controlRow("Underlying price") {
                TextField("Underlying price", value: $scenario.underlyingPrice, format: currencyFormat)
                    .fieldStyle(width: 90)
            }
            ScenarioSlider(label: "Underlying price", value: priceSliderValue, range: priceRange, color: color)
                .accessibilityIdentifier("scenarioPriceSlider")
        }
    }

    private var dateControl: some View {
        VStack(spacing: 4) {
            controlRow("Date and time (ET)") {
                DatePicker("Date and time", selection: $scenario.date,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .fixedSize()
                    .environment(\.locale, usLocale)  // "11/20/2026, 10:00 AM", like the rest of the app
            }
            ScenarioSlider(label: "Date and time", value: dateSliderValue, range: dateRange, color: color)
                .accessibilityIdentifier("scenarioDateSlider")
        }
    }

    private var volatilityControl: some View {
        VStack(spacing: 4) {
            controlRow("Implied volatility") {
                if let marketIV, abs(marketIV - scenario.ivPercent) >= 0.05 {
                    Button {
                        scenario.ivPercent = marketIV
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to the position’s IV (\(percent(marketIV / 100)))")
                    .accessibilityLabel("Reset to the position’s implied volatility")
                }
                TextField("Implied volatility", value: ivFraction, format: percentFieldFormat)
                    .fieldStyle(width: 70)
            }
            ScenarioSlider(label: "Implied volatility", value: ivSliderValue, range: ivRange, color: color)
                .accessibilityIdentifier("scenarioIVSlider")
        }
    }

    /// "Label ……… field"
    private func controlRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            field()
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 12) {
            Stat("Option price", price(optionValue))
                .frame(maxWidth: .infinity, alignment: .leading)
            Stat("Position value", money(positionValue))
                .frame(maxWidth: .infinity, alignment: .leading)
            Stat("Time to expiry", expiryCountdown(position.expiration, now: scenario.date))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Duplicate", action: onDuplicate)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    // MARK: Slider bindings and ranges

    /// Rounded to cents.
    private var priceSliderValue: Binding<Double> {
        Binding(get: { scenario.underlyingPrice },
                set: { scenario.underlyingPrice = ($0 * 100).rounded() / 100 })
    }

    /// The chart's price range, widened to include the scenario's price.
    private var priceRange: ClosedRange<Double> {
        let range = Theme.priceRange(for: position, spot: store.underlyingPrice(for: position)?.value,
                                     iv: store.impliedVolatility(for: position))
        return Swift.min(range.lowerBound, scenario.underlyingPrice)...Swift.max(range.upperBound, scenario.underlyingPrice)
    }

    /// Seconds since the reference date, snapped to whole hours (but never outside the range).
    private var dateSliderValue: Binding<Double> {
        Binding(get: { scenario.date.timeIntervalSinceReferenceDate },
                set: { seconds in
                    let snapped = (seconds / 3600).rounded() * 3600
                    let clamped = Swift.min(Swift.max(snapped, dateRange.lowerBound), dateRange.upperBound)
                    scenario.date = Date(timeIntervalSinceReferenceDate: clamped)
                })
    }

    /// From now (or the scenario's date, if earlier) to 4:00 PM ET on the expiration day.
    private var dateRange: ClosedRange<Double> {
        let start = Swift.min(now, scenario.date).timeIntervalSinceReferenceDate
        let end = Swift.max(expirationMoment(position.expiration), scenario.date).timeIntervalSinceReferenceDate
        return start...Swift.max(end, start + 3600)
    }

    /// Steps of 0.5 percentage points.
    private var ivSliderValue: Binding<Double> {
        Binding(get: { scenario.ivPercent },
                set: { scenario.ivPercent = ($0 * 2).rounded() / 2 })
    }

    /// 5% … 200%, widened to include the scenario's IV.
    private var ivRange: ClosedRange<Double> {
        Swift.min(5, scenario.ivPercent)...Swift.max(200, scenario.ivPercent)
    }

    /// The IV field edits a fraction ("62.7%") of the stored percentage.
    private var ivFraction: Binding<Double> {
        Binding(get: { scenario.ivPercent / 100 },
                set: { scenario.ivPercent = $0 * 100 })
    }

    /// Today's IV in percent, rounded to 0.1.
    private var marketIV: Double? {
        store.impliedVolatility(for: position).map { ($0 * 1000).rounded() / 10 }
    }
}

private let currencyFormat = FloatingPointFormatStyle<Double>.Currency.currency(code: "USD")
    .locale(usLocale).precision(.fractionLength(2))

/// A full-width slider tinted with the scenario color. Its range holds still while it is dragged,
/// so the thumb never jumps when the range would otherwise follow the value.
private struct ScenarioSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color

    @State private var dragRange: ClosedRange<Double>?

    var body: some View {
        Slider(value: $value, in: dragRange ?? range,
               label: { Text(label) },
               onEditingChanged: { editing in dragRange = editing ? range : nil })
        .labelsHidden()
        .controlSize(.small)
        .tint(color)
    }
}
