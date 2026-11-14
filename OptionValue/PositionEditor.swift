import SwiftData
import SwiftUI

/// The New / Edit Position sheet: a contract picked from the option chain or typed in,
/// the position size, and an optional Hyperliquid symbol for prices while US markets are closed.
struct PositionEditor: View {
    let position: Position?  // nil → new position
    let onSave: (Position) -> Void  // called after insert/update, before dismiss

    @Environment(MarketStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // Contract. The manual fields also remember the last row chosen in the chain.
    @State private var ticker: String
    @State private var optionType: OptionType
    @State private var expiration: Date
    @State private var strikeInput: String
    @State private var manualChosen: Bool?  // nil until the user switches modes

    // Option chain
    @State private var chain: [OptionQuote] = []
    @State private var chainError: String?
    @State private var isLoadingChain = false
    @State private var loadedChainKey: String?
    @State private var chainExpiration: Date?
    @State private var chosenID: OptionQuote.ID?
    @State private var stockPrice: Double?  // loaded with the chain

    // Position
    @State private var contractsInput: String
    @State private var averagePriceInput: String
    @State private var ivInput: String  // percent, e.g. "62.7" (manual mode only)
    @State private var ivEdited = false

    // Hyperliquid
    @State private var hyperliquidSymbol: String
    @State private var autoFilledSymbol = ""
    @State private var hyperliquidCheck: HyperliquidCheck?
    @State private var notListedTicker: String?  // auto-detection found no symbol for this ticker

    init(position: Position?, onSave: @escaping (Position) -> Void) {
        self.position = position
        self.onSave = onSave
        _ticker = State(initialValue: position?.underlying ?? DemoData.ticker?.uppercased() ?? "")
        _optionType = State(initialValue: position?.optionType ?? .call)
        _expiration = State(initialValue: position?.expiration ?? defaultMonthlyExpiration())
        _strikeInput = State(initialValue: position.map { plainNumber($0.strike) } ?? "")
        _contractsInput = State(initialValue: position.map { String($0.contracts) } ?? "")
        _averagePriceInput = State(initialValue: position.map { plainNumber($0.averagePrice, decimals: 2) } ?? "")
        _ivInput = State(initialValue: position?.lastIV.map { ivText($0) } ?? "")
        _hyperliquidSymbol = State(initialValue: position?.hyperliquidSymbol ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(position == nil ? "New Position" : "Edit Position")
                .font(.title2.weight(.semibold))
            contractCard
            positionCard
            hyperliquidCard
            buttons
        }
        .padding(20)
        .frame(width: 540)
        .onChange(of: ticker) {
            if ticker != ticker.uppercased() { ticker = ticker.uppercased() }
        }
        .onChange(of: chainExpiration) { keepStrikeOnNewExpiration() }
        .onChange(of: ivInput) { ivEdited = true }
        .task(id: "\(isManual) \(cleanTicker) \(optionType.rawValue)") { await loadChain() }
        .task(id: cleanTicker) { await autoFillHyperliquid() }
        .task(id: cleanSymbol) { await checkHyperliquid() }
    }

    // MARK: Contract card

    private var contractCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            tickerRow
            if isManual {
                manualFields
            } else {
                chainBrowser
            }
            if store.hasAlpacaKeys {
                modeFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tickerRow: some View {
        HStack(spacing: 12) {
            TextField("Ticker", text: $ticker, prompt: Text("Ticker"))
                .autocorrectionDisabled()
                .frame(width: 110)
                .accessibilityIdentifier("editorTicker")
            Picker("Type", selection: $optionType) {
                Text("Call").tag(OptionType.call)
                Text("Put").tag(OptionType.put)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150, alignment: .leading)
            Spacer(minLength: 0)
            chainStatus
        }
    }

    /// Spinner while loading, else the stock price and the number of expirations (chain mode only).
    @ViewBuilder private var chainStatus: some View {
        if !isManual {
            if isLoadingChain {
                ProgressView().controlSize(.small)
            } else if !chain.isEmpty {
                Text(chainStatusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "$43.02 · 23 expirations", or "23 expirations" without a stock price.
    private var chainStatusText: String {
        let count = expirations.count == 1 ? "1 expiration" : "\(expirations.count) expirations"
        guard let stockPrice else { return count }
        return "\(price(stockPrice)) · \(count)"
    }

    private var chainBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Expiration", selection: $chainExpiration) {
                if expirations.isEmpty {
                    Text("–").tag(Date?.none)
                }
                ForEach(expirations, id: \.self) { day in
                    Text("\(longDateText(day)) · \(expiryCountdown(day))").tag(Date?.some(day))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(expirations.isEmpty)
            StrikeList(rows: rows, selection: chosenBinding, spot: spot, placeholder: chainPlaceholder)
        }
    }

    /// The expiration and strike, with a hint under them when the expiration falls on a weekend.
    private var manualFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                DatePicker("Expiration", selection: $expiration, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .fixedSize()
                    .environment(\.locale, usLocale)  // "2/19/2027", like the rest of the app
                LabeledContent("Strike") {
                    NumberField(title: "Strike", text: $strikeInput)
                        .accessibilityIdentifier("editorStrike")
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            if let weekendHint {
                Text(weekendHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The chosen contract (chain mode) and the button that switches between the two modes (Alpaca keys only).
    private var modeFooter: some View {
        HStack(spacing: 12) {
            if !isManual {
                chosenCaption
            }
            Spacer(minLength: 0)
            Button(isManual ? "Browse option chain" : "Enter contract manually") {
                manualChosen = !isManual
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityIdentifier("editorModeToggle")
        }
    }

    @ViewBuilder private var chosenCaption: some View {
        if let quote = chosenQuote {
            Text(contractCaption(quote))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if !rows.isEmpty {
            Text("Choose a strike")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Position card

    /// The size and cost of the position; in manual mode also its implied volatility on a second row.
    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sizeRow
            if isManual {
                volatilityRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var sizeRow: some View {
        HStack(spacing: 16) {
            LabeledContent("Contracts") {
                NumberField(title: "Contracts", text: $contractsInput)
                    .accessibilityIdentifier("editorContracts")
            }
            .fixedSize()
            LabeledContent("Average price") {
                NumberField(title: "Average price", text: $averagePriceInput, prompt: "per share")
                    .accessibilityIdentifier("editorAveragePrice")
            }
            .fixedSize()
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Cost basis")
                    .font(.caption)
                Text(costBasisText)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private var volatilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Implied volatility") {
                HStack(spacing: 4) {
                    NumberField(title: "Implied volatility", text: $ivInput, prompt: "e.g. 60", width: 70)
                        .accessibilityIdentifier("editorIV")
                    Text("%")
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            Text("From your broker’s option chain. Needed to value the position — you can change it any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Hyperliquid card

    private var hyperliquidCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LabeledContent("Hyperliquid symbol") {
                    TextField("Hyperliquid symbol", text: $hyperliquidSymbol, prompt: Text("e.g. xyz:DRAM"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .frame(width: 150)
                        .accessibilityIdentifier("editorHyperliquid")
                }
                .fixedSize()
                hyperliquidStatus
                Spacer(minLength: 0)
            }
            Text(hyperliquidCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Spinner while checking, then a check mark and the price, or "Not found on Hyperliquid".
    @ViewBuilder private var hyperliquidStatus: some View {
        if !cleanSymbol.isEmpty {
            if let check = hyperliquidCheck, check.symbol == cleanSymbol {
                if let mid = check.price {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(price(mid))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Found on Hyperliquid, \(price(mid))")
                } else {
                    Text("Not found on Hyperliquid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Says so when the ticker isn't on Hyperliquid and there are no Alpaca keys to price it instead.
    /// Without keys Alpaca is mentioned only then.
    private var hyperliquidCaption: String {
        if store.hasAlpacaKeys {
            return "Optional. Used for the underlying price while US markets are closed, or if Alpaca is unavailable."
        }
        if cleanSymbol.isEmpty, notListedTicker == cleanTicker {
            return "\(cleanTicker) isn’t listed on Hyperliquid, so the app can’t fetch its price without Alpaca keys. "
                + "You can still save the position and run scenarios."
        }
        return "Used for the underlying price. The app fills it in when Hyperliquid lists the ticker."
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editorCancel")
            Button(position == nil ? "Add Position" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .accessibilityIdentifier("editorSave")
        }
    }

    // MARK: Derived values

    /// The result of looking up one Hyperliquid symbol (price nil = not found).
    private struct HyperliquidCheck {
        let symbol: String
        let price: Double?
    }

    /// Manual mode when editing or without Alpaca keys, until the user switches.
    private var isManual: Bool {
        !store.hasAlpacaKeys || (manualChosen ?? (position != nil))
    }

    private var cleanTicker: String { ticker.trimmingCharacters(in: .whitespaces).uppercased() }
    private var cleanSymbol: String { hyperliquidSymbol.trimmingCharacters(in: .whitespaces) }

    /// The chain's expiration days, nearest first.
    private var expirations: [Date] { Set(chain.map(\.expiration)).sorted() }

    /// The strikes of the expiration shown in the picker.
    private var rows: [OptionQuote] { chain.filter { $0.expiration == chainExpiration } }

    /// The underlying's price the strike list centers on: the stock price, else the Hyperliquid card's price.
    private var spot: Double? {
        if let stockPrice { return stockPrice }
        guard let check = hyperliquidCheck, check.symbol == cleanSymbol else { return nil }
        return check.price
    }

    private var chosenQuote: OptionQuote? {
        isManual ? nil : chain.first { $0.id == chosenID }
    }

    /// Selecting a row also fills the manual fields, so switching modes keeps the contract.
    private var chosenBinding: Binding<OptionQuote.ID?> {
        Binding(get: { chosenID },
                set: { id in choose(chain.first { $0.id == id }) })
    }

    /// What the list area says when it has no rows.
    private var chainPlaceholder: String? {
        if cleanTicker.isEmpty { return "Enter a ticker to browse its option chain." }
        if isLoadingChain { return "Loading option chain…" }
        if let chainError { return chainError }
        if chain.isEmpty { return "No option chain found for \(cleanTicker)" }
        return nil
    }

    // The contract that would be saved: the chosen row in chain mode, the fields in manual mode.
    private var contractStrike: Double? {
        isManual ? parseNumber(strikeInput).flatMap { $0 > 0 ? $0 : nil } : chosenQuote?.strike
    }

    private var contractExpiration: Date? {
        isManual ? expiration : chosenQuote?.expiration
    }

    /// "That’s a Saturday. …" when the typed expiration falls on a weekend. Only a hint: it can still be saved.
    private var weekendHint: String? {
        switch easternCalendar.component(.weekday, from: expiration) {
        case 7: "That’s a Saturday. Options expire on weekdays, usually Fridays."
        case 1: "That’s a Sunday. Options expire on weekdays, usually Fridays."
        default: nil
        }
    }

    private var contracts: Int? {
        Int(contractsInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
            .flatMap { $0 > 0 ? $0 : nil }
    }

    private var averagePrice: Double? {
        parseNumber(averagePriceInput).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The typed implied volatility as a fraction; nil when the field is empty or not a positive number.
    private var typedIV: Double? {
        parseNumber(ivInput.replacingOccurrences(of: "%", with: "")).flatMap { $0 > 0 ? $0 / 100 : nil }
    }

    /// Empty is fine (the position just can't be valued yet); anything typed must be a positive number.
    private var ivIsValid: Bool {
        ivInput.trimmingCharacters(in: .whitespaces).isEmpty || typedIV != nil
    }

    private var costBasisText: String {
        guard let contracts, let averagePrice else { return "–" }
        return money(Double(contracts) * averagePrice * 100)
    }

    private var canSave: Bool {
        !cleanTicker.isEmpty && contractStrike != nil && contractExpiration != nil
            && contracts != nil && averagePrice != nil && (!isManual || ivIsValid)
    }

    /// "DRAM Feb 19 '27 $49 Call · mid $3.83"
    private func contractCaption(_ quote: OptionQuote) -> String {
        let name = "\(quote.underlying) \(shortDateText(quote.expiration)) \(strikeLabel(quote.strike)) "
            + (quote.type == .call ? "Call" : "Put")
        guard let mid = quote.mid else { return name }
        return "\(name) · mid \(price(mid))"
    }

    // MARK: Actions

    private func choose(_ quote: OptionQuote?) {
        chosenID = quote?.id
        if let quote {
            strikeInput = plainNumber(quote.strike)
            expiration = quote.expiration
        }
    }

    /// When another expiration is picked, keep the same strike if that expiration has it.
    private func keepStrikeOnNewExpiration() {
        guard let current = chain.first(where: { $0.id == chosenID }),
              current.expiration != chainExpiration else { return }
        choose(rows.first { $0.strike == current.strike })
    }

    /// Loads the chain 0.6 s after the ticker or type stops changing (chain mode only).
    private func loadChain() async {
        let key = "\(cleanTicker) \(optionType.rawValue)"
        if cleanTicker.isEmpty {
            clearChain()
        }
        guard !isManual, !cleanTicker.isEmpty, key != loadedChainKey else {
            isLoadingChain = false
            return
        }
        clearChain()
        isLoadingChain = true
        try? await Task.sleep(for: .seconds(0.6))
        guard !Task.isCancelled else { return }
        do {
            let result = try await store.chain(underlying: cleanTicker, type: optionType)
            let latestPrice = await store.stockPrice(cleanTicker)
            guard !Task.isCancelled else { return }
            chain = result
            stockPrice = latestPrice
            loadedChainKey = key
            selectInitialRow()
        } catch {
            guard !Task.isCancelled else { return }
            chainError = error.localizedDescription
        }
        isLoadingChain = false
    }

    private func clearChain() {
        chain = []
        chainError = nil
        chainExpiration = nil
        loadedChainKey = nil
        stockPrice = nil
    }

    /// After a load: re-select the contract in the fields if the chain has it. Otherwise show the edited
    /// position's expiration if the chain has it, else the default one (at least 28 days away).
    private func selectInitialRow() {
        let strike = parseNumber(strikeInput)
        if let match = chain.first(where: { $0.strike == strike && sameDay($0.expiration, expiration) }) {
            chainExpiration = match.expiration
            chosenID = match.id
        } else {
            let editedExpiration = position == nil ? nil : expirations.first { sameDay($0, expiration) }
            chainExpiration = editedExpiration ?? defaultExpiration(expirations)
            chosenID = nil
        }
    }

    /// When the ticker changes and the symbol is empty or was auto-filled, look the ticker up on every
    /// Hyperliquid exchange and fill in the symbol it finds.
    private func autoFillHyperliquid() async {
        guard !cleanTicker.isEmpty, cleanTicker != position?.underlying, canAutoFill else { return }
        try? await Task.sleep(for: .seconds(0.6))
        guard !Task.isCancelled else { return }
        let ticker = cleanTicker
        let found = await store.findHyperliquidSymbol(for: ticker)
        guard !Task.isCancelled, canAutoFill else { return }
        if let found {
            hyperliquidCheck = HyperliquidCheck(symbol: found.symbol, price: found.price)
            autoFilledSymbol = found.symbol
            hyperliquidSymbol = found.symbol
            notListedTicker = nil
        } else {
            autoFilledSymbol = ""
            hyperliquidSymbol = ""
            notListedTicker = ticker
        }
    }

    private var canAutoFill: Bool {
        cleanSymbol.isEmpty || hyperliquidSymbol == autoFilledSymbol
    }

    /// Checks whatever is in the symbol field, 0.6 s after it stops changing.
    private func checkHyperliquid() async {
        let symbol = cleanSymbol
        guard !symbol.isEmpty, hyperliquidCheck?.symbol != symbol else { return }
        try? await Task.sleep(for: .seconds(0.6))
        guard !Task.isCancelled else { return }
        let mid = await store.hyperliquidPrice(symbol)
        guard !Task.isCancelled else { return }
        hyperliquidCheck = HyperliquidCheck(symbol: symbol, price: mid)
    }

    /// Inserts or updates the position, then hands it back and closes the sheet.
    private func save() {
        guard canSave, let strike = contractStrike, let day = contractExpiration,
              let contracts, let averagePrice else { return }
        let expirationDay = easternCalendar.startOfDay(for: day)
        let chosenIV = chosenQuote?.impliedVolatility
        // Manual mode uses the typed IV; chain mode the chosen row's.
        let newIV = isManual ? typedIV : chosenIV

        if let position {
            let contractChanged = position.underlying != cleanTicker || position.optionType != optionType
                || position.strike != strike || !sameDay(position.expiration, expirationDay)
            position.underlying = cleanTicker
            position.optionType = optionType
            position.strike = strike
            position.expiration = expirationDay
            position.contracts = contracts
            position.averagePrice = averagePrice
            position.hyperliquidSymbol = cleanSymbol
            if isManual && ivEdited {
                position.lastIV = newIV
            } else if contractChanged {
                position.lastIV = chosenIV  // the old contract's IV no longer applies
            }
            try? context.save()
            onSave(position)
        } else {
            let newPosition = Position(underlying: cleanTicker, optionType: optionType, strike: strike,
                                       expiration: expirationDay, contracts: contracts,
                                       averagePrice: averagePrice, hyperliquidSymbol: cleanSymbol)
            newPosition.lastIV = newIV  // so it can be valued right away
            context.insert(newPosition)
            try? context.save()
            onSave(newPosition)
        }
        dismiss()
    }
}

// MARK: - Strike list

/// The strikes of one expiration: a caption header over a bordered list that opens centered on the money.
private struct StrikeList: View {
    let rows: [OptionQuote]
    @Binding var selection: OptionQuote.ID?
    let spot: Double?  // the underlying's price, if known
    let placeholder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StrikeColumns(cells: ["Strike", "Bid", "Ask", "IV", "Delta", "Volume"])
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)  // the bordered list's row inset
                .accessibilityHidden(true)
            ScrollViewReader { proxy in
                List(rows, selection: $selection) { quote in
                    StrikeRow(quote: quote)
                }
                .listStyle(.bordered)
                .frame(height: 200)
                .overlay { placeholderText }
                .onAppear { scrollToMoney(proxy) }
                .onChange(of: rows.map(\.id)) { scrollToMoney(proxy) }
            }
        }
    }

    @ViewBuilder private var placeholderText: some View {
        if rows.isEmpty, let placeholder {
            Text(placeholder)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
        }
    }

    /// Centers the chosen row, else the strike nearest the underlying's price, else the row whose |delta|
    /// is closest to 0.5, else the middle row.
    private func scrollToMoney(_ proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let chosen = rows.first { $0.id == selection }
        let nearestStrike = spot.flatMap { spot in rows.min { abs($0.strike - spot) < abs($1.strike - spot) } }
        let withDelta = rows.filter { $0.delta != nil }
        let halfDelta = withDelta.min { abs(abs($0.delta ?? 0) - 0.5) < abs(abs($1.delta ?? 0) - 0.5) }
        let target = chosen ?? nearestStrike ?? halfDelta ?? rows[rows.count / 2]
        // The list lays out its new rows first.
        Task { @MainActor in
            proxy.scrollTo(target.id, anchor: .center)
        }
    }
}

/// One contract in the strike list.
private struct StrikeRow: View {
    let quote: OptionQuote

    var body: some View {
        StrikeColumns(cells: [price(quote.strike), price(quote.bid), price(quote.ask),
                              percent(quote.impliedVolatility), deltaText, volumeText])
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Strike \(price(quote.strike)), bid \(price(quote.bid)), ask \(price(quote.ask)), "
                + "IV \(percent(quote.impliedVolatility)), delta \(deltaText), volume \(volumeText)")
    }

    private var deltaText: String {
        quote.delta.map { $0.formatted(.number.locale(usLocale).precision(.fractionLength(2))) } ?? "–"
    }

    private var volumeText: String {
        quote.volume.map { $0.formatted(.number.locale(usLocale).precision(.fractionLength(0))) } ?? "–"
    }
}

/// Six equal columns: the first leading, the rest trailing. Shared by the header and the rows.
private struct StrikeColumns: View {
    let cells: [String]

    var body: some View {
        HStack(spacing: 12) {
            Text(cells[0])
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(1..<cells.count, id: \.self) { index in
                Text(cells[index])
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .lineLimit(1)
    }
}

/// A right-aligned text field for a number, typed as text so totals and validation update live.
private struct NumberField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var width: CGFloat = 90

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
    }
}

// MARK: - Helpers

/// A number for a text field, with at least `decimals` decimals: "49", "49.5", "6.20".
private func plainNumber(_ value: Double, decimals: Int = 0) -> String {
    value.formatted(.number.locale(usLocale).grouping(.never).precision(.fractionLength(decimals...6)))
}

/// An implied volatility (a fraction) as a percent with one decimal: 0.627 → "62.7".
private func ivText(_ fraction: Double) -> String {
    (fraction * 100).formatted(.number.locale(usLocale).grouping(.never).precision(.fractionLength(1)))
}

/// Reads "1,234.5" or "$2.31" as a number.
private func parseNumber(_ text: String) -> Double? {
    Double(text.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "$", with: ""))
}

private func sameDay(_ first: Date, _ second: Date) -> Bool {
    easternCalendar.isDate(first, inSameDayAs: second)
}
