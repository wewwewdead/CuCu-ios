import SwiftUI

/// Renders a single text block from its data.
///
/// This is the canonical visual mapping from JSON → SwiftUI for text blocks.
/// A future web renderer should produce visually equivalent output from the
/// same TextBlockData fields.
///
/// `widthStyle` determines whether the text frame fills its available width
/// before padding/background are applied. The block's *outer* horizontal
/// position (compact/centered) is the renderer's job — see `ProfileBlockView`.
struct TextBlockView: View {
    let data: TextBlockData

    var body: some View {
        sizedText
            .padding(data.padding)
            .background(
                RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous)
                    .fill(Color(hex: data.backgroundColorHex))
            )
    }

    @ViewBuilder
    private var sizedText: some View {
        let text = Text(data.content.isEmpty ? "Empty text block" : data.content)
            .font(.system(size: data.fontSize, design: data.fontName.design))
            .foregroundStyle(Color(hex: data.textColorHex))
            .multilineTextAlignment(data.alignment.textAlignment)

        if data.widthStyle == .fill {
            text.frame(maxWidth: .infinity, alignment: data.alignment.frameAlignment)
        } else {
            text
        }
    }
}
