import SwiftUI

@main
struct SooFrontierApp: App {
    @State private var store: FrontierStore
    @State private var reader = Reader()

    init() {
        let store = FrontierStore()
        _store = State(initialValue: store)
        #if os(iOS)
        DailyRefresh.register { store }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Themed {
                RootView()
                    .environment(store)
                    .environment(reader)
            }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Dispatch Agents") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            Themed { NavigationStack { SettingsView() } }
                .environment(store)
                .environment(reader)
                .frame(width: 520, height: 640)
        }
        #endif
    }
}
