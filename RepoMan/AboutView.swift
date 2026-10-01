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
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .accessibilityHidden(true)

                Text("RepoMan")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.8)
                    .padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)

                Text("Keep your Git repositories in sight.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 8)

                HStack(spacing: 10) {
                    Text("Version \(version)")
                        .foregroundStyle(Theme.primary)
                    Circle().fill(Theme.subtle).frame(width: 3, height: 3)
                    Text("Build \(build)")
                        .foregroundStyle(Theme.secondary)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.control, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                .padding(.top, 18)
                .accessibilityElement(children: .combine)

                Text("A clear view of local changes, repository health,\nand the issues that need your attention.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)

                HStack(spacing: 10) {
                    resourceLink("View on GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: repositoryURL)
                    resourceLink("Report an Issue", symbol: "bubble.left", url: issuesURL)
                }
                .padding(.top, 26)
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background {
                RadialGradient(colors: [Theme.blue.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.5, y: 0.15),
                               startRadius: 0, endRadius: 240)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                Link(destination: authorURL) {
                    Text("Made by \(Text("tsilva").foregroundStyle(Theme.secondary))")
                        .foregroundStyle(Theme.subtle)
                }
                .help("Visit tsilva on GitHub")
                Spacer()
                Label("Built for macOS", systemImage: "macwindow")
                    .foregroundStyle(Theme.subtle)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(Theme.panel)
        }
        .frame(width: 480)
        .foregroundStyle(Theme.primary)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onExitCommand { dismissWindow(id: "about") }
    }

    private func resourceLink(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.secondary)
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(AboutResourceLinkStyle())
        .help("Open \(url.absoluteString)")
    }
}

private struct AboutResourceLinkStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || isHovered ? Theme.selection : Theme.control,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
            .onHover { isHovered = $0 }
    }
}

#Preview {
    AboutView()
}
