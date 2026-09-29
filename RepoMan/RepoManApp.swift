import SwiftUI

@main
struct RepoManApp: App {
    @StateObject private var store = RepositoryStore()

    var body: some Scene {
        WindowGroup("RepoMan") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1_180, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_586, height: 990)
        .windowToolbarStyle(.unifiedCompact)
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
