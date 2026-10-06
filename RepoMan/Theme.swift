import SwiftUI

struct RepositoryCheckProgressRing: View {
    let progress: RepositoryCheckProgress

    var body: some View {
        Circle().stroke(Theme.secondary.opacity(0.25), lineWidth: 2)
            .overlay {
                Circle().trim(from: 0, to: progress.fraction)
                    .stroke(Theme.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .accessibilityLabel("Repository checks")
            .accessibilityValue("\(progress.completed) of \(progress.total) completed, \(progress.remaining) remaining")
    }
}

enum Theme {
    static let background = color(0x181818)
    static let sidebar = color(0x1D1D1D)
    static let topBar = color(0x242424)
    static let panel = color(0x202020)
    static let control = color(0x282828)
    static let field = color(0x282828)
    static let composer = color(0x363636)
    static let selection = color(0x333333)
    static let scrollbarWidth: CGFloat = 6
    static let scrollbar = color(0x383838)
    static let scrollbarHover = color(0x505050)
    static let border = color(0x353535)
    static let primary = color(0xECECEC)
    static let secondary = color(0xA3A3A3)
    static let subtle = color(0x858585)
    static let blue = color(0xA3BBD1)
    static let green = color(0x83BD98)
    static let amber = color(0xDEB654)
    static let purple = color(0xB0A3BD)
    static let cyan = color(0x9CBFC3)
    static let red = color(0xE18484)

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }
}

extension URL {
    var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
