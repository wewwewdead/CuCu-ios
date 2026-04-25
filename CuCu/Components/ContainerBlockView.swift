import SwiftUI

/// Renders a container block: stacks its children along an axis with the
/// configured spacing and cross-axis alignment, then applies padding,
/// background, corner radius / circle clip, and width-style.
///
/// Containers are recursive — a child can itself be `.container(...)`. The
/// dispatcher in `ProfileBlockView` recurses through `ProfileBlockView`
/// instances, so arbitrarily deep nesting just works.
struct ContainerBlockView: View {
    let data: ContainerBlockData

    var body: some View {
        stackedChildren
            .padding(data.padding)
            .frame(maxWidth: data.widthStyle == .fill ? .infinity : nil,
                   alignment: data.contentAlignment.frameAlignment)
            .background(Color(hex: data.backgroundColorHex))
            .clipShape(outerShape)
    }

    @ViewBuilder
    private var stackedChildren: some View {
        switch data.axis {
        case .vertical:
            VStack(alignment: data.contentAlignment.horizontal, spacing: data.spacing) {
                ForEach(data.children) { child in
                    ProfileBlockView(block: child)
                }
            }
        case .horizontal:
            HStack(alignment: data.contentAlignment.vertical, spacing: data.spacing) {
                ForEach(data.children) { child in
                    ProfileBlockView(block: child)
                }
            }
        }
    }

    /// AnyShape because `clipShape(_:)` requires a concrete Shape, not a
    /// `@ViewBuilder` opaque view. Available on iOS 16+ (deployment target
    /// is iOS 26.4).
    private var outerShape: AnyShape {
        switch data.clipShape {
        case .rectangle:
            AnyShape(RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous))
        case .circle:
            AnyShape(Circle())
        }
    }
}

private extension ContainerContentAlignment {
    /// Used for the outer `.frame(maxWidth:alignment:)` so non-fill containers
    /// position themselves consistently with their children's cross-axis pull.
    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
