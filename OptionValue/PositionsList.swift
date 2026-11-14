import SwiftUI

/// The positions card: a header row and one two-line row per position, in equal-width columns.
/// Click selects, double-click edits; ↑/↓, Return and Delete work while the card has keyboard focus.
struct PositionsList: View {
    let positions: [Position]
    @Binding var selection: Position.ID?
    let onEdit: (Position) -> Void
    let onDelete: (Position) -> Void

    @State private var hovered: Position.ID?
    @FocusState private var isFocused: Bool

    /// More rows than this scroll inside the card.
    private let maxVisibleRows = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .padding(.bottom, 4)
            if positions.count > maxVisibleRows {
                ScrollView {
                    rows
                }
                .frame(height: CGFloat(maxVisibleRows) * PositionRow.height)
            } else {
                rows
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .card(padding: 0)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.return) { act(onEdit) }
        .onKeyPress(.delete) { act(onDelete) }
        .onKeyPress(.deleteForward) { act(onDelete) }
        .animation(.snappy(duration: 0.2), value: hovered)
        .animation(.snappy(duration: 0.2), value: selection)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Contract")
                .frame(minWidth: PositionRow.minWidths[0], maxWidth: .infinity, alignment: .leading)
            ForEach(1..<6) { column in
                Text(["", "Position", "Underlying", "Synthetic", "Market value", "Unrealized P&L"][column])
                    .fixedSize()
                    .frame(minWidth: PositionRow.minWidths[column], maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(positions) { position in
                row(position)
            }
        }
    }

    private func row(_ position: Position) -> some View {
        PositionRow(position: position,
                    isSelected: selection == position.id,
                    isHovered: hovered == position.id)
            .onHover { inside in
                if inside {
                    hovered = position.id
                } else if hovered == position.id {
                    hovered = nil
                }
            }
            .gesture(TapGesture(count: 2).onEnded {
                select(position)
                onEdit(position)
            })
            .simultaneousGesture(TapGesture().onEnded {
                select(position)
            })
            .contextMenu {
                Button("Edit Position…") { onEdit(position) }
                Button("Delete Position…", role: .destructive) { onDelete(position) }
            }
            .accessibilityAction { select(position) }
            .accessibilityAction(named: "Edit Position") { onEdit(position) }
            .accessibilityAction(named: "Delete Position") { onDelete(position) }
    }

    // MARK: Selection and keyboard

    private func select(_ position: Position) {
        selection = position.id
        isFocused = true
    }

    /// Moves the selection up or down one row (selects the first row when nothing is selected).
    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard !positions.isEmpty else { return .ignored }
        guard let index = positions.firstIndex(where: { $0.id == selection }) else {
            selection = positions.first?.id
            return .handled
        }
        let newIndex = Swift.min(Swift.max(index + offset, 0), positions.count - 1)
        selection = positions[newIndex].id
        return .handled
    }

    /// Runs an action (edit or delete) on the selected position.
    private func act(_ action: (Position) -> Void) -> KeyPress.Result {
        guard let position = positions.first(where: { $0.id == selection }) else { return .ignored }
        action(position)
        return .handled
    }
}

/// One position: six equal-width columns, each a primary line over a caption line.
private struct PositionRow: View {
    let position: Position
    let isSelected: Bool
    let isHovered: Bool

    @Environment(MarketStore.self) private var store

    /// The narrowest each column may get: contract, position, underlying, synthetic, market value, P&L.
    /// Columns share any extra width equally; the header uses the same widths, so everything lines up.
    /// Together they fit the 540 pt page left beside a 400 pt inspector in the smallest (980 pt) window.
    static let minWidths: [CGFloat] = [110, 52, 80, 56, 70, 76]
    /// Approximate height of one row plus the gap below it (used to cap the scrolling height).
    static let height: CGFloat = 49

    var body: some View {
        HStack(spacing: 12) {
            contractCell
            cell(1, Text(position.contracts.formatted()), "avg \(price(position.averagePrice))")
            cell(2, underlyingLine, moneynessText)
            cell(3, Text(price(synthetic)), syntheticDetail)
            cell(4, Text(money(marketValue)), "cost \(money(position.costBasis))")
            profitCell
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("positionRow-\(position.symbol)")
    }

    // MARK: Cells

    private var contractCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(position.title)
                .font(.body.weight(.semibold))
            Text("\(position.expirationText) · \(position.countdownText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(minWidth: Self.minWidths[0], maxWidth: .infinity, alignment: .leading)
    }

    /// "$42.83", preceded by an "HL" tag when the price comes from Hyperliquid. The tag sits in a zero-width
    /// frame (it draws to the left of it), so every price in the column ends on the same edge, tagged or not.
    private var underlyingLine: some View {
        HStack(spacing: 0) {
            if underlying?.source == .hyperliquid {
                Tag("HL")
                    .padding(.trailing, 4)
                    .fixedSize()
                    .frame(width: 0, alignment: .trailing)
            }
            Text(price(underlying?.value))
        }
    }

    private var profitCell: some View {
        PnLStack(profit: profit, fraction: profitFraction)
            .fixedSize()
            .frame(minWidth: Self.minWidths[5], maxWidth: .infinity, alignment: .trailing)
    }

    /// A trailing-aligned column: a body line over a secondary caption line. The column's width comes only
    /// from `minWidths` and the space available, so every row lines up with the header; the text keeps its
    /// natural size and, if it is ever wider, reaches into the 12 pt gutter rather than truncating.
    private func cell(_ column: Int, _ line1: some View, _ line2: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            line1
                .font(.body.monospacedDigit())
            Text(line2)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .frame(minWidth: Self.minWidths[column], maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Values

    private var underlying: MarketData.Price? { store.underlyingPrice(for: position) }
    private var synthetic: Double? { store.syntheticValue(for: position) }
    private var marketValue: Double? { store.marketValue(for: position) }
    private var profit: Double? { store.profit(for: position) }

    private var profitFraction: Double? {
        guard let profit, position.costBasis > 0 else { return nil }
        return profit / position.costBasis
    }

    /// "last $2.78" when the contract has a last trade, else the IV in use ("IV 62.7%"), else "IV not set".
    private var syntheticDetail: String {
        if let last = store.quote(for: position)?.last {
            return "last \(price(last))"
        }
        if let iv = store.impliedVolatility(for: position) {
            return "IV \(percent(iv))"
        }
        return "IV not set"
    }

    private var moneynessText: String {
        guard let spot = underlying?.value else { return "–" }
        return position.moneynessText(spot: spot)
    }

    /// Clear normally, a soft fill on hover, a stronger neutral fill when selected. Not the accent color:
    /// this user's accent is red, which would make a selected gain look like a loss.
    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.fill.tertiary) }
        if isHovered { return AnyShapeStyle(.fill.quaternary) }
        return AnyShapeStyle(Color.clear)
    }

    /// "DRAM 49 dollar call, 400 contracts, unrealized gain 48,379 dollars, 52.4 percent".
    private var spokenSummary: String {
        let kind = position.optionType == .call ? "call" : "put"
        var parts = ["\(position.underlying) \(position.strike.formatted()) dollar \(kind)",
                     contractsText(position.contracts)]
        if let profit, let profitFraction {
            let direction = profit < 0 ? "loss" : "gain"
            let dollars = abs(profit).formatted(.number.precision(.fractionLength(0)))
            let percentText = abs(profitFraction * 100).formatted(.number.precision(.fractionLength(1)))
            parts.append("unrealized \(direction) \(dollars) dollars, \(percentText) percent")
        } else {
            parts.append("not priced yet")
        }
        parts.append(position.countdownText)
        return parts.joined(separator: ", ")
    }
}
