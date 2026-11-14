import Foundation

/// Latest market data for one option contract.
struct OptionQuote: Identifiable, Sendable {
    let symbol: String  // OCC symbol, e.g. DRAM270219C00049000
    let underlying: String
    let type: OptionType
    let strike: Double
    let expiration: Date
    let bid: Double?
    let ask: Double?
    let last: Double?
    let impliedVolatility: Double?
    let delta: Double?
    let volume: Double?

    var id: String { symbol }

    /// Mid of bid and ask, else the last trade.
    var mid: Double? {
        if let bid, let ask, bid > 0, ask > 0 { return (bid + ask) / 2 }
        return last
    }
}

/// The expiration a chain opens on: the first one at least 28 days away (calendar days in Eastern time),
/// else the last one. `expirations` is sorted, nearest first.
func defaultExpiration(_ expirations: [Date], now: Date = .now) -> Date? {
    let calendar = easternCalendar
    let today = calendar.startOfDay(for: now)
    let fourWeeksOut = calendar.date(byAdding: .day, value: 28, to: today) ?? today
    return expirations.first { calendar.startOfDay(for: $0) >= fourWeeksOut } ?? expirations.last
}

/// The expiration a typed-in contract starts on: the first standard monthly expiration (the third Friday
/// of a month) at least 28 days away, counting calendar days in Eastern time.
func defaultMonthlyExpiration(now: Date = .now) -> Date {
    let calendar = easternCalendar
    let today = calendar.startOfDay(for: now)
    let fourWeeksOut = calendar.date(byAdding: .day, value: 28, to: today) ?? today
    // The third Friday of the month four weeks out, unless it comes before that day: then the next month's.
    var thirdFriday = calendar.dateComponents([.year, .month], from: fourWeeksOut)
    thirdFriday.weekday = 6  // Friday
    thirdFriday.weekdayOrdinal = 3
    if let day = calendar.date(from: thirdFriday), day >= fourWeeksOut { return day }
    thirdFriday.month = (thirdFriday.month ?? 1) + 1  // month 13 rolls over into January
    return calendar.date(from: thirdFriday) ?? fourWeeksOut
}

/// The US stock market's trading session right now.
enum MarketSession: String, Sendable {
    case pre, regular, post, closed

    /// From an Alpaca clock phase: pre, core or lunch (regular), post, closed.
    init(phase: String) {
        switch phase {
        case "pre": self = .pre
        case "core", "lunch": self = .regular
        case "post": self = .post
        default: self = .closed
        }
    }

    /// Estimated from Eastern time when Alpaca's clock is unavailable. Weekdays 4:00–9:30 pre-market,
    /// 9:30–16:00 regular, 16:00–20:00 after hours, otherwise closed. Ignores holidays.
    static func estimated(at date: Date) -> MarketSession {
        let parts = easternCalendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard (2...6).contains(parts.weekday ?? 1) else { return .closed }
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        switch minutes {
        case 240..<570: return .pre        // 4:00–9:30
        case 570..<960: return .regular    // 9:30–16:00
        case 960..<1200: return .post      // 16:00–20:00
        default: return .closed
        }
    }

    /// "Open", "Pre-market", "After hours" or "Closed".
    var label: String {
        switch self {
        case .pre: "Pre-market"
        case .regular: "Open"
        case .post: "After hours"
        case .closed: "Closed"
        }
    }

    /// Stocks trade on Alpaca: pre-market, regular hours or after hours.
    var isTrading: Bool { self != .closed }
}

struct AlpacaError: LocalizedError {
    let errorDescription: String?
}

/// Alpaca market data (stocks and options). Uses whichever feed the account is subscribed to:
/// SIP/OPRA with a paid plan, otherwise IEX for stocks and the indicative feed for options.
struct AlpacaClient {
    let keyID: String
    let secretKey: String

    /// The most chain pages (of 1,000 contracts each) that `chain` will load.
    static let maxChainPages = 20

    var hasKeys: Bool { !keyID.isEmpty && !secretKey.isEmpty }

    /// Latest trade price for each stock symbol.
    func stockPrices(_ symbols: [String]) async throws -> [String: Double] {
        struct Trade: Decodable { let p: Double }  // p = price
        struct Response: Decodable { let trades: [String: Trade] }
        let response: Response = try await get("https://data.alpaca.markets/v2/stocks/trades/latest",
                                               ["symbols": symbols.joined(separator: ",")])
        return response.trades.mapValues(\.p)
    }

    /// Latest quote, trade and IV for up to 100 option contracts, keyed by OCC symbol.
    func optionQuotes(_ symbols: [String]) async throws -> [String: OptionQuote] {
        let response: SnapshotsResponse = try await get("https://data.alpaca.markets/v1beta1/options/snapshots",
                                                        ["symbols": symbols.joined(separator: ",")])
        return Dictionary(uniqueKeysWithValues: response.quotes.map { ($0.symbol, $0) })
    }

    /// Every contract of one type expiring today or later, sorted by expiration then strike.
    /// Follows `next_page_token` until there are no more pages, at most `maxChainPages` pages.
    func chain(underlying: String, type: OptionType) async throws -> [OptionQuote] {
        let ticker = underlying.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? underlying
        var query = [
            "type": type.rawValue,
            "expiration_date_gte": dayFormatter.string(from: .now),
            "limit": "1000",
        ]
        var quotes: [OptionQuote] = []
        for _ in 0..<Self.maxChainPages {
            let response: SnapshotsResponse = try await get("https://data.alpaca.markets/v1beta1/options/snapshots/\(ticker)", query)
            quotes += response.quotes
            guard let token = response.nextPageToken else { break }
            query["page_token"] = token
        }
        return quotes.sorted { ($0.expiration, $0.strike) < ($1.expiration, $1.strike) }
    }

    /// The current market session. Alpaca's market clock (which knows holidays) is on the trading API,
    /// so try the live host, then paper. If neither answers, estimate it from Eastern time.
    func marketSession() async -> MarketSession {
        struct Clock: Decodable { let phase: String }  // closed, pre, core, lunch or post
        struct Response: Decodable { let clocks: [Clock] }
        for host in ["https://api.alpaca.markets", "https://paper-api.alpaca.markets"] {
            if let response: Response = try? await get("\(host)/v3/clock", ["markets": "NYSE"]),
               let clock = response.clocks.first {
                return MarketSession(phase: clock.phase)
            }
        }
        return .estimated(at: .now)
    }

    private func get<T: Decodable>(_ url: String, _ query: [String: String]) async throws -> T {
        guard hasKeys else {
            throw AlpacaError(errorDescription: "Add your Alpaca API keys in Settings (⌘,).")
        }
        var components = URLComponents(string: url)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let requestURL = components?.url else {
            throw AlpacaError(errorDescription: "Alpaca: invalid request")
        }
        var request = URLRequest(url: requestURL)
        request.setValue(keyID, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(secretKey, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (try? JSONDecoder().decode(AlpacaErrorResponse.self, from: data))?.message
            let fallback = http.statusCode == 401 ? "API keys were rejected (HTTP 401)" : "HTTP \(http.statusCode)"
            throw AlpacaError(errorDescription: "Alpaca: \(message ?? fallback)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct AlpacaErrorResponse: Decodable {
    let message: String
}

/// Response of both option snapshot endpoints. Alpaca uses short field names:
/// bp/ap = bid/ask price, p = trade price, v = volume.
private struct SnapshotsResponse: Decodable {
    struct Snapshot: Decodable {
        struct Quote: Decodable { let bp: Double; let ap: Double }
        struct Trade: Decodable { let p: Double }
        struct Bar: Decodable { let v: Double }
        struct Greeks: Decodable { let delta: Double }
        let latestQuote: Quote?
        let latestTrade: Trade?
        let dailyBar: Bar?
        let greeks: Greeks?
        let impliedVolatility: Double?
    }

    let snapshots: [String: Snapshot]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case snapshots
        case nextPageToken = "next_page_token"
    }

    var quotes: [OptionQuote] {
        snapshots.compactMap { symbol, snapshot in
            guard let contract = parseOptionSymbol(symbol) else { return nil }
            return OptionQuote(
                symbol: symbol, underlying: contract.underlying, type: contract.type,
                strike: contract.strike, expiration: contract.expiration,
                bid: snapshot.latestQuote?.bp, ask: snapshot.latestQuote?.ap,
                last: snapshot.latestTrade?.p, impliedVolatility: snapshot.impliedVolatility,
                delta: snapshot.greeks?.delta, volume: snapshot.dailyBar?.v)
        }
    }
}

/// OCC option symbol: underlying, yyMMdd, C/P, strike × 1000 padded to 8 digits, e.g. DRAM270219C00049000.
func optionSymbol(underlying: String, type: OptionType, strike: Double, expiration: Date) -> String {
    let side = type == .call ? "C" : "P"
    let strikeDigits = String(format: "%08d", Int((strike * 1000).rounded()))
    return "\(underlying)\(occDateFormatter.string(from: expiration))\(side)\(strikeDigits)"
}

func parseOptionSymbol(_ symbol: String) -> (underlying: String, type: OptionType, strike: Double, expiration: Date)? {
    let tail = symbol.suffix(15)  // yyMMdd + C/P + 8 strike digits
    guard symbol.count > 15,
          let expiration = occDateFormatter.date(from: String(tail.prefix(6))),
          let strike = Double(tail.suffix(8)) else { return nil }
    let type: OptionType = tail.dropFirst(6).first == "P" ? .put : .call
    return (String(symbol.dropLast(15)), type, strike / 1000, expiration)
}

private let occDateFormatter = easternFormatter("yyMMdd")

/// Formats and parses YYYY-MM-DD dates in Eastern time.
let dayFormatter = easternFormatter("yyyy-MM-dd")

/// A fixed-format, US-English date formatter in Eastern time.
func easternFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = format
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = eastern
    return formatter
}
