import AppKit
import SwiftUI

@main
struct RenderDemo {
    @MainActor
    static func main() async {
        let store = RepositoryStore()
        guard store.isDemo else {
            fputs("Demo rendering requires --demo.\n", stderr)
            exit(1)
        }
        store.start()
        let width: CGFloat = 1_586
        let height: CGFloat = 916
        let view = ContentView()
        .environmentObject(store)
        .frame(width: width, height: height)
        .preferredColorScheme(.dark)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 120_000_000)
        hosting.layoutSubtreeIfNeeded()
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
