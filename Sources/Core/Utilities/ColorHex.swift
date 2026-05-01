import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    /// Converts to a `#RRGGBB` string via NSColor in sRGB. Returns nil for
    /// system dynamic colors that can't be resolved to a static value.
    func toHex() -> String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(srgb.redComponent * 255))
        let g = Int(round(srgb.greenComponent * 255))
        let b = Int(round(srgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum LabelPalette {
    /// Default colors offered when creating a new label.
    static let presets: [String] = [
        "#E53935", "#FB8C00", "#FDD835", "#43A047",
        "#00ACC1", "#1E88E5", "#5E35B1", "#8E24AA",
        "#6D4C41", "#546E7A"
    ]

    static func randomPreset() -> String {
        presets.randomElement() ?? "#1E88E5"
    }
}
