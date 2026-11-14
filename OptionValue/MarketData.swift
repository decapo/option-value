import Foundation
import Observation

/// Everything fetched in one refresh, and the rules for which underlying price and IV to use.
struct MarketData {
    enum Source: Equatable { case alpaca, hyperliquid }

    struct Price: Equatable {
        let value: Double
        let source: Source
    }

    var stockPrices: [String: Double] = [:]  // Alpaca, by stock symbol
    var hyperliquidPrices: [String: Double] = [:]  // by Hyperliquid symbol, e.g. xyz:DRAM
    var optionQuotes: [String: OptionQuote] = [:]  // Alpaca, by OCC symbol
    var session = MarketSession.closed

    /// Alpaca while stocks trade (pre-market, regular or after hours). Hyperliquid when the market is closed,
    /// or when Alpaca has no price (no API keys, or the request failed). Alpaca's last price if there's no
    /// Hyperliquid price.
    func underlyingPrice(for position: Position) -> Price? {
        let alpaca = stockPrices[position.underlying]
        if let alpaca, session.isTrading {
            return Price(value: alpaca, source: .alpaca)
        }
        if let hyperliquid = hyperliquidPrices[position.hyperliquidSymbol] {
            return Price(value: hyperliquid, source: .hyperliquid)
        }
        return alpaca.map { Price(value: $0, source: .alpaca) }
    }

    func quote(for position: Position) -> OptionQuote? {
        optionQuotes[position.symbol]
    }

    /// The contract's market IV, or the last one we saw if Alpaca is unavailable.
    func impliedVolatility(for position: Position) -> Double? {
        quote(for: position)?.impliedVolatility ?? position.lastIV
    }

    /// Our fair value per share right now, from the current underlying price and the contract's IV.
    func syntheticValue(for position: Position, ratePercent: Double) -> Double? {
        guard let spot = underlyingPrice(for: position)?.value,
              let iv = impliedVolatility(for: position) else { return nil }
        return position.fairValue(spot: spot, at: .now, vol: iv, ratePercent: ratePercent)
    }
}

/// The app's shared state: settings, the latest market data and every valuation the views show.
/// Views read it with `@Environment(MarketStore.self)` and never call Alpaca or Hyperliquid themselves.
/// In demo mode it never touches the network or the saved settings; in ephemeral mode it uses the network
/// but never reads or writes the saved settings.
@MainActor @Observable
final class MarketStore {
    // MARK: Settings (saved to UserDefaults, except in demo and ephemeral mode)

    var alpacaKeyID: String { didSet { save(alpacaKeyID, "alpacaKeyID") } }
    var alpacaSecretKey: String { didSet { save(alpacaSecretKey, "alpacaSecretKey") } }
    var ratePercent: Double { didSet { save(ratePercent, "riskFreeRate") } }

    var hasAlpacaKeys: Bool { alpaca.hasKeys }

    // MARK: State

    private(set) var data = MarketData()
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    /// True when the last refresh could not reach Alpaca (so prices fall back to Hyperliquid).
    private(set) var alpacaFailed = false

    var session: MarketSession { data.session }

    init() {
        if DemoData.isEnabled {
            alpacaKeyID = DemoData.hasKeys ? "DEMO-KEY-ID" : ""
            alpacaSecretKey = DemoData.hasKeys ? "demo-secret" : ""
            ratePercent = 4.3
            data = DemoData.marketData(withKeys: DemoData.hasKeys)
            lastUpdated = .now
            errorMessage = DemoData.errorMessage
            alpacaFailed = DemoData.errorMessage?.hasPrefix("Alpaca") ?? false
        } else if DemoData.isEphemeral {
            alpacaKeyID = ""
            alpacaSecretKey = ""
            ratePercent = 4.3
        } else {
            let defaults = UserDefaults.standard
            alpacaKeyID = defaults.string(forKey: "alpacaKeyID") ?? ""
            alpacaSecretKey = defaults.string(forKey: "alpacaSecretKey") ?? ""
            ratePercent = defaults.object(forKey: "riskFreeRate") as? Double ?? 4.3
        }
    }

    /// Fetches prices, quotes and the market session for these positions, and remembers each contract's IV.
    func refresh(_ positions: [Position]) async {
        guard !positions.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if DemoData.isEnabled {
            data = DemoData.marketData(withKeys: hasAlpacaKeys)
            lastUpdated = .now
            return
        }

        var newData = MarketData()
        var problems: [String] = []
        var alpacaProblem = false
        let client = alpaca

        if client.hasKeys {
            do {
                newData.stockPrices = try await client.stockPrices(Array(Set(positions.map(\.underlying))))
                newData.optionQuotes = try await client.optionQuotes(positions.map(\.symbol))
            } catch {
                let message = error.localizedDescription
                problems.append(message.hasPrefix("Alpaca") ? message : "Alpaca: \(message)")
                alpacaProblem = true
            }
        }
        newData.session = await client.marketSession()

        let hyperliquidSymbols = positions.map(\.hyperliquidSymbol).filter { !$0.isEmpty }
        if !hyperliquidSymbols.isEmpty {
            do {
                newData.hyperliquidPrices = try await Hyperliquid.midPrices(for: hyperliquidSymbols)
            } catch {
                problems.append("Hyperliquid: \(error.localizedDescription)")
            }
        }

        // A refresh cancelled half-way (keys or positions changed) is replaced by a new one.
        guard !Task.isCancelled else { return }

        for position in positions {
            if let iv = newData.quote(for: position)?.impliedVolatility {
                position.lastIV = iv
            }
        }
        data = newData
        errorMessage = problems.isEmpty ? nil : problems.joined(separator: " · ")
        alpacaFailed = alpacaProblem
        lastUpdated = .now
    }

    // MARK: Valuation now

    func underlyingPrice(for position: Position) -> MarketData.Price? {
        data.underlyingPrice(for: position)
    }

    /// Bid, ask, last trade, IV, delta and volume.
    func quote(for position: Position) -> OptionQuote? {
        data.quote(for: position)
    }

    /// As a fraction, e.g. 0.627.
    func impliedVolatility(for position: Position) -> Double? {
        data.impliedVolatility(for: position)
    }

    /// Fair value per share right now.
    func syntheticValue(for position: Position) -> Double? {
        data.syntheticValue(for: position, ratePercent: ratePercent)
    }

    /// Synthetic value × contracts × 100.
    func marketValue(for position: Position) -> Double? {
        syntheticValue(for: position).map { $0 * position.shares }
    }

    /// Market value − cost basis.
    func profit(for position: Position) -> Double? {
        marketValue(for: position).map { $0 - position.costBasis }
    }

    // MARK: Valuation "what if" (per share)

    /// Value per share at an underlying price, moment and IV (a fraction).
    func value(of position: Position, spot: Double, at date: Date, vol: Double) -> Double {
        position.fairValue(spot: spot, at: date, vol: vol, ratePercent: ratePercent)
    }

    /// Value per share in a saved scenario.
    func value(of scenario: Scenario, for position: Position) -> Double {
        value(of: position, spot: scenario.underlyingPrice, at: scenario.date, vol: scenario.ivPercent / 100)
    }

    // MARK: Lookups for the editor and Settings

    /// Every contract of one type expiring today or later, sorted by expiration then strike.
    func chain(underlying: String, type: OptionType) async throws -> [OptionQuote] {
        let ticker = underlying.trimmingCharacters(in: .whitespaces).uppercased()
        if DemoData.isEnabled {
            try await Task.sleep(for: .seconds(0.3))
            guard hasAlpacaKeys else { throw AlpacaError(errorDescription: "Add your Alpaca API keys in Settings (⌘,).") }
            return DemoData.chain(underlying: ticker, type: type)
        }
        return try await alpaca.chain(underlying: ticker, type: type)
    }

    /// Hyperliquid mid price for a symbol such as xyz:DRAM, or nil if it isn't listed.
    func hyperliquidPrice(_ symbol: String) async -> Double? {
        let symbol = symbol.trimmingCharacters(in: .whitespaces)
        guard !symbol.isEmpty else { return nil }
        if DemoData.isEnabled {
            try? await Task.sleep(for: .seconds(0.3))
            return DemoData.hyperliquidPrices[symbol]
        }
        return try? await Hyperliquid.midPrices(for: [symbol])[symbol]
    }

    /// Finds the Hyperliquid symbol of a stock ticker (e.g. DRAM -> xyz:DRAM) on any of its exchanges, with
    /// its mid price. Nil when no exchange lists it or Hyperliquid can't be reached.
    func findHyperliquidSymbol(for ticker: String) async -> (symbol: String, price: Double)? {
        let ticker = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ticker.isEmpty else { return nil }
        if DemoData.isEnabled {
            try? await Task.sleep(for: .seconds(0.3))
            let symbol = "xyz:\(ticker)"
            return DemoData.hyperliquidPrices[symbol].map { (symbol, $0) }
        }
        return await Hyperliquid.findSymbol(for: ticker)
    }

    /// Latest trade price of a stock on Alpaca, or nil without keys or if the request fails.
    func stockPrice(_ ticker: String) async -> Double? {
        let ticker = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        if DemoData.isEnabled {
            try? await Task.sleep(for: .seconds(0.3))
            return hasAlpacaKeys ? DemoData.stockPrices[ticker] : nil
        }
        return try? await alpaca.stockPrices([ticker])[ticker]
    }

    /// Checks the Alpaca keys with one small request. Returns nil when they work, else the error text.
    func testAlpacaConnection() async -> String? {
        if DemoData.isEnabled {
            try? await Task.sleep(for: .seconds(0.3))
            return hasAlpacaKeys ? nil : "Add your Alpaca API keys in Settings (⌘,)."
        }
        do {
            _ = try await alpaca.stockPrices(["SPY"])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Private

    private var alpaca: AlpacaClient {
        AlpacaClient(keyID: alpacaKeyID, secretKey: alpacaSecretKey)
    }

    private func save(_ value: Any, _ key: String) {
        guard !DemoData.isEnabled && !DemoData.isEphemeral else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
