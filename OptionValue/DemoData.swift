import Foundation
import SwiftData
import SwiftUI

/// Demo mode, for building and checking the UI safely: launch with `-demo YES`. Sample positions live in
/// memory, market data is canned, and the user's saved positions, keys and settings are never touched.
///
/// Other launch arguments: `-demoAppearance light|dark`, `-demoEmpty YES`, `-demoKeys NO`,
/// `-demoError "<text>"`, `-demoTicker DRAM`.
///
/// Ephemeral mode, a clean slate for trying the app: launch with `-ephemeral YES`. The positions store is
/// in memory and starts empty, saved settings are neither read nor written, but the network is real.
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }

    /// `-ephemeral YES`: nothing is read from or written to disk. Demo mode wins when both are on.
    static var isEphemeral: Bool { UserDefaults.standard.bool(forKey: "ephemeral") }

    /// Forced color scheme (`-demoAppearance`), nil outside demo and ephemeral mode.
    static var appearance: ColorScheme? {
        guard isEnabled || isEphemeral else { return nil }
        switch UserDefaults.standard.string(forKey: "demoAppearance") {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// False with `-demoKeys NO`: behave as if no Alpaca keys were entered.
    static var hasKeys: Bool {
        UserDefaults.standard.object(forKey: "demoKeys") == nil || UserDefaults.standard.bool(forKey: "demoKeys")
    }

    /// `-demoError "<text>"`: shown as the store's error message.
    static var errorMessage: String? { UserDefaults.standard.string(forKey: "demoError") }

    /// `-demoTicker DRAM`: pre-fills the ticker of the new-position editor. Nil outside demo mode.
    static var ticker: String? {
        isEnabled ? UserDefaults.standard.string(forKey: "demoTicker") : nil
    }

    /// An in-memory store: the sample positions in demo mode, empty with `-demoEmpty YES` or in ephemeral mode.
    @MainActor static func makeContainer() -> ModelContainer {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Position.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Could not create the demo store: \(error)")
        }
        if isEnabled && !UserDefaults.standard.bool(forKey: "demoEmpty") {
            seed(container.mainContext)
        }
        return container
    }

    // MARK: Sample data

    /// Stock prices (Alpaca) of the sample tickers.
    static let stockPrices = ["DRAM": 43.66, "NVDA": 163.15, "TSLA": 412.60]

    /// Hyperliquid mid prices.
    static let hyperliquidPrices = ["xyz:DRAM": 42.83, "xyz:NVDA": 162.90, "xyz:TSLA": 413.05]

    /// Base implied volatility per ticker, used for the canned chains.
    private static let baseIV = ["DRAM": 0.627, "NVDA": 0.48, "TSLA": 0.52]

    /// Expiration days of the canned chains (third Fridays).
    private static let chainExpirations = ["2026-12-18", "2027-01-15", "2027-02-19", "2027-03-19"]

    /// Market data for the sample positions, as a refresh would return it. The market is closed.
    /// Without keys there are no Alpaca prices or quotes, as in the real app.
    static func marketData(withKeys: Bool) -> MarketData {
        var data = MarketData()
        data.session = .closed
        data.hyperliquidPrices = hyperliquidPrices
        guard withKeys else { return data }
        data.stockPrices = stockPrices
        let quotes = [
            quote("DRAM", .call, 49, "2027-02-19", bid: 3.40, ask: 4.25, last: 2.78, iv: 0.627, delta: 0.43, volume: 184),
            quote("NVDA", .call, 180, "2027-01-15", bid: 6.95, ask: 7.40, last: 7.10, iv: 0.48, delta: 0.36, volume: 8_421),
            quote("TSLA", .put, 400, "2026-12-18", bid: 18.90, ask: 19.55, last: 19.10, iv: 0.52, delta: -0.38, volume: 12_840),
        ]
        data.optionQuotes = Dictionary(uniqueKeysWithValues: quotes.map { ($0.symbol, $0) })
        return data
    }

    /// A canned option chain: four expirations with 25 strikes around the stock price, priced with
    /// Black-Scholes. Empty for tickers other than the sample ones.
    static func chain(underlying: String, type: OptionType) -> [OptionQuote] {
        guard let spot = stockPrices[underlying], let iv = baseIV[underlying] else { return [] }
        let step: Double = spot < 100 ? 1 : 5
        let center = (spot / step).rounded() * step
        var quotes: [OptionQuote] = []
        for day in chainExpirations {
            let expiration = date(day)
            guard expirationMoment(expiration) > .now else { continue }
            for offset in -12...12 {
                let strike = center + Double(offset) * step
                quotes.append(chainQuote(underlying, type, strike: strike, expiration: expiration, spot: spot, baseIV: iv))
            }
        }
        return quotes
    }

    // MARK: Private helpers

    private static func seed(_ context: ModelContext) {
        let start = Date.now.addingTimeInterval(-3_600)

        let dram = Position(underlying: "DRAM", optionType: .call, strike: 49, expiration: date("2027-02-19"),
                            contracts: 400, averagePrice: 2.31, hyperliquidSymbol: "xyz:DRAM")
        dram.lastIV = 0.627
        dram.createdAt = start
        let nvda = Position(underlying: "NVDA", optionType: .call, strike: 180, expiration: date("2027-01-15"),
                            contracts: 20, averagePrice: 9.80, hyperliquidSymbol: "xyz:NVDA")
        nvda.lastIV = 0.48
        nvda.createdAt = start.addingTimeInterval(60)
        let tsla = Position(underlying: "TSLA", optionType: .put, strike: 400, expiration: date("2026-12-18"),
                            contracts: 10, averagePrice: 14.50, hyperliquidSymbol: "xyz:TSLA")
        tsla.lastIV = 0.52
        tsla.createdAt = start.addingTimeInterval(120)
        for position in [dram, nvda, tsla] {
            context.insert(position)
        }

        let nextWeek = daysFromNow(7)
        addScenario(to: dram, name: "$50 on \(monthDayText(nextWeek))", price: 50, date: nextWeek, iv: 62.7, created: start)
        addScenario(to: dram, name: "", price: 58, date: daysFromNow(35), iv: 55.0, created: start.addingTimeInterval(60))
        addScenario(to: tsla, name: "", price: 380, date: daysFromNow(14), iv: 55.0, created: start.addingTimeInterval(120))
        try? context.save()
    }

    private static func addScenario(to position: Position, name: String, price: Double, date: Date,
                                    iv: Double, created: Date) {
        let scenario = Scenario(name: name, underlyingPrice: price, date: date, ivPercent: iv)
        scenario.createdAt = created
        position.scenarios.append(scenario)
    }

    /// 10:00 AM ET, a number of days from today.
    private static func daysFromNow(_ days: Int) -> Date {
        let calendar = easternCalendar
        let day = calendar.date(byAdding: .day, value: days, to: .now) ?? .now
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }

    /// A fixed YYYY-MM-DD day (midnight ET).
    private static func date(_ day: String) -> Date {
        dayFormatter.date(from: day) ?? .now
    }

    private static func quote(_ underlying: String, _ type: OptionType, _ strike: Double, _ day: String,
                              bid: Double, ask: Double, last: Double, iv: Double, delta: Double,
                              volume: Double) -> OptionQuote {
        let expiration = date(day)
        return OptionQuote(symbol: optionSymbol(underlying: underlying, type: type, strike: strike, expiration: expiration),
                           underlying: underlying, type: type, strike: strike, expiration: expiration,
                           bid: bid, ask: ask, last: last, impliedVolatility: iv, delta: delta, volume: volume)
    }

    /// One chain row: a small volatility smile, mid from Black-Scholes, a spread of 6% (at least 5 cents),
    /// delta by finite difference, and fewer trades further from the money.
    private static func chainQuote(_ underlying: String, _ type: OptionType, strike: Double, expiration: Date,
                                   spot: Double, baseIV: Double) -> OptionQuote {
        let years = yearsBetween(.now, expirationMoment(expiration))
        let distance = abs(strike / spot - 1)
        let iv = baseIV * (1 + 0.6 * distance)
        func value(_ s: Double) -> Double {
            blackScholesPrice(type: type, spot: s, strike: strike, years: years, vol: iv, rate: 0.043)
        }
        let mid = value(spot)
        let halfSpread = Swift.max(0.025, mid * 0.03)
        let cents = { (x: Double) in (x * 100).rounded() / 100 }
        let delta = (value(spot + 0.01) - value(spot - 0.01)) / 0.02
        return OptionQuote(symbol: optionSymbol(underlying: underlying, type: type, strike: strike, expiration: expiration),
                           underlying: underlying, type: type, strike: strike, expiration: expiration,
                           bid: cents(Swift.max(0.01, mid - halfSpread)), ask: cents(mid + halfSpread),
                           last: cents(mid), impliedVolatility: iv, delta: (delta * 100).rounded() / 100,
                           volume: (2_000 / (1 + 40 * distance)).rounded())
    }
}
