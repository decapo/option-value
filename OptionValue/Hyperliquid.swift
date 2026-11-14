import Foundation

/// Mid prices from Hyperliquid's public info API (no key needed). Perps listed by builder-deployed
/// exchanges ("dexes") are named "dex:COIN", e.g. xyz:DRAM; core perps have no prefix, e.g. BTC.
enum Hyperliquid {
    static func midPrices(for symbols: [String]) async throws -> [String: Double] {
        let dexes = Set(symbols.map { $0.contains(":") ? String($0.prefix { $0 != ":" }) : "" })
        var prices: [String: Double] = [:]
        for dex in dexes {
            for (symbol, mid) in try await allMids(dex: dex) {
                prices[symbol] = Double(mid)
            }
        }
        return prices
    }

    /// The symbol and mid price of a stock ticker, e.g. DRAM -> ("xyz:DRAM", 42.83). Looks on the xyz
    /// exchange first and then on every other exchange, in the order Hyperliquid lists them.
    /// Nil if no exchange lists the ticker, or on any failure.
    static func findSymbol(for ticker: String) async -> (symbol: String, price: Double)? {
        let ticker = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ticker.isEmpty else { return nil }
        return try? await search(ticker)
    }

    // MARK: Private

    private struct PerpDex: Decodable {
        let name: String
    }

    private static func search(_ ticker: String) async throws -> (symbol: String, price: Double)? {
        if let found = try await find(ticker, on: "xyz") {
            return found
        }
        for dex in try await dexNames() where dex != "xyz" {
            if let found = try await find(ticker, on: dex) {
                return found
            }
        }
        return nil
    }

    private static func find(_ ticker: String, on dex: String) async throws -> (symbol: String, price: Double)? {
        let symbol = "\(dex):\(ticker)"
        guard let mid = try await allMids(dex: dex)[symbol].flatMap(Double.init) else { return nil }
        return (symbol, mid)
    }

    /// Names of the builder-deployed exchanges. The main exchange is listed as null and is skipped.
    private static func dexNames() async throws -> [String] {
        let data = try await info(["type": "perpDexs"])
        return try JSONDecoder().decode([PerpDex?].self, from: data).compactMap { $0?.name }
    }

    /// Mid prices of every perp on one exchange ("" is the main one).
    private static func allMids(dex: String) async throws -> [String: String] {
        let data = try await info(["type": "allMids", "dex": dex])
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private static func info(_ body: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.hyperliquid.xyz/info")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
