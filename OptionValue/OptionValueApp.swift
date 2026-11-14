import SwiftData
import SwiftUI

/// The app: one main window and the Settings window, sharing one `MarketStore`.
@main
struct OptionValueApp: App {
    let container: ModelContainer
    @State private var store = MarketStore()

    init() {
        if DemoData.isEnabled || DemoData.isEphemeral {
            container = DemoData.makeContainer()
            return
        }
        // Use our own folder: unsandboxed apps otherwise share ~/Library/Application Support/default.store.
        let folder = URL.applicationSupportDirectory.appending(path: "OptionValue")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: folder.appending(path: "Positions.store"))
        do {
            container = try ModelContainer(for: Position.self, configurations: config)
        } catch {
            fatalError("Could not open the positions store: \(error)")
        }
    }

    var body: some Scene {
        Window("Option Value", id: "main") {
            DashboardView()
                // A 980 × 620 window: the content sits below the 52 pt title bar and toolbar.
                .frame(minWidth: 980, minHeight: 568)
                .environment(store)
                .preferredColorScheme(DemoData.appearance)
        }
        .modelContainer(container)
        .defaultSize(width: 1280, height: 800)
        .commands {
            InspectorCommands()
        }

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(DemoData.appearance)
        }
    }
}
