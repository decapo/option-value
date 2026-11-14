import SwiftUI

/// The app's colors and the chart's price range. Green and red only ever mean gain and loss.
enum Theme {
    static let gain = steady(.systemGreen)
    static let loss = steady(.systemRed)
    static let now = steady(.systemBlue)
    static let expiry = Color.secondary

    /// Scenario colors in order; a scenario's color is its index in `Position.sortedScenarios`.
    static let scenarioColors: [Color] = [steady(.systemOrange), steady(.systemPurple), steady(.systemPink),
                                          steady(.systemYellow), steady(.systemBrown), steady(.systemTeal)]

    /// A system color exactly as it looks in a normal light or dark window. The inspector has a vibrant
    /// appearance that would otherwise brighten system colors, so a scenario's dot and slider would no
    /// longer match its curve in the chart, and gains would be a different green.
    private static func steady(_ color: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let plain = NSAppearance(named: appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
            var resolved = color
            plain?.performAsCurrentDrawingAppearance {
                resolved = color.usingType(.componentBased) ?? color
            }
            return resolved
        })
    }

    /// The palette color for a scenario index (cycles after six).
    static func scenarioColor(at index: Int) -> Color {
        scenarioColors[abs(index) % scenarioColors.count]
    }

    /// A scenario's color within its position.
    static func color(for scenario: Scenario, in position: Position) -> Color {
        scenarioColor(at: position.sortedScenarios.firstIndex { $0.id == scenario.id } ?? 0)
    }

    /// Gain for positive values, loss for negative ones, primary for zero or missing.
    static func pnlColor(_ value: Double?) -> Color {
        guard let value else { return .primary }
        if value > 0 { return gain }
        if value < 0 { return loss }
        return .primary
    }

    /// Underlying prices shown on the chart and the scenario price slider: min(spot, strike) minus a margin to
    /// max(spot, strike) plus the same margin, widened to include every scenario price. The margin follows the
    /// expected move, 1.25 × IV × √(years to expiry), kept between 8% and 50% (30% when there is no IV).
    static func priceRange(for position: Position, spot: Double?, iv: Double?) -> ClosedRange<Double> {
        let reference = spot ?? position.strike
        var margin = 0.3
        if let iv {
            let years = Swift.max(position.daysToExpiration, 1) / 365
            margin = Swift.min(Swift.max(1.25 * iv * sqrt(years), 0.08), 0.5)
        }
        var lower = (1 - margin) * Swift.min(reference, position.strike)
        var upper = (1 + margin) * Swift.max(reference, position.strike)
        for scenario in position.scenarios {
            lower = Swift.min(lower, scenario.underlyingPrice)
            upper = Swift.max(upper, scenario.underlyingPrice)
        }
        return upper > lower ? lower...upper : lower...(lower + 1)
    }
}

// MARK: - Number formats ("–" for missing values)

/// Numbers are always shown in US English ("$1,234.50"), whatever the system region.
let usLocale = Locale(identifier: "en_US")

/// Per-share prices, always 2 decimals: "$3.52".
func price(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.currency(code: "USD").locale(usLocale).precision(.fractionLength(2)))
}

/// Position totals: whole dollars from $1,000 ("$140,779"), otherwise 2 decimals ("$924.50").
func money(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.currency(code: "USD").locale(usLocale).precision(.fractionLength(abs(value) >= 1000 ? 0 : 2)))
}

/// Like `money` with an explicit sign: "+$48,379", "-$1,204".
func signedMoney(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.currency(code: "USD").locale(usLocale)
        .precision(.fractionLength(abs(value) >= 1000 ? 0 : 2))
        .sign(strategy: .always(showZero: false)))
}

/// A fraction as a signed percentage with 1 decimal: 0.524 → "+52.4%".
func signedPercent(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.percent.locale(usLocale).precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
}

/// A fraction as a percentage with 1 decimal: 0.627 → "62.7%".
func percent(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.percent.locale(usLocale).precision(.fractionLength(1)))
}

/// A strike (or scenario price) without trailing zeros: "$49", "$49.50", "$1,250".
func strikeLabel(_ strike: Double) -> String {
    guard strike == strike.rounded() else { return price(strike) }
    return strike.formatted(.currency(code: "USD").locale(usLocale).precision(.fractionLength(0)))
}

/// "400 contracts", "1 contract".
func contractsText(_ count: Int) -> String {
    count == 1 ? "1 contract" : "\(count.formatted(.number.locale(usLocale))) contracts"
}

/// The format of the implied-volatility text fields: a fraction shown with one decimal, "62.7%".
let percentFieldFormat = FloatingPointFormatStyle<Double>.Percent.percent.locale(usLocale).precision(.fractionLength(1))

// MARK: - Dates (always Eastern time)

private let shortDateFormatter = easternFormatter("MMM d ''yy")
private let longDateFormatter = easternFormatter("MMM d, yyyy")
private let monthDayFormatter = easternFormatter("MMM d")
private let monthDayTimeFormatter = easternFormatter("MMM d, h:mm a")
private let timeFormatter = easternFormatter("h:mm a")

/// "Feb 19 '27"
func shortDateText(_ date: Date) -> String { shortDateFormatter.string(from: date) }

/// "Feb 19, 2027"
func longDateText(_ date: Date) -> String { longDateFormatter.string(from: date) }

/// "Nov 20"
func monthDayText(_ date: Date) -> String { monthDayFormatter.string(from: date) }

/// "Nov 20, 10:00 AM"
func monthDayTimeText(_ date: Date) -> String { monthDayTimeFormatter.string(from: date) }

/// "1:01 AM"
func timeText(_ date: Date) -> String { timeFormatter.string(from: date) }

/// Countdown to an expiration day: "98 days", "1 day", "Expires today" or "Expired"
/// (options expire at 4:00 PM ET). Days are calendar days in Eastern time.
func expiryCountdown(_ expiration: Date, now: Date = .now) -> String {
    if now >= expirationMoment(expiration) { return "Expired" }
    let calendar = easternCalendar
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: expiration)).day ?? 0
    switch days {
    case ...0: return "Expires today"
    case 1: return "1 day"
    default: return "\(days) days"
    }
}

// MARK: - Shared components

extension View {
    /// The app's one panel style: a soft rounded fill, no border, no shadow. Inner padding defaults to 16.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .modifier(CardBackground())
    }

    /// An inline value field (scenario values, the inspector's IV): right-aligned, of a fixed width.
    func fieldStyle(width: CGFloat) -> some View {
        self
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .labelsHidden()
            .frame(width: width)
    }
}

/// The card fill: `.fill.quaternary`, one step stronger in light mode, where quaternary on the white
/// page is too faint to see.
private struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(colorScheme == .light ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary),
                           in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A tiny capsule label, e.g. "HL" for a Hyperliquid price.
struct Tag: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.fill.tertiary, in: Capsule())
    }
}

/// A small caption label over a value, optionally followed by trailing content such as a `Tag`.
struct Stat<Trailing: View>: View {
    let label: String
    let value: String
    let trailing: Trailing

    init(_ label: String, _ value: String, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.value = value
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.body.monospacedDigit())
                trailing
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Stat where Trailing == EmptyView {
    init(_ label: String, _ value: String) {
        self.init(label, value) { EmptyView() }
    }
}

/// A profit or loss in dollars ("+$48,379"), colored gain / loss.
struct PnLText: View {
    let value: Double?
    let style: Font

    init(_ value: Double?, _ style: Font = .body) {
        self.value = value
        self.style = style
    }

    var body: some View {
        Text(signedMoney(value))
            .font(style.monospacedDigit())
            .foregroundStyle(Theme.pnlColor(value))
    }
}

/// A P&L in dollars over the same P&L as a fraction of the cost ("+$48,379" over "+52.4%"), trailing.
struct PnLStack: View {
    let profit: Double?
    let fraction: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            PnLText(profit, .body.weight(.medium))
            Text(signedPercent(fraction))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.pnlColor(profit))
        }
    }
}
