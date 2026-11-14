import Foundation

enum OptionType: String, CaseIterable, Identifiable, Codable {
    case call, put
    var id: Self { self }
}

let eastern = TimeZone(identifier: "America/New_York")!

var easternCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = eastern
    return calendar
}

/// Options stop trading at 4:00 PM ET on their expiration date.
func expirationMoment(_ day: Date) -> Date {
    easternCalendar.date(bySettingHour: 16, minute: 0, second: 0, of: day)!
}

func yearsBetween(_ start: Date, _ end: Date) -> Double {
    end.timeIntervalSince(start) / (365 * 24 * 60 * 60)
}

/// Black-Scholes price per share. `vol` and `rate` are decimals (0.62 = 62%).
/// At or after expiration the option is worth its intrinsic value.
func blackScholesPrice(type: OptionType, spot: Double, strike: Double, years: Double, vol: Double, rate: Double) -> Double {
    if years <= 0 || vol <= 0 {
        return intrinsicValue(type: type, spot: spot, strike: strike)
    }
    let volSqrtT = vol * years.squareRoot()
    let d1 = (log(spot / strike) + (rate + vol * vol / 2) * years) / volSqrtT
    let d2 = d1 - volSqrtT
    let discountedStrike = strike * exp(-rate * years)
    switch type {
    case .call: return spot * normalCDF(d1) - discountedStrike * normalCDF(d2)
    case .put: return discountedStrike * normalCDF(-d2) - spot * normalCDF(-d1)
    }
}

func intrinsicValue(type: OptionType, spot: Double, strike: Double) -> Double {
    switch type {
    case .call: return max(spot - strike, 0)
    case .put: return max(strike - spot, 0)
    }
}

private func normalCDF(_ x: Double) -> Double {
    0.5 * erfc(-x / 2.0.squareRoot())
}
