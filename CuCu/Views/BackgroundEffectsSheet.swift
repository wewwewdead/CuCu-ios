import SwiftUI

/// Standalone modal for editing image effects — Gaussian blur and
/// vignette. Generic over the source: takes optional `Double?` bindings
/// to whatever fields hold the values, so the same view powers both the
/// page background's effects (`ProfileDocument.pageBackgroundBlur` /
/// `pageBackgroundVignette`) and a container's background image
/// (`NodeStyle.backgroundBlur` / `backgroundVignette`).
///
/// Edits apply live to the canvas via direct binding mutations;
/// `onCommit` fires once per slider release so SwiftData persists
/// exactly one document mutation per gesture.
struct BackgroundEffectsSheet: View {
    /// Title displayed in the navigation bar. Defaults to "Edit Image".
    var title: String = "Edit Image"
    @Binding var blur: Double?
    @Binding var vignette: Double?
    var onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    effectSlider(
                        title: "Gaussian Blur",
                        binding: blurBinding,
                        range: 0...30,
                        step: 1,
                        valueLabel: "\(Int(blurBinding.wrappedValue))"
                    )
                    effectSlider(
                        title: "Vignette",
                        binding: vignetteBinding,
                        range: 0...1.5,
                        step: 0.05,
                        valueLabel: String(format: "%.2f", vignetteBinding.wrappedValue)
                    )
                    Button(role: .destructive) {
                        blurBinding.wrappedValue = 0
                        vignetteBinding.wrappedValue = 0
                        onCommit()
                    } label: {
                        Label("Reset Effects", systemImage: "arrow.counterclockwise")
                            .font(.cucuSerif(15, weight: .semibold))
                    }
                    .disabled(
                        (blurBinding.wrappedValue <= 0.01) &&
                        (vignetteBinding.wrappedValue <= 0.01)
                    )
                } header: {
                    CucuSectionLabel(text: "Effects")
                } footer: {
                    Text("Edits apply directly to the canvas. Slide back to 0 to remove an effect with no quality loss.")
                        .font(.cucuSans(12, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
            .cucuFormBackdrop()
            .cucuSheetTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.cucuSerif(16, weight: .bold))
                }
            }
        }
    }

    // MARK: - Bindings

    /// Bridges `Binding<Double?>` (storage) to `Binding<Double>` (sliders).
    /// Storing as `Double?` keeps "off" out of the JSON for compactness;
    /// the slider always sees a real number.
    private var blurBinding: Binding<Double> {
        Binding(
            get: { blur ?? 0 },
            set: { blur = $0 > 0.01 ? $0 : nil }
        )
    }

    private var vignetteBinding: Binding<Double> {
        Binding(
            get: { vignette ?? 0 },
            set: { vignette = $0 > 0.01 ? $0 : nil }
        )
    }

    private func effectSlider(title: String,
                              binding: Binding<Double>,
                              range: ClosedRange<Double>,
                              step: Double.Stride,
                              valueLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.cucuSerif(15, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Spacer()
                CucuValuePill(text: valueLabel)
            }
            Slider(value: binding, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
            .tint(Color.cucuMoss)
        }
    }
}
