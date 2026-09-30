import AppKit
import SwiftUI

@main
struct RepoManApp: App {
    @NSApplicationDelegateAdaptor(RepoManAppDelegate.self) private var appDelegate
    @StateObject private var store = RepositoryStore()

    var body: some Scene {
        WindowGroup("RepoMan") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1_180, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_586, height: 990)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Repositories") {
                Button("Choose Folder…") { store.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Refresh All") { store.refreshAll() }
                    .keyboardShortcut("r")
                    .disabled(store.folder == nil || store.isScanning || store.isFetching)
            }
        }
    }
}

private final class RepoManAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the bundled artwork even when the Dock has cached a placeholder.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
