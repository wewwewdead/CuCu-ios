import SwiftUI

/// Labeled slider with a right-aligned numeric readout. Used by both the theme
/// editor and the block editor so all sliders look and behave identically.
struct StyleSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.cucuSerif(15, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Spacer()
                CucuValuePill(text: format(value))
            }
            Slider(value: $value, in: range, step: step)
                .tint(Color.cucuMoss)
        }
    }
}
