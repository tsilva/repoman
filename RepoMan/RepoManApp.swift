import AppKit
import SwiftUI

@main
struct RepoManApp: App {
    @NSApplicationDelegateAdaptor(RepoManAppDelegate.self) private var appDelegate
    @StateObject private var store = RepositoryStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("RepoMan") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1_180, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.persistIssueThreads = { store.persistIssueThreads() }
                }
        }
        .defaultSize(width: 1_586, height: 990)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RepoMan") { openWindow(id: "about") }
            }
            CommandMenu("Repositories") {
                Button("Choose Folder…") { store.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Refresh All") { store.refreshAll() }
                    .keyboardShortcut("r")
                    .disabled(store.folder == nil || store.isScanning || store.isFetching)
            }
        }

        Window("About RepoMan", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(minWidth: 1_040, minHeight: 640)
        }
        .defaultSize(width: 1_340, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class RepoManAppDelegate: NSObject, NSApplicationDelegate {
    var persistIssueThreads: (() -> Bool)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        persistIssueThreads?() == false ? .terminateCancel : .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the bundled artwork even when the Dock has cached a placeholder.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
