import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// Initialize from "#RRGGBB", "#RRGGBBAA", "#RGB", or the same without leading "#".
    /// Falls back to black for malformed input rather than crashing.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .black
            return
        }
        let r, g, b, a: Double
        switch cleaned.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1.0
        case 3:
            r = Double((value >> 8) & 0xF) * 17.0 / 255
            g = Double((value >> 4) & 0xF) * 17.0 / 255
            b = Double(value & 0xF) * 17.0 / 255
            a = 1.0
        default:
            self = .black
            return
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Render this Color back to a hex string in the same shape `init(hex:)` reads.
    /// Returns `#RRGGBB` when fully opaque, `#RRGGBBAA` otherwise. The SwiftUI
    /// Color is bridged to the platform's native color type so we can read its
    /// sRGB components — operations roundtrip via the JSON schema as hex.
    func toHex() -> String {
        var R = 0, G = 0, B = 0, A = 255
        #if canImport(UIKit)
        let native = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if native.getRed(&r, green: &g, blue: &b, alpha: &a) {
            R = Int(round(max(0, min(1, r)) * 255))
            G = Int(round(max(0, min(1, g)) * 255))
            B = Int(round(max(0, min(1, b)) * 255))
            A = Int(round(max(0, min(1, a)) * 255))
        }
        #elseif canImport(AppKit)
        if let native = NSColor(self).usingColorSpace(.sRGB) {
            R = Int(round(native.redComponent * 255))
            G = Int(round(native.greenComponent * 255))
            B = Int(round(native.blueComponent * 255))
            A = Int(round(native.alphaComponent * 255))
        }
        #endif
        if A >= 255 {
            return String(format: "#%02X%02X%02X", R, G, B)
        }
        return String(format: "#%02X%02X%02X%02X", R, G, B, A)
    }
}

extension Binding where Value == String {
    /// Bridge a hex-string binding to a SwiftUI Color binding so `ColorPicker`
    /// can drive a value that's persisted as hex inside `designJSON`. The hex
    /// remains the source of truth — the Color form is computed on read and
    /// the string is rewritten on every set.
    func asColor() -> Binding<Color> {
        Binding<Color>(
            get: { Color(hex: self.wrappedValue) },
            set: { self.wrappedValue = $0.toHex() }
        )
    }
}
