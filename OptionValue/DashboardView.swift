import SwiftData
import SwiftUI

/// The main window: a scrolling page of cards (banner, summary tiles, positions, chart) with the selected
/// position's details and scenarios in the trailing inspector.
struct DashboardView: View {
    @Environment(MarketStore.self) private var store
    @Environment(\.modelContext) private var context
    @Query(sort: \Position.createdAt) private var positions: [Position]

    @State private var selection: Position.ID?
    @State private var selectedScenario: Scenario.ID?
    @State private var showingInspector = true
    @State private var editorRequest: EditorRequest?
    @State private var positionToDelete: Position?

    /// The editor sheet's subject. Presenting with `sheet(item:)` hands the sheet the position directly;
    /// with `isPresented` the first sheet after launch could open as "New Position" when editing.
    private struct EditorRequest: Identifiable {
        let id = UUID()
        let position: Position?  // nil = new position
    }

    var body: some View {
        mainColumn
            .toolbar { toolbarItems }
            .inspector(isPresented: inspectorShown) {
                PositionInspector(position: selectedPosition, selectedScenario: $selectedScenario,
                                  onEdit: edit, onDelete: askToDelete)
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
            }
            .sheet(item: $editorRequest) { request in
                PositionEditor(position: request.position) { saved in
                    select(saved.id)
                }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteDialogShown, titleVisibility: .visible,
                                presenting: positionToDelete) { position in
                Button("Delete", role: .destructive) { delete(position) }
                Button("Cancel", role: .cancel) {}
            } message: { position in
                Text(deleteMessage(position))
            }
            .onAppear { selectFirstIfNeeded() }
            .onChange(of: positions.map(\.id)) { selectFirstIfNeeded() }
            .onChange(of: selection) {
                selectedScenario = selectedPosition?.sortedScenarios.first?.id
                if selection != nil { showingInspector = true }
            }
            // Refresh 0.5 s after launch or a change of positions or keys, then every minute.
            .task(id: refreshKey) {
                try? await Task.sleep(for: .seconds(0.5))
                while !Task.isCancelled {
                    await store.refresh(positions)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .environment(\.timeZone, eastern)
    }

    // MARK: Main column

    @ViewBuilder private var mainColumn: some View {
        if positions.isEmpty {
            emptyState
        } else {
            page
        }
    }

    /// The page of cards. It is at least as tall as the window so the chart can grow (300–680 pt).
    private var page: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    banner
                    PortfolioHeader(positions: positions)
                    PositionsList(positions: positions, selection: $selection, onEdit: edit, onDelete: askToDelete)
                    PayoffChart(position: selectedPosition, selectedScenario: selectedScenario)
                        .frame(minHeight: 300, maxHeight: 680)
                }
                .padding(20)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
    }

    /// Shown only when a refresh failed. Having no Alpaca keys is normal and needs no banner.
    @ViewBuilder private var banner: some View {
        if let message = store.errorMessage {
            let sentence = message.hasSuffix(".") ? message : message + "."
            Banner(tint: .orange, symbol: "exclamationmark.triangle.fill",
                   text: sentence + (store.alpacaFailed ? " Showing Hyperliquid prices where available." : ""))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No positions yet", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text("Add an option position to see what it’s worth now — and what it would be worth at any price and date.")
        } actions: {
            Button("Add Position", action: addPosition)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: addPosition) {
                Label("Add Position", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("n")
            .help("Add an option position (⌘N)")
            .accessibilityIdentifier("addPosition")

            Button {
                Task { await store.refresh(positions) }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r")
            .disabled(positions.isEmpty)
            .help("Refresh prices (⌘R)")
            .accessibilityIdentifier("refresh")

            Button {
                showingInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .disabled(positions.isEmpty)
            .help("Show or hide the position inspector")
        }
    }

    // MARK: State helpers

    private var selectedPosition: Position? {
        positions.first { $0.id == selection }
    }

    /// The inspector is hidden while there are no positions.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { showingInspector && !positions.isEmpty },
                set: { showingInspector = $0 })
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { positionToDelete != nil },
                set: { if !$0 { positionToDelete = nil } })
    }

    /// Changes whenever the refresh loop should restart: positions' contracts or keys.
    private var refreshKey: [String] {
        positions.map { $0.symbol + " " + $0.hyperliquidSymbol } + [store.alpacaKeyID, store.alpacaSecretKey]
    }

    private var deleteTitle: String {
        positionToDelete.map { "Delete \($0.title)?" } ?? ""
    }

    private func deleteMessage(_ position: Position) -> String {
        switch position.scenarios.count {
        case 0: ""
        case 1: "Its saved scenario will be deleted too."
        default: "Its \(position.scenarios.count) saved scenarios will be deleted too."
        }
    }

    // MARK: Actions

    /// Selects the first position on launch and after the selected one is deleted.
    private func selectFirstIfNeeded() {
        if selectedPosition == nil {
            select(positions.first?.id)
        }
    }

    /// Selecting a position resets the selected scenario to its first one.
    private func select(_ id: Position.ID?) {
        selection = id
        selectedScenario = selectedPosition?.sortedScenarios.first?.id
    }

    private func addPosition() {
        editorRequest = EditorRequest(position: nil)
    }

    private func edit(_ position: Position) {
        editorRequest = EditorRequest(position: position)
    }

    private func askToDelete(_ position: Position) {
        positionToDelete = position
    }

    private func delete(_ position: Position) {
        if selection == position.id {
            selection = nil
        }
        context.delete(position)
        try? context.save()
        positionToDelete = nil
    }
}

/// A slim notice at the top of the page with a button that opens Settings.
private struct Banner: View {
    let tint: Color
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsLink {
                Text("Open Settings")
            }
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
