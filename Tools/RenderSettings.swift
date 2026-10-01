import AppKit
import SwiftUI

/// Render the actual settings view with demo data, without changing saved preferences.
@main
struct RenderSettings {
    @MainActor
    static func main() async throws {
        let store = RepositoryStore()
        guard store.isDemo else {
            fputs("Settings rendering requires --demo.\n", stderr)
            exit(1)
        }
        store.start()
        store.setCheck("git.staleBranches", enabled: false)
        store.setCheck("git.worktrees", enabled: false)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let size = CGSize(width: 1_672, height: 917)
        let hosting = NSHostingView(rootView: SettingsView()
            .environmentObject(store)
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fputs("Could not render RepoMan settings.\n", stderr)
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Could not encode RepoMan settings.\n", stderr)
            exit(1)
        }
        let path = CommandLine.arguments.first { $0.hasSuffix(".png") }
            ?? "DerivedData/settings-render.png"
        try png.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}
