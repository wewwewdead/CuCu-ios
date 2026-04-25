import SwiftUI

/// Read-only renderer for a ProfileDesign.
///
/// This is the canonical visual that the preview screen (and a future web
/// viewer) reproduces from the same JSON schema. Theme fields drive page
/// background, vertical block spacing, and horizontal page padding. A local
/// background image, when set, is layered above the color fill and below the
/// content scroll view.
struct ProfileRenderer: View {
    let design: ProfileDesign

    var body: some View {
        ZStack {
            Color(hex: design.theme.backgroundColorHex)
                .ignoresSafeArea()

            if let img = backgroundImage {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
            }

            ScrollView {
                LazyVStack(spacing: design.theme.blockSpacing) {
                    ForEach(design.blocks) { block in
                        ProfileBlockView(block: block)
                    }
                }
                .padding(.horizontal, design.theme.pageHorizontalPadding)
                .padding(.vertical, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var backgroundImage: Image? {
        guard let path = design.theme.backgroundImagePath else { return nil }
        return LocalAssetStore.loadImage(relativePath: path)
    }
}

/// Polymorphic block view used by both the live builder and the read-only
/// renderer so the two stay visually identical. Width style and outer
/// alignment are applied here; the inner block view handles its own padding,
/// background, and text/image style.
struct ProfileBlockView: View {
    let block: ProfileBlock

    var body: some View {
        switch block {
        case .text(let data):
            applyWidth(TextBlockView(data: data),
                       widthStyle: data.widthStyle,
                       alignment: data.alignment.frameAlignment,
                       leading: data.alignment == .leading,
                       trailing: data.alignment == .trailing)
        case .image(let data):
            // Image blocks have no per-block text alignment, so compact /
            // centered both center horizontally for a balanced page.
            applyWidth(ImageBlockView(data: data),
                       widthStyle: data.widthStyle,
                       alignment: .center,
                       leading: false,
                       trailing: false)
        case .container(let data):
            // Containers handle their own internal alignment for children;
            // outer compact/centered just centers the whole container in
            // its row, matching how images behave.
            applyWidth(ContainerBlockView(data: data),
                       widthStyle: data.widthStyle,
                       alignment: .center,
                       leading: false,
                       trailing: false)
        }
    }

    @ViewBuilder
    private func applyWidth<Content: View>(
        _ view: Content,
        widthStyle: BlockWidthStyle,
        alignment: Alignment,
        leading: Bool,
        trailing: Bool
    ) -> some View {
        switch widthStyle {
        case .fill:
            view
        case .compact:
            HStack(spacing: 0) {
                if !leading { Spacer(minLength: 0) }
                view
                if !trailing { Spacer(minLength: 0) }
            }
        case .centered:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                view
                Spacer(minLength: 0)
            }
        }
    }
}
