import SwiftUI

/// HSV color picker for the redesigned text inspector. Matches the
/// `inspector-text.jsx` layout: a saturation/value square, a vertical
/// hue strip, a vertical alpha strip, a back chevron + tiny preview
/// dot, and a hex input + opacity numeric field along the bottom.
///
/// Bindings:
/// - `hex`: 6-character hex (`#RRGGBB`); the picker rewrites it on
///   any drag.
/// - `alpha`: 0...1 opacity; rewritten by the alpha strip and the
///   numeric field.
/// - `onBack`: tapped from the chevron above the square.
struct HSVColorPicker: View {
    @Binding var hex: String
    @Binding var alpha: Double
    var onBack: () -> Void

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var value: Double = 1
    @State private var hexDraft: String = ""
    /// Set while a drag is in flight so the view ignores any external
    /// `hex`-driven sync that would otherwise re-pull the indicator
    /// back to the previously committed hue/saturation/value triple.
    @State private var isDragging: Bool = false

    /// Fixed strip height. Hue and alpha strips read this directly in
    /// both the indicator placement and the drag gesture math — using a
    /// constant (rather than `GeometryReader`) keeps the gesture target
    /// stable across the parent re-renders that fire each time the
    /// alpha binding writes back to the document.
    private let stripHeight: CGFloat = 160
    private let stripWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Circle()
                    .fill(currentColor)
                    .overlay(Circle().stroke(Color.cucuInk.opacity(0.18), lineWidth: 1))
                    .frame(width: 22, height: 22)
            }

            HStack(spacing: 10) {
                saturationSquare
                hueStrip
                alphaStrip
            }
            .frame(height: stripHeight)

            HStack(spacing: 10) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: 28, height: 32)

                hexField
                opacityField
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.cucuCard)
        .onAppear { syncStateFromHex() }
        .onChange(of: hex) { _, _ in
            if !isDragging { syncStateFromHex() }
        }
    }

    // MARK: Saturation/Value square

    private var saturationSquare: some View {
        GeometryReader { geo in
            let pureHue = HSVColorPicker.color(h: hue, s: 1, v: 1, a: 1)
            ZStack {
                pureHue
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .background(
                        Circle().stroke(Color.black.opacity(0.4), lineWidth: 1).padding(-1)
                    )
                    .frame(width: 14, height: 14)
                    .position(x: saturation * geo.size.width,
                              y: (1 - value) * geo.size.height)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.cucuInk.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isDragging = true
                        let w = max(1, geo.size.width)
                        let h = max(1, geo.size.height)
                        saturation = clamp(Double(v.location.x / w), 0, 1)
                        value = clamp(Double(1 - (v.location.y / h)), 0, 1)
                        commitFromHSV()
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
    }

    // MARK: Hue strip

    private var hueStrip: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                stops: hueStops,
                startPoint: .top,
                endPoint: .bottom
            )
            hueIndicator(width: stripWidth)
                .position(x: stripWidth / 2,
                          y: (hue / 360) * stripHeight)
                .allowsHitTesting(false)
        }
        .frame(width: stripWidth, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.cucuInk.opacity(0.12), lineWidth: 1)
        )
        // Padding outward expands the strip's hit area so a thin 18pt
        // column is forgiving under a real fingertip; the visual stays
        // 18pt wide because the gradient is clipped above this line.
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .padding(.horizontal, -6)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    isDragging = true
                    hue = clamp(Double(v.location.y / stripHeight), 0, 1) * 360
                    commitFromHSV()
                }
                .onEnded { _ in isDragging = false }
        )
    }

    private static let hueColors: [Color] = [
        .red, .yellow, .green, .cyan, .blue, .purple, .red
    ]
    private var hueStops: [Gradient.Stop] {
        [
            .init(color: Color(red: 1, green: 0, blue: 0), location: 0.00),
            .init(color: Color(red: 1, green: 1, blue: 0), location: 0.17),
            .init(color: Color(red: 0, green: 1, blue: 0), location: 0.33),
            .init(color: Color(red: 0, green: 1, blue: 1), location: 0.50),
            .init(color: Color(red: 0, green: 0, blue: 1), location: 0.67),
            .init(color: Color(red: 1, green: 0, blue: 1), location: 0.83),
            .init(color: Color(red: 1, green: 0, blue: 0), location: 1.00),
        ]
    }

    private func hueIndicator(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color.white, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.black.opacity(0.4), lineWidth: 1)
                    .padding(-1)
            )
            .frame(width: width + 6, height: 8)
    }

    // MARK: Alpha strip

    private var alphaStrip: some View {
        ZStack(alignment: .top) {
            // White backing so the gray checkerboard squares read
            // against a real second tile (without this, the gray
            // pattern just sits on `.clear` and the strip looks
            // tinted rather than alpha-aware).
            Color.white
            CheckerboardPattern()
                .fill(Color.gray.opacity(0.45))
            LinearGradient(
                colors: [opaqueBaseColor, opaqueBaseColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            hueIndicator(width: stripWidth)
                .position(x: stripWidth / 2,
                          y: (1 - alpha) * stripHeight)
                .allowsHitTesting(false)
        }
        .frame(width: stripWidth, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.cucuInk.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .padding(.horizontal, -6)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    isDragging = true
                    alpha = clamp(Double(1 - (v.location.y / stripHeight)), 0, 1)
                }
                .onEnded { _ in isDragging = false }
        )
    }

    // MARK: Hex / opacity fields

    private var hexField: some View {
        HStack(spacing: 6) {
            Text("#")
                .font(.cucuMono(13, weight: .regular))
                .foregroundStyle(Color.cucuInk.opacity(0.55))
            TextField("", text: $hexDraft)
                .font(.cucuMono(13, weight: .regular))
                .foregroundStyle(Color.cucuInk)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { commitHexDraft() }
                .onChange(of: hexDraft) { _, raw in
                    let cleaned = raw
                        .uppercased()
                        .filter { "0123456789ABCDEF".contains($0) }
                    let trimmed = String(cleaned.prefix(6))
                    if trimmed != hexDraft { hexDraft = trimmed; return }
                    if trimmed.count == 6 {
                        hex = "#" + trimmed
                        syncStateFromHex()
                    }
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color.cucuInk.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var opacityField: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(
                get: { Int((alpha * 100).rounded()) },
                set: { alpha = clamp(Double($0) / 100, 0, 1) }
            ), format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .font(.cucuMono(13, weight: .regular))
            .foregroundStyle(Color.cucuInk)

            Text("%")
                .font(.cucuMono(13, weight: .regular))
                .foregroundStyle(Color.cucuInk.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .frame(width: 88, height: 32)
        .background(Color.cucuInk.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Helpers

    private var currentColor: Color {
        HSVColorPicker.color(h: hue, s: saturation, v: value, a: alpha)
    }

    private var opaqueBaseColor: Color {
        HSVColorPicker.color(h: hue, s: saturation, v: value, a: 1)
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }

    private func commitFromHSV() {
        let rgb = HSVColorPicker.hsvToRgb(h: hue, s: saturation, v: value)
        let new = HSVColorPicker.rgbHex(r: rgb.r, g: rgb.g, b: rgb.b)
        hex = new
        hexDraft = new.replacingOccurrences(of: "#", with: "")
    }

    private func commitHexDraft() {
        guard hexDraft.count == 6 else { return }
        hex = "#" + hexDraft
        syncStateFromHex()
    }

    /// Pull h/s/v out of the bound hex. Called on appear and whenever
    /// `hex` changes from outside (a different swatch tapped, paragraph
    /// preset, etc.). Robust to 8-digit `#RRGGBBAA` inputs — alpha is
    /// owned by the separate `alpha` binding, so any trailing byte is
    /// ignored for HSV computation.
    private func syncStateFromHex() {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "#", with: "")
        let rgbPart: String
        if cleaned.count == 8 || cleaned.count == 6 {
            rgbPart = String(cleaned.prefix(6))
        } else {
            hexDraft = "1F1A12"
            return
        }
        guard let value = UInt32(rgbPart, radix: 16) else {
            hexDraft = "1F1A12"
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        let hsv = HSVColorPicker.rgbToHsv(r: r, g: g, b: b)
        // Keep the current hue when saturation drops to zero so the
        // square stays on the user's last-picked column instead of
        // snapping to red.
        if hsv.s > 0.001 { hue = hsv.h }
        saturation = hsv.s
        self.value = hsv.v
        hexDraft = String(rgbPart.uppercased())
    }

    // MARK: Color math (static so it can be reused without instantiating)

    static func hsvToRgb(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s
        let hh = h / 60
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch hh {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }

    static func rgbToHsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 0 {
            switch mx {
            case r: h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
            case g: h = ((b - r) / d) + 2
            default: h = ((r - g) / d) + 4
            }
            h *= 60
            if h < 0 { h += 360 }
        }
        let s = mx == 0 ? 0 : d / mx
        return (h, s, mx)
    }

    static func rgbHex(r: Double, g: Double, b: Double) -> String {
        func clamp255(_ x: Double) -> Int { min(255, max(0, Int((x * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", clamp255(r), clamp255(g), clamp255(b))
    }

    static func color(h: Double, s: Double, v: Double, a: Double) -> Color {
        let rgb = hsvToRgb(h: h, s: s, v: v)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b, opacity: a)
    }
}

// MARK: - Checkerboard backing

/// 10pt-tile checkerboard used behind the alpha strip. Drawn as a `Shape`
/// so the alpha gradient stays a single linear-gradient layer above it
/// — no UIImage backing needed.
private struct CheckerboardPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tile: CGFloat = 5
        var y: CGFloat = 0
        var row = 0
        while y < rect.height {
            var x: CGFloat = (row % 2 == 0) ? 0 : tile
            while x < rect.width {
                path.addRect(CGRect(x: x, y: y, width: tile, height: tile))
                x += tile * 2
            }
            y += tile
            row += 1
        }
        return path
    }
}
