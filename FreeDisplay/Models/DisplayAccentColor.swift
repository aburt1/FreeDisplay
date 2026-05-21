import SwiftUI
import CoreGraphics

/// Assigns each display a stable accent color drawn from a small palette
/// inspired by the macOS Accent picker. The color is keyed on the display's
/// UUID so it stays consistent across launches and reconnects, but maps
/// purely deterministically — no UserDefaults read needed.
///
/// Used by the menu row indicator dot, the brightness slider tint, and the
/// identify-display flash overlay so a user can visually link "this slider"
/// to "that physical screen" without reading the display name.
enum DisplayAccent {
    /// Ordered palette — front-of-list colors land on the first display seen
    /// at app launch (typically the main external). Mac-system-palette adjacent.
    private static let palette: [Color] = [
        Color(red: 0.31, green: 0.55, blue: 0.97), // blue
        Color(red: 0.96, green: 0.41, blue: 0.43), // red
        Color(red: 0.40, green: 0.78, blue: 0.50), // green
        Color(red: 0.95, green: 0.62, blue: 0.31), // orange
        Color(red: 0.62, green: 0.47, blue: 0.91), // purple
        Color(red: 0.95, green: 0.78, blue: 0.31), // yellow
        Color(red: 0.45, green: 0.78, blue: 0.85), // teal
        Color(red: 0.88, green: 0.45, blue: 0.78), // pink
    ]

    /// Deterministic color for a display UUID. Stable across runs.
    static func color(for displayUUID: String) -> Color {
        // FNV-1a-ish hash → palette index. UUID is short and stable, so a
        // cheap hash is fine; we don't need cryptographic distribution.
        var hash: UInt64 = 1469598103934665603
        for byte in displayUUID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let idx = Int(hash % UInt64(palette.count))
        return palette[idx]
    }

    /// `NSColor` form for the identify-display NSWindow overlay.
    static func nsColor(for displayUUID: String) -> NSColor {
        let c = color(for: displayUUID)
        // SwiftUI Color → NSColor via UIColor-like resolution. We constructed
        // these from RGB so we can re-derive the components directly.
        return NSColor(c)
    }
}
