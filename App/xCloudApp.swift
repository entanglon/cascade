import SwiftUI

@main
struct xCloudApp: App {
    @NSApplicationDelegateAdaptor(TerminationHandler.self) private var terminationHandler
    @Environment(\.openWindow) private var openWindow
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 1024, minHeight: 640)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About xCloud") {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "about")
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Settings...") {
                    appState.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button("Select All") { appState.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") { appState.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Move to Trash") { appState.bulkTrash() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(appState.selectedFiles.isEmpty)
            }
        }

        Window("About", id: "about") {
            AboutView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}
