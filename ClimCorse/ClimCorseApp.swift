import SwiftUI

@main
struct ClimCorseApp: App {
    @StateObject private var viewModel = ClimateViewModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher les mises à jour…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .toolbar) {
                Button("Actualiser") {
                    Task { await viewModel.refresh() }
                }
                .keyboardShortcut("r")
            }
        }

        MenuBarExtra("ClimCorse", systemImage: "wind") {
            MenuBarView()
                .environmentObject(viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }
}
