import AppKit
import SwiftUI

/// Burnish's colour: the brass of a front-desk bell, matching the website's palette in light and
/// dark. `brass` tints controls and seals, `brassHigh` is the highlight end of a gradient, and
/// `brassInk` is for text on a pale brass background.
public extension Color {
    static let brass = Color(light: 0xC47A24, dark: 0xEAA64A)
    static let brassHigh = Color(light: 0xF2B452, dark: 0xFFD08A)
    static let brassInk = Color(light: 0xA8621A, dark: 0xF2B452)

    /// The brass gradient the website's hero uses, for progress bars.
    static let brassGradient = LinearGradient(colors: [.brass, .brassHigh], startPoint: .leading, endPoint: .trailing)

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
