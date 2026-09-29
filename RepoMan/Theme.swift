import SwiftUI

enum Theme {
    static let background = color(0x151B22)
    static let sidebar = color(0x1C232B)
    static let panel = color(0x1D252E)
    static let control = color(0x29313B)
    static let field = color(0x272E37)
    static let selection = color(0x2C4560)
    static let border = color(0x36404B)
    static let primary = color(0xF2F4F7)
    static let secondary = color(0xAAB7C8)
    static let subtle = color(0x8492A3)
    static let blue = color(0x75A8D5)
    static let green = color(0x78B894)
    static let amber = color(0xD8A94F)
    static let purple = color(0xB995D0)
    static let cyan = color(0x72B9BF)
    static let red = color(0xD97983)

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
