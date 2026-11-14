// Tests of AlpacaClient, Hyperliquid, MarketData, MarketStore (demo and ephemeral mode), the demo data, the
// number formats and the model helpers. Run them with Tests/run.sh.
// No real network: Alpaca's and Hyperliquid's hosts are answered by a URLProtocol stub. The app's saved
// positions and preferences are never read: this program has its own preferences domain, and the settings
// it needs are registered as volatile defaults.
import Foundation
import SwiftData

nonisolated(unsafe) var clockPhase = "pre"        // phase the clock answers with
nonisolated(unsafe) var liveClockFails = true     // live host answers 401 (paper still answers)
nonisolated(unsafe) var allClocksFail = false
nonisolated(unsafe) var requests: [String] = []
nonisolated(unsafe) var loopPages = 0              // requests served for the endless LOOP chain
// Hyperliquid: the allMids answer of each exchange ("" is the main one), the perpDexs answer, and a switch
// that makes every request fail as if the network were down.
nonisolated(unsafe) var hlMids = [
    "": #"{"BTC":"90000.5"}"#,
    "xyz": #"{"xyz:DRAM":"42.99","xyz:TSLA":"413.1"}"#,
    "flx": #"{"flx:GOLD":"2650.0"}"#,
    "km": #"{"km:PLTR":"180.5"}"#,
]
nonisolated(unsafe) var hlDexList = #"[null,{"name":"xyz","fullName":"XYZ","deployer":"0x1"},{"name":"flx","fullName":"Felix"},{"name":"km","fullName":"Kinetiq"}]"#
nonisolated(unsafe) var hlDown = false
nonisolated(unsafe) var hlRequests: [String] = []  // "allMids xyz", "perpDexs", …

final class StubNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.contains("alpaca.markets") || host.contains("hyperliquid.xyz")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var status = 200, body = ""
        if url.host!.contains("hyperliquid.xyz") {
            let fields = (try? JSONDecoder().decode([String: String].self, from: bodyData())) ?? [:]
            let type = fields["type"] ?? "?"
            hlRequests.append(type == "allMids" ? "allMids \(fields["dex"] ?? "?")" : type)
            if hlDown {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            body = type == "perpDexs" ? hlDexList : hlMids[fields["dex"] ?? ""] ?? "{}"
        } else {
            let auth = request.value(forHTTPHeaderField: "APCA-API-KEY-ID") == "key" && request.value(forHTTPHeaderField: "APCA-API-SECRET-KEY") == "secret"
            requests.append("\(url.host!)\(url.path)?\(url.query ?? "") auth=\(auth)")
            (status, body) = alpaca(url)
            if !auth { status = 401; body = "<html>401 Authorization Required</html>" }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands the POST body to a URLProtocol as a stream.
    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func alpaca(_ url: URL) -> (Int, String) {
        let pageToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page_token" }?.value
        switch url.path {
        case "/v2/stocks/trades/latest":
            return (200, #"{"trades":{"DRAM":{"c":["@"],"i":826,"p":43.1,"s":100,"t":"2026-11-13T15:00:00.123456789Z","x":"V","z":"B"}},"currency":"USD"}"#)
        case "/v1beta1/options/snapshots":
            return (200, #"{"snapshots":{"DRAM270219C00049000":{"greeks":{"delta":0.43,"gamma":0.03,"rho":0.04,"theta":-0.03,"vega":0.09},"impliedVolatility":0.627,"latestQuote":{"ap":4.25,"as":162,"ax":"C","bp":3.4,"bs":180,"bx":"C","c":"A","t":"2026-11-13T15:00:00Z"},"latestTrade":{"c":"I","p":2.78,"s":1,"t":"2026-11-13T14:00:00Z","x":"C"},"dailyBar":{"c":2.78,"h":2.8,"l":2.7,"n":3,"o":2.7,"t":"2026-11-13T05:00:00Z","v":12,"vw":2.75}}},"next_page_token":null}"#)
        case "/v1beta1/options/snapshots/DRAM":
            if pageToken == nil {  // page 1 of 2
                return (200, #"{"snapshots":{"DRAM270319C00050000":{"latestQuote":{"ap":4.6,"as":1,"ax":"C","bp":4.1,"bs":1,"bx":"C","c":"A","t":"2026-11-13T15:00:00Z"}},"DRAM270219C00049500":{"impliedVolatility":0.61,"greeks":{"delta":0.42,"gamma":0,"rho":0,"theta":0,"vega":0}}},"next_page_token":"page2"}"#)
            }
            if pageToken == "page2" {
                return (200, #"{"snapshots":{"DRAM270219C00049000":{"impliedVolatility":0.627}},"next_page_token":null}"#)
            }
            return (400, #"{"message":"bad page token"}"#)
        case "/v1beta1/options/snapshots/LOOP":  // never runs out of pages
            loopPages += 1
            let symbol = "LOOP270219C" + String(format: "%05d000", loopPages)
            return (200, #"{"snapshots":{"\#(symbol)":{"impliedVolatility":0.5}},"next_page_token":"more\#(loopPages)"}"#)
        case "/v3/clock":
            if allClocksFail || (liveClockFails && url.host == "api.alpaca.markets") {
                return (401, "<html>401 Authorization Required</html>")
            }
            return (200, #"{"clocks":[{"market":{"acronym":"NYSE","name":"New York Stock Exchange","timezone":"America/New_York","mic":"XNYS","bic":"XNYS"},"timestamp":"2026-11-13T08:00:00-05:00","is_market_day":true,"next_market_open":"2026-11-13T09:30:00-05:00","next_market_close":"2026-11-13T16:00:00-05:00","phase":"\#(clockPhase)","phase_until":"2026-11-13T09:30:00-05:00"}]}"#)
        default:
            return (404, #"{"message":"not found"}"#)
        }
    }
}
URLProtocol.registerClass(StubNetwork.self)

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS" : "FAIL", name)
    if ok { passes += 1 } else { failures += 1 }
}
func expect(_ name: String, _ actual: String, _ expected: String) {
    check("\(name): \"\(actual)\"" + (actual == expected ? "" : " (expected \"\(expected)\")"), actual == expected)
}

let client = AlpacaClient(keyID: "key", secretKey: "secret")
let expiry = dayFormatter.date(from: "2027-02-19")!
let et = DateFormatter(); et.timeZone = eastern; et.dateFormat = "yyyy-MM-dd HH:mm"; et.locale = Locale(identifier: "en_US_POSIX")
func etDate(_ s: String) -> Date { et.date(from: s)! }

print("— OCC symbols")
check("build OCC symbol", optionSymbol(underlying: "DRAM", type: .call, strike: 49, expiration: expiry) == "DRAM270219C00049000")
let parsed = parseOptionSymbol("DRAM270219P00049500")!
check("parse OCC symbol", parsed.underlying == "DRAM" && parsed.type == .put && parsed.strike == 49.5 && dayFormatter.string(from: parsed.expiration) == "2027-02-19")
check("reject short symbol", parseOptionSymbol("C00049000") == nil)

print("— Alpaca endpoints")
let stockPrices = try await client.stockPrices(["DRAM"])
check("stock latest trade", stockPrices == ["DRAM": 43.1])
let quotes = try await client.optionQuotes(["DRAM270219C00049000"])
let q = quotes["DRAM270219C00049000"]!
check("option snapshot fields", q.bid == 3.4 && q.ask == 4.25 && q.last == 2.78 && q.impliedVolatility == 0.627 && q.delta == 0.43 && q.volume == 12 && q.strike == 49 && q.type == .call)
do { _ = try await AlpacaClient(keyID: "bad", secretKey: "bad").stockPrices(["DRAM"]); check("bad keys throw", false) }
catch { expect("bad keys error", error.localizedDescription, "Alpaca: API keys were rejected (HTTP 401)") }
do { _ = try await AlpacaClient(keyID: "", secretKey: "").stockPrices(["DRAM"]); check("no keys throw", false) }
catch { check("no keys error: \(error.localizedDescription)", error.localizedDescription.contains("Settings")) }

print("— Chain paging")
requests = []
let twoPages = try await client.chain(underlying: "DRAM", type: .call)
let chainRequests = requests.filter { $0.contains("snapshots/DRAM") }
check("two pages loaded via page_token, stops at null token", chainRequests.count == 2 && chainRequests[1].contains("page_token=page2") && !chainRequests[0].contains("page_token"))
check("query: type, limit 1000, expiration_date_gte today", chainRequests[0].contains("type=call") && chainRequests[0].contains("limit=1000") && chainRequests[0].contains("expiration_date_gte=\(dayFormatter.string(from: .now))"))
check("pages merged, sorted by expiry then strike", twoPages.map(\.symbol) == ["DRAM270219C00049000", "DRAM270219C00049500", "DRAM270319C00050000"])
check("missing snapshot fields stay nil", twoPages[2].impliedVolatility == nil && twoPages[2].bid == 4.1 && twoPages[0].bid == nil)
loopPages = 0
let capped = try await client.chain(underlying: "LOOP", type: .put)
check("page cap: stops after \(AlpacaClient.maxChainPages) pages (got \(loopPages) requests, \(capped.count) contracts)", loopPages == 20 && capped.count == 20)
for r in chainRequests { print("   ", r) }

print("— Market session from Alpaca's clock")
liveClockFails = false; allClocksFail = false
for (phase, session) in [("pre", MarketSession.pre), ("core", .regular), ("lunch", .regular), ("post", .post), ("closed", .closed)] {
    clockPhase = phase
    check("live clock phase \(phase) -> \(session)", await client.marketSession() == session)
}
liveClockFails = true; clockPhase = "core"
check("live 401, paper says core -> regular", await client.marketSession() == .regular)
allClocksFail = true
check("both clocks fail -> Eastern-time estimate", await client.marketSession() == MarketSession.estimated(at: .now))
check("no keys -> Eastern-time estimate", await AlpacaClient(keyID: "", secretKey: "").marketSession() == MarketSession.estimated(at: .now))

print("— Market session estimated from Eastern time (Fri 2026-11-13, Sat 2026-11-14)")
for (time, session) in [("2026-11-13 03:59", MarketSession.closed), ("2026-11-13 04:00", .pre), ("2026-11-13 09:29", .pre),
                        ("2026-11-13 09:30", .regular), ("2026-11-13 15:59", .regular), ("2026-11-13 16:00", .post),
                        ("2026-11-13 19:59", .post), ("2026-11-13 20:00", .closed), ("2026-11-14 12:00", .closed),
                        ("2026-11-15 10:00", .closed)] {
    check("\(time) ET -> \(session)", MarketSession.estimated(at: etDate(time)) == session)
}
check("labels", [MarketSession.pre, .regular, .post, .closed].map(\.label) == ["Pre-market", "Open", "After hours", "Closed"])
check("isTrading", MarketSession.pre.isTrading && MarketSession.regular.isTrading && MarketSession.post.isTrading && !MarketSession.closed.isTrading)

print("— Hyperliquid (stubbed)")
let hl = try await Hyperliquid.midPrices(for: ["xyz:DRAM", "BTC"])
check("Hyperliquid xyz + core dex", hl["xyz:DRAM"] == 42.99 && hl["BTC"] == 90000.5)

print("— Hyperliquid symbol search (stubbed)")
func search(_ ticker: String) async -> String {
    hlRequests = []
    guard let found = await Hyperliquid.findSymbol(for: ticker) else { return "nil" }
    return "\(found.symbol) \(found.price)"
}
expect("found on xyz (trimmed, uppercased)", await search(" dram "), "xyz:DRAM 42.99")
check("found on xyz: one allMids request, no perpDexs (\(hlRequests))", hlRequests == ["allMids xyz"])
expect("not on xyz, found on a later exchange", await search("PLTR"), "km:PLTR 180.5")
check("then perpDexs, every other exchange in order, skipping null and xyz (\(hlRequests))",
      hlRequests == ["allMids xyz", "perpDexs", "allMids flx", "allMids km"])
expect("found nowhere", await search("SPY"), "nil")
check("found nowhere: every exchange asked once (\(hlRequests))", hlRequests == ["allMids xyz", "perpDexs", "allMids flx", "allMids km"])
hlDexList = "[null]"
expect("only the main exchange (null) besides xyz", await search("PLTR"), "nil")
check("the main exchange is not searched (\(hlRequests))", hlRequests == ["allMids xyz", "perpDexs"])
hlDexList = #"[null,{"name":"xyz"},{"name":"flx"},{"name":"km"}]"#
hlDown = true
expect("network error", await search("DRAM"), "nil")
hlDown = false
hlMids["xyz"] = "<html>502 Bad Gateway</html>"
expect("unreadable answer", await search("DRAM"), "nil")
hlMids["xyz"] = #"{"xyz:DRAM":"42.99","xyz:TSLA":"413.1"}"#
expect("empty ticker", await search("  "), "nil")
check("empty ticker: no request", hlRequests.isEmpty)

print("— Number formats")
expect("price", price(3.52), "$3.52")
expect("price whole", price(50), "$50.00")
expect("price nil", price(nil), "–")
expect("money ≥ 1,000", money(140_779.4), "$140,779")
expect("money < 1,000", money(924.5), "$924.50")
expect("money negative", money(-1_204.3), "-$1,204")
expect("signedMoney gain", signedMoney(48_379.2), "+$48,379")
expect("signedMoney loss", signedMoney(-1_204), "-$1,204")
expect("signedMoney small loss", signedMoney(-12.5), "-$12.50")
expect("signedMoney zero", signedMoney(0), "$0.00")
expect("signedMoney nil", signedMoney(nil), "–")
expect("signedPercent gain", signedPercent(0.524), "+52.4%")
expect("signedPercent loss", signedPercent(-0.1), "-10.0%")
expect("percent", percent(0.627), "62.7%")
expect("percent nil", percent(nil), "–")
expect("strikeLabel whole", strikeLabel(49), "$49")
expect("strikeLabel half", strikeLabel(49.5), "$49.50")
expect("strikeLabel thousands", strikeLabel(1_250), "$1,250")
expect("contractsText one", contractsText(1), "1 contract")
expect("contractsText many", contractsText(1_430), "1,430 contracts")

print("— OptionQuote.mid")
func midQuote(bid: Double?, ask: Double?, last: Double?) -> OptionQuote {
    OptionQuote(symbol: "X", underlying: "X", type: .call, strike: 1, expiration: .now, bid: bid, ask: ask,
                last: last, impliedVolatility: nil, delta: nil, volume: nil)
}
check("mid of bid and ask", midQuote(bid: 3.40, ask: 4.25, last: 2.78).mid == 3.825)
check("mid falls back to last without a bid", midQuote(bid: nil, ask: 4.25, last: 2.78).mid == 2.78)
check("mid falls back to last with a zero bid", midQuote(bid: 0, ask: 0.05, last: 0.02).mid == 0.02)
check("mid nil without quotes", midQuote(bid: nil, ask: nil, last: nil).mid == nil)

print("— Default expiration of a chain")
func days(_ list: [String]) -> [Date] { list.map { dayFormatter.date(from: $0)! } }
func defaultDay(_ expirations: [Date], now: String) -> String {
    defaultExpiration(expirations, now: etDate(now)).map { dayFormatter.string(from: $0) } ?? "nil"
}
let monthlies = days(["2026-12-18", "2027-01-15", "2027-02-19", "2027-03-19"])
let weeklies = days(["2026-11-13", "2026-11-20", "2026-11-27", "2026-12-04", "2026-12-11", "2026-12-18"])
expect("first expiration at least 28 days away", defaultDay(monthlies, now: "2026-11-13 10:00"), "2026-12-18")
expect("skips today and the weeklies, 28 days counts", defaultDay(weeklies, now: "2026-11-13 21:00"), "2026-12-11")
expect("28 days away late in the evening", defaultDay(monthlies, now: "2026-11-20 23:30"), "2026-12-18")
expect("27 days away is too near", defaultDay(monthlies, now: "2026-11-21 09:00"), "2027-01-15")
expect("none 28 days away -> the last one", defaultDay(monthlies, now: "2027-02-25 10:00"), "2027-03-19")
expect("only expirations this week -> the last one", defaultDay(Array(weeklies.prefix(2)), now: "2026-11-13 10:00"), "2026-11-20")
expect("empty chain -> nil", defaultDay([], now: "2026-11-13 10:00"), "nil")

print("— Default expiration of a typed-in contract (third Friday at least 28 days away)")
func monthlyDay(now: String) -> String { dayFormatter.string(from: defaultMonthlyExpiration(now: etDate(now))) }
expect("Sat Nov 14 -> Dec 18", monthlyDay(now: "2026-11-14 12:00"), "2026-12-18")
expect("Nov 25: Dec 18 is only 23 days away -> Jan 15", monthlyDay(now: "2026-11-25 12:00"), "2027-01-15")
expect("on a third Friday (Nov 20) -> the next one, 28 days counts", monthlyDay(now: "2026-11-20 10:00"), "2026-12-18")
expect("year boundary: Dec 1 '27, Dec 17 too near -> Jan 21 '28", monthlyDay(now: "2027-12-01 10:00"), "2028-01-21")

print("— Position helpers")
let dram = Position(underlying: "DRAM", optionType: .call, strike: 49, expiration: expiry, contracts: 400, averagePrice: 2.31, hyperliquidSymbol: "xyz:DRAM")
let halfStrike = Position(underlying: "DRAM", optionType: .call, strike: 49.5, expiration: expiry, contracts: 1, averagePrice: 1, hyperliquidSymbol: "")
let spy = Position(underlying: "SPY", optionType: .put, strike: 580, expiration: dayFormatter.date(from: "2026-12-18")!, contracts: 10, averagePrice: 6.2, hyperliquidSymbol: "")
expect("title", dram.title, "DRAM $49 Call")
expect("title half strike", halfStrike.title, "DRAM $49.50 Call")
expect("title put", spy.title, "SPY $580 Put")
expect("name (unchanged)", dram.name, "DRAM Feb 19 '27 49C")
expect("expirationText", dram.expirationText, "Feb 19 '27")
expect("longExpirationText", dram.longExpirationText, "Feb 19, 2027")
expect("countdown 98 days", expiryCountdown(expiry, now: etDate("2026-11-13 10:00")), "98 days")
expect("countdown late evening", expiryCountdown(expiry, now: etDate("2026-11-13 23:30")), "98 days")
expect("countdown 1 day", expiryCountdown(expiry, now: etDate("2027-02-18 18:00")), "1 day")
expect("countdown today", expiryCountdown(expiry, now: etDate("2027-02-19 15:59")), "Expires today")
expect("countdown at 4 PM", expiryCountdown(expiry, now: etDate("2027-02-19 16:00")), "Expired")
expect("countdown next day", expiryCountdown(expiry, now: etDate("2027-02-20 09:00")), "Expired")
expect("countdownText uses now", dram.countdownText, expiryCountdown(expiry))
check("daysToExpiration positive before expiry", dram.daysToExpiration > 0 && abs(dram.daysToExpiration - expirationMoment(expiry).timeIntervalSinceNow / 86_400) < 0.001)
expect("moneyness call OTM", dram.moneynessText(spot: 42.83), "12.6% OTM")
expect("moneyness call ITM", dram.moneynessText(spot: 50.5), "3.1% ITM")
expect("moneyness at the money", dram.moneynessText(spot: 49.2), "At the money")
expect("moneyness put OTM", spy.moneynessText(spot: 598.4), "3.2% OTM")
expect("moneyness put ITM", spy.moneynessText(spot: 560), "3.4% ITM")
check("breakEven call = strike + avg", abs(dram.breakEven - 51.31) < 1e-9)
check("breakEven put = strike − avg", abs(spy.breakEven - 573.8) < 1e-9)

print("— Scenario helpers")
let unnamed = Scenario(name: "", underlyingPrice: 50, date: etDate("2026-11-20 10:00"), ivPercent: 62.7)
let blank = Scenario(name: "   ", underlyingPrice: 58, date: etDate("2026-12-18 10:00"), ivPercent: 55)
let named = Scenario(name: "Earnings pop", underlyingPrice: 50, date: etDate("2026-11-20 10:00"), ivPercent: 62.7)
let cents = Scenario(name: "", underlyingPrice: 58.5, date: etDate("2026-12-18 10:00"), ivPercent: 55)
expect("auto title", unnamed.title, "$50 on Nov 20")
expect("blank name -> auto title", blank.title, "$58 on Dec 18")
expect("auto title keeps cents", cents.title, "$58.50 on Dec 18")
expect("named title", named.title, "Earnings pop")
expect("summary", unnamed.summary, "$50.00 · Nov 20, 10:00 AM · IV 62.7%")

print("— Underlying price rules")
let noHL = Position(underlying: "DRAM", optionType: .call, strike: 49, expiration: expiry, contracts: 400, averagePrice: 2.31, hyperliquidSymbol: "")
var m = MarketData(stockPrices: ["DRAM": 43.1], hyperliquidPrices: ["xyz:DRAM": 42.99], optionQuotes: quotes, session: .regular)
for session in [MarketSession.pre, .regular, .post] {
    m.session = session
    check("\(session) + Alpaca price -> Alpaca", m.underlyingPrice(for: dram) == MarketData.Price(value: 43.1, source: .alpaca))
}
m.session = .closed
check("closed + HL price -> Hyperliquid", m.underlyingPrice(for: dram) == MarketData.Price(value: 42.99, source: .hyperliquid))
check("closed + no HL symbol -> Alpaca last", m.underlyingPrice(for: noHL) == MarketData.Price(value: 43.1, source: .alpaca))
m.stockPrices = [:]; m.session = .regular
check("Alpaca failed during session -> Hyperliquid", m.underlyingPrice(for: dram)?.source == .hyperliquid)
check("Alpaca failed, no HL symbol -> nil", m.underlyingPrice(for: noHL) == nil)
m.optionQuotes = [:]
check("no IV and no last IV -> no synthetic", m.syntheticValue(for: dram, ratePercent: 4.3) == nil)
dram.lastIV = 0.627
let synthetic = m.syntheticValue(for: dram, ratePercent: 4.3)!
check("last known IV -> synthetic \(String(format: "%.4f", synthetic))", abs(synthetic - dram.fairValue(spot: 42.99, at: .now, vol: 0.627, ratePercent: 4.3)) < 0.01)

print("— Ephemeral mode (real network, no saved settings, empty store)")
// Volatile settings that a normal launch would read. Nothing here is written to disk.
UserDefaults.standard.register(defaults: ["alpacaKeyID": "saved-key", "alpacaSecretKey": "saved-secret", "riskFreeRate": 9.9])
let normalStore = MarketStore()
check("a normal launch reads the saved settings (sanity check)", normalStore.alpacaKeyID == "saved-key" && normalStore.ratePercent == 9.9)
UserDefaults.standard.register(defaults: ["ephemeral": true, "demoAppearance": "dark"])
let ephemeral = MarketStore()
check("ephemeral: saved keys and rate are not read", ephemeral.alpacaKeyID == "" && ephemeral.alpacaSecretKey == "" && ephemeral.ratePercent == 4.3 && !ephemeral.hasAlpacaKeys)
check("ephemeral: no demo market data", ephemeral.lastUpdated == nil && ephemeral.data.hyperliquidPrices.isEmpty)
ephemeral.alpacaKeyID = "typed-key"
ephemeral.alpacaSecretKey = "typed-secret"
ephemeral.ratePercent = 5
let defaults = UserDefaults.standard
check("ephemeral: changed settings are not written", defaults.string(forKey: "alpacaKeyID") == "saved-key" && defaults.string(forKey: "alpacaSecretKey") == "saved-secret" && defaults.double(forKey: "riskFreeRate") == 9.9)
let ephemeralContainer = DemoData.makeContainer()  // keep it: a context doesn't keep its container alive
check("ephemeral: the positions store starts empty", try ephemeralContainer.mainContext.fetchCount(FetchDescriptor<Position>()) == 0)
check("ephemeral: -demoAppearance applies", DemoData.appearance == .dark)
let ephemeralFound = await ephemeral.findHyperliquidSymbol(for: "pltr")
check("ephemeral: symbol search uses the (stubbed) network", ephemeralFound?.symbol == "km:PLTR" && ephemeralFound?.price == 180.5)

print("— MarketStore in demo mode (no network, no settings)")
UserDefaults.standard.register(defaults: ["demo": true, "ephemeral": false])  // volatile; nothing is written
let store = MarketStore()
check("demo keys and session", store.hasAlpacaKeys && store.alpacaKeyID == "DEMO-KEY-ID" && store.session == .closed && store.lastUpdated != nil)
let demoDRAM = Position(underlying: "DRAM", optionType: .call, strike: 49, expiration: expiry, contracts: 400, averagePrice: 2.31, hyperliquidSymbol: "xyz:DRAM")
check("demo DRAM priced from Hyperliquid while closed", store.underlyingPrice(for: demoDRAM) == MarketData.Price(value: 42.83, source: .hyperliquid))
check("demo DRAM IV from quote", store.impliedVolatility(for: demoDRAM) == 0.627 && store.quote(for: demoDRAM)?.impliedVolatility == 0.627)
let mv = store.marketValue(for: demoDRAM) ?? 0
// Each call values at its own `.now`, so allow $1 of time decay between calls.
check("marketValue = synthetic × 400 × 100, profit = mv − cost (\(money(mv)))", abs(mv - (store.syntheticValue(for: demoDRAM) ?? 0) * 40_000) < 1 && abs((store.profit(for: demoDRAM) ?? 0) - (mv - 92_400)) < 1)
let demoChain = try await store.chain(underlying: "dram", type: .call)
check("demo chain: 4 expirations × 25 strikes, sorted, includes $49 Feb 19", demoChain.count == 100 && Set(demoChain.map(\.expiration)).count == 4 && demoChain.contains { $0.symbol == "DRAM270219C00049000" })
check("demo chain unknown ticker -> empty", try await store.chain(underlying: "ZZZZ", type: .put).isEmpty)
let knownHL = await store.hyperliquidPrice("xyz:DRAM"), unknownHL = await store.hyperliquidPrice("xyz:NOPE")
check("demo hyperliquidPrice", knownHL == 42.83 && unknownHL == nil)
let dramSpot = await store.stockPrice(" dram "), nvdaSpot = await store.stockPrice("NVDA"), unknownSpot = await store.stockPrice("ZZZZ")
check("demo stockPrice: trimmed and uppercased, nil for an unknown ticker", dramSpot == 43.66 && nvdaSpot == 163.15 && unknownSpot == nil)
store.alpacaKeyID = ""  // demo mode never saves settings
let noKeysSpot = await store.stockPrice("DRAM")
store.alpacaKeyID = "DEMO-KEY-ID"
check("demo stockPrice without keys -> nil", noKeysSpot == nil && store.hasAlpacaKeys)
check("demo testAlpacaConnection -> nil", await store.testAlpacaConnection() == nil)
let demoTSLA = await store.findHyperliquidSymbol(for: " tsla "), demoSPY = await store.findHyperliquidSymbol(for: "SPY")
check("demo findHyperliquidSymbol: xyz:TSLA 413.05, nothing for SPY", demoTSLA?.symbol == "xyz:TSLA" && demoTSLA?.price == 413.05 && demoSPY == nil)
func inRange(_ range: ClosedRange<Double>, _ lower: Double, _ upper: Double) -> Bool {
    abs(range.lowerBound - lower) < 1e-6 && abs(range.upperBound - upper) < 1e-6
}
let margin = 1.25 * 0.627 * sqrt(Swift.max(demoDRAM.daysToExpiration, 1) / 365)
let range = Theme.priceRange(for: demoDRAM, spot: 42.83, iv: 0.627)
check("priceRange 1.25 × IV × √years (\(price(range.lowerBound)) … \(price(range.upperBound)))",
      inRange(range, (1 - margin) * 42.83, (1 + margin) * 49) && range.lowerBound > 24 && range.upperBound < 71)
check("priceRange margin at least 8%", inRange(Theme.priceRange(for: demoDRAM, spot: 42.83, iv: 0.05), 0.92 * 42.83, 1.08 * 49))
check("priceRange margin at most 50%", inRange(Theme.priceRange(for: demoDRAM, spot: 42.83, iv: 3), 0.5 * 42.83, 1.5 * 49))
check("priceRange without IV: 30%, nil spot -> strike", inRange(Theme.priceRange(for: demoDRAM, spot: nil, iv: nil), 0.7 * 49, 1.3 * 49))

print("— Demo data")
let demoContainer = DemoData.makeContainer()
let samples = try demoContainer.mainContext.fetch(FetchDescriptor<Position>(sortBy: [SortDescriptor(\.createdAt)]))
check("three sample positions: \(samples.map(\.title))", samples.map(\.title) == ["DRAM $49 Call", "NVDA $180 Call", "TSLA $400 Put"])
check("each has a Hyperliquid symbol", samples.map(\.hyperliquidSymbol) == ["xyz:DRAM", "xyz:NVDA", "xyz:TSLA"])
check("each has a saved IV", samples.map(\.lastIV) == [0.627, 0.48, 0.52])
let tsla = samples[2]
check("TSLA put: 10 × $14.50, expires Dec 18 '26", tsla.contracts == 10 && tsla.averagePrice == 14.5 && tsla.expirationText == "Dec 18 '26" && tsla.optionType == .put)
let tslaScenario = tsla.sortedScenarios.first
check("TSLA: one unnamed scenario, $380, IV 55, 14 days out", tsla.scenarios.count == 1 && tslaScenario?.name == "" && tslaScenario?.underlyingPrice == 380 && tslaScenario?.ivPercent == 55 && abs((tslaScenario?.date.timeIntervalSinceNow ?? 0) / 86_400 - 14) < 1)
check("scenario counts DRAM 2, NVDA 0", samples[0].scenarios.count == 2 && samples[1].scenarios.isEmpty)
await store.refresh(samples)
check("with keys: Hyperliquid prices while closed", samples.map { store.underlyingPrice(for: $0) } == [MarketData.Price(value: 42.83, source: .hyperliquid), MarketData.Price(value: 162.90, source: .hyperliquid), MarketData.Price(value: 413.05, source: .hyperliquid)])
check("with keys: live quotes and IVs", samples.allSatisfy { store.quote(for: $0)?.impliedVolatility != nil } && store.impliedVolatility(for: tsla) == 0.52)
check("with keys: every position valued, TSLA put shows a gain", samples.allSatisfy { store.marketValue(for: $0) != nil } && (store.profit(for: tsla) ?? 0) > 0)
store.alpacaKeyID = ""
await store.refresh(samples)
check("without keys: no option quotes", samples.allSatisfy { store.quote(for: $0) == nil })
check("without keys: every position valued from Hyperliquid and its saved IV",
      samples.allSatisfy { store.underlyingPrice(for: $0)?.source == .hyperliquid && store.impliedVolatility(for: $0) == $0.lastIV && store.marketValue(for: $0) != nil })
do { _ = try await store.chain(underlying: "DRAM", type: .call); check("without keys: chain throws", false) }
catch { check("without keys: chain throws the no-keys error", error.localizedDescription.contains("Settings")) }
store.alpacaKeyID = "DEMO-KEY-ID"
await store.refresh(samples)
for ticker in ["DRAM", "NVDA", "TSLA"] {
    let quotes = try await store.chain(underlying: ticker, type: ticker == "TSLA" ? .put : .call)
    check("demo chain for \(ticker): \(quotes.count) contracts", quotes.count == 100)
}
let tslaChain = try await store.chain(underlying: "TSLA", type: .put)
check("TSLA chain contains the $400 Dec 18 put", tslaChain.contains { $0.symbol == tsla.symbol })
check("no demo chain for SPY", try await store.chain(underlying: "SPY", type: .put).isEmpty)

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
