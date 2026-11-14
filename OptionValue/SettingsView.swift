import SwiftUI

/// The Settings window: Alpaca keys with a connection test, the risk-free rate and a Hyperliquid note.
struct SettingsView: View {
    @Environment(MarketStore.self) private var store

    /// The result of the last "Test Connection".
    private enum TestState: Equatable {
        case idle, testing, connected
        case failed(String)
    }

    @State private var testState = TestState.idle

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                TextField("API key ID", text: $store.alpacaKeyID)
                SecureField("Secret key", text: $store.alpacaSecretKey)
                testRow
            } header: {
                Text("Alpaca (optional)")
            } footer: {
                footnote("Optional. Adds live option quotes and implied volatility, the option-chain browser, and prices for tickers that Hyperliquid doesn’t list. Paper-trading keys are enough.")
            }

            Section {
                LabeledContent("Risk-free rate") {
                    rateField
                }
            } header: {
                Text("Pricing")
            } footer: {
                footnote("Used by the Black-Scholes model for every value in the app.")
            }

            Section("Hyperliquid") {
                Text("No key needed. Underlying prices come from Hyperliquid whenever US markets are closed or there are no Alpaca keys. The app finds the symbol when you add a position.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The window takes the Form's full height, so nothing is cut off at the bottom.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 480)
        // A new key makes the last test result stale.
        .onChange(of: store.alpacaKeyID) { testState = .idle }
        .onChange(of: store.alpacaSecretKey) { testState = .idle }
    }

    // MARK: Alpaca

    private var testRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button("Test Connection", action: testConnection)
                .disabled(testState == .testing || !store.hasAlpacaKeys)
                .accessibilityIdentifier("testConnection")
            testResult
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Label {
                Text("Connected")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Label {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func testConnection() {
        testState = .testing
        Task {
            let error = await store.testAlpacaConnection()
            testState = error.map { .failed($0) } ?? .connected
        }
    }

    // MARK: Pricing

    /// "4.3 %" with a stepper that moves in steps of 0.1.
    private var rateField: some View {
        @Bindable var store = store

        return HStack(spacing: 4) {
            TextField("Risk-free rate", value: $store.ratePercent,
                      format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Text("%")
                .foregroundStyle(.secondary)
            Stepper("Risk-free rate") {
                stepRate(by: 0.1)
            } onDecrement: {
                stepRate(by: -0.1)
            }
            .labelsHidden()
        }
    }

    /// Steps the rate and rounds to one decimal so repeated steps don't drift (4.3 → 4.4, not 4.3999…).
    private func stepRate(by step: Double) {
        store.ratePercent = Swift.max(0, ((store.ratePercent + step) * 10).rounded() / 10)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
