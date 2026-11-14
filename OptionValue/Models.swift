import Foundation
import SwiftData

// The stored properties of both models must not change: the user's saved store has to keep loading.

/// A saved option position. Persisted with SwiftData between launches.
@Model
final class Position {
    var underlying: String
    var optionType: OptionType
    var strike: Double
    var expiration: Date  // any moment on the expiration day (ET)
    var contracts: Int
    var averagePrice: Double  // per share
    var hyperliquidSymbol: String = ""  // e.g. xyz:DRAM, for underlying prices while the market is closed
    /// The IV used when there is no live quote: the last one from Alpaca, or the one the user typed.
    var lastIV: Double?
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Scenario.position)
    var scenarios: [Scenario] = []

    init(underlying: String, optionType: OptionType, strike: Double, expiration: Date,
         contracts: Int, averagePrice: Double, hyperliquidSymbol: String) {
        self.underlying = underlying
        self.optionType = optionType
        self.strike = strike
        self.expiration = expiration
        self.contracts = contracts
        self.averagePrice = averagePrice
        self.hyperliquidSymbol = hyperliquidSymbol
        self.createdAt = .now
    }
}

/// A saved "what if" for a position: underlying price, moment and IV.
@Model
final class Scenario {
    var name: String
    var underlyingPrice: Double
    var date: Date
    var ivPercent: Double
    var createdAt: Date
    var position: Position?

    init(name: String, underlyingPrice: Double, date: Date, ivPercent: Double) {
        self.name = name
        self.underlyingPrice = underlyingPrice
        self.date = date
        self.ivPercent = ivPercent
        self.createdAt = .now
    }
}

// Spelled out so `Position.ID` and `Scenario.ID` resolve in every file. With Swift 6.4 the alias that
// @Model generates is "inaccessible" from other files when they are type-checked file by file.
extension Position { typealias ID = PersistentIdentifier }
extension Scenario { typealias ID = PersistentIdentifier }

extension Position {
    /// OCC option symbol, e.g. DRAM270219C00049000.
    var symbol: String {
        optionSymbol(underlying: underlying, type: optionType, strike: strike, expiration: expiration)
    }

    /// Compact name, e.g. DRAM Feb 19 '27 49C.
    var name: String {
        "\(underlying) \(expirationText) \(strike.formatted())\(optionType == .call ? "C" : "P")"
    }

    /// Display title, e.g. "DRAM $49 Call" or "DRAM $49.50 Put".
    var title: String {
        "\(underlying) \(strikeText) \(optionType == .call ? "Call" : "Put")"
    }

    /// Strike without trailing zeros: "$49", "$49.50".
    var strikeText: String { strikeLabel(strike) }

    /// "Feb 19 '27"
    var expirationText: String { shortDateText(expiration) }

    /// "Feb 19, 2027"
    var longExpirationText: String { longDateText(expiration) }

    /// Days from now until 4:00 PM ET on the expiration day; negative once expired.
    var daysToExpiration: Double {
        expirationMoment(expiration).timeIntervalSinceNow / 86_400
    }

    /// "98 days", "1 day", "Expires today" or "Expired".
    var countdownText: String { expiryCountdown(expiration) }

    /// Underlying price at which the position breaks even at expiry.
    var breakEven: Double {
        optionType == .call ? strike + averagePrice : strike - averagePrice
    }

    /// Scenarios, oldest first. A scenario's color is its index in this list.
    var sortedScenarios: [Scenario] {
        scenarios.sorted { $0.createdAt < $1.createdAt }
    }

    var shares: Double { Double(contracts * 100) }
    var costBasis: Double { averagePrice * shares }

    /// "12.6% OTM", "3.1% ITM" or "At the money" (within 0.5% of the strike).
    func moneynessText(spot: Double) -> String {
        let distance = abs(spot - strike) / strike
        if distance < 0.005 { return "At the money" }
        let inTheMoney = optionType == .call ? spot > strike : spot < strike
        return "\(percent(distance)) \(inTheMoney ? "ITM" : "OTM")"
    }

    /// Black-Scholes value per share at a given underlying price, moment and IV.
    func fairValue(spot: Double, at date: Date, vol: Double, ratePercent: Double) -> Double {
        blackScholesPrice(type: optionType, spot: spot, strike: strike,
                          years: yearsBetween(date, expirationMoment(expiration)),
                          vol: vol, rate: ratePercent / 100)
    }
}

extension Scenario {
    /// The name, or "$50 on Nov 20" when the name is empty.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? autoTitle : trimmed
    }

    /// The automatic title, without cents for whole dollars: "$50 on Nov 20", "$50.50 on Nov 20".
    var autoTitle: String {
        "\(strikeLabel(underlyingPrice)) on \(monthDayText(date))"
    }

    /// "$50.00 · Nov 20, 10:00 AM · IV 62.7%"
    var summary: String {
        "\(price(underlyingPrice)) · \(monthDayTimeText(date)) · IV \(percent(ivPercent / 100))"
    }
}
