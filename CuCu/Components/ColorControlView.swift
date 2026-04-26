import SwiftUI

/// A row using SwiftUI's native ColorPicker, backed by a hex string. The hex
/// is the source of truth (it lives in JSON) and is shown as small monospaced
/// secondary text so designers can copy/eyeball values without a separate
/// "advanced" toggle.
struct ColorControlRow: View {
    let label: String
    @Binding var hex: String
    var supportsAlpha: Bool = true

    var body: some View {
        ColorPicker(selection: $hex.asColor(), supportsOpacity: supportsAlpha) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.cucuSerif(15, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Text(hex.uppercased())
                    .font(.cucuMono(11, weight: .medium))
                    .foregroundStyle(Color.cucuInkFaded)
            }
        }
    }
}
