import AppKit
import SwiftUI

@main
struct RenderDemo {
    @MainActor
    static func main() async {
        let store = RepositoryStore()
        store.start()
        let preview = CommandLine.arguments.contains("--preview")
        if preview {
            guard store.isDemo else { fputs("Preview rendering requires --demo.\n", stderr); exit(1) }
            let targets = store.repositories.filter { repository in store.findings(in: repository).contains { $0.checkID == "files.gitignore" } }
            store.prepareAction("files.gitignore", repositories: targets)
            for _ in 0..<250 where store.actionSession?.isPreparing == true {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard store.actionSession?.isPreparing == false else { fputs("Preview preparation timed out.\n", stderr); exit(1) }
        }
        let width: CGFloat = preview ? 860 : 1_586
        let height: CGFloat = preview ? 650 : 916
        let view = Group {
            if preview { RepositoryActionSheet() } else { ContentView() }
        }
        .environmentObject(store)
        .frame(width: width, height: height)
        .preferredColorScheme(.dark)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
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
