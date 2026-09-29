import AppKit
import SwiftUI

@main
struct RenderDemo {
    @MainActor
    static func main() {
        let store = RepositoryStore()
        store.start()
        let view = ContentView()
            .environmentObject(store)
            .frame(width: 1_586, height: 916)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_586, height: 916)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fputs("Could not render RepoMan demo.\n", stderr)
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Could not encode RepoMan demo.\n", stderr)
            exit(1)
        }
        let path = CommandLine.arguments.first { $0.hasSuffix(".png") } ?? "DerivedData/demo-render.png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print(path)
        } catch {
            fputs("Could not save demo: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
