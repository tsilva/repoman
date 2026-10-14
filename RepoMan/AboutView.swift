import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    private let repositoryURL = URL(string: "https://github.com/tsilva/repoman")!
    private let issuesURL = URL(string: "https://github.com/tsilva/repoman/issues")!
    private let authorURL = URL(string: "https://github.com/tsilva")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                Text("RepoMan")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)

                Text("Version \(version) (\(build))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 4)
                    .accessibilityLabel("Version \(version), build \(build)")

                Text("Keep your Git repositories in sight.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 10)

                HStack(spacing: 12) {
                    Link("GitHub", destination: repositoryURL)
                    Circle().fill(Theme.subtle).frame(width: 2, height: 2).accessibilityHidden(true)
                    Link("Report an Issue", destination: issuesURL)
                    Circle().fill(Theme.subtle).frame(width: 2, height: 2).accessibilityHidden(true)
                    Link("By tsilva", destination: authorURL)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 16)

                Rectangle().fill(Theme.border).frame(height: 1)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                AppUpdateStatusView(compact: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 360)
        .foregroundStyle(Theme.primary)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onExitCommand { dismissWindow(id: "about") }
    }

}

#Preview {
    AboutView()
        .environmentObject(RepositoryStore())
}
