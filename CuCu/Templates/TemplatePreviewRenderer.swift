import SwiftUI

// MARK: - Template preview renderer
//
// Lightweight SwiftUI renderer used by the templates picker. Mirrors the
// prototype's `TplCanvas` / `TplNode` (`templates-picker.jsx`) — *not* the
// production `CanvasEditorView`. The picker only needs to show how a
// template *looks* at thumbnail size; reusing the heavy UIKit canvas
// would force layout math, gesture machinery, and inspector hooks that
// have nothing to do with a static preview.
//
// Coordinate space: nodes are laid out in their authored page-space
// positions inside an inner `ZStack` sized to `pageWidth × pageHeight`.
// The caller passes a `scale` and we apply a `.scaleEffect` + outer
// `.frame` so the preview occupies exactly the requested footprint.

/// Render a template `ProfileDocument` at thumbnail size.
struct TplCanvasView: View {
    let document: ProfileDocument
    let scale: CGFloat

    var body: some View {
        let pageWidth: CGFloat = CGFloat(document.pageWidth)
        let pageHeight: CGFloat = CGFloat(document.pages.first?.height ?? document.pageHeight)
        let bgHex = document.pages.first?.backgroundHex ?? document.pageBackgroundHex
        let patternKey = document.pages.first?.backgroundPatternKey

        ZStack(alignment: .topLeading) {
            Color(hex: bgHex)

            if let pattern = CanvasBackgroundPattern(key: patternKey) {
                CucuTilePatternView(pattern: pattern)
            }

            ForEach(orderedNodes(), id: \.id) { node in
                TplNodeView(node: node)
                    .frame(width: CGFloat(node.frame.width),
                           height: CGFloat(node.frame.height),
                           alignment: .topLeading)
                    .position(x: CGFloat(node.frame.x) + CGFloat(node.frame.width) / 2,
                              y: CGFloat(node.frame.y) + CGFloat(node.frame.height) / 2)
                    .opacity(node.opacity)
            }
        }
        .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
        .clipped()
        .scaleEffect(scale, anchor: .topLeading)
        // The scaleEffect is purely visual — the inner view still
        // reports its 390×805 footprint to layout. Without `alignment:
        // .topLeading` on this outer frame, SwiftUI center-aligns the
        // 390×805 view inside the smaller container, which combined
        // with the topLeading-anchored scale puts the rendered content
        // at a negative offset and chops the top + left off the
        // preview. Matching the alignment to the scale anchor lines
        // them up.
        .frame(width: pageWidth * scale, height: pageHeight * scale, alignment: .topLeading)
    }

    /// Root nodes in z-order (back → front). Falls back to the legacy
    /// `rootChildrenIDs` mirror when the document has no pages array.
    private func orderedNodes() -> [CanvasNode] {
        let rootIDs = document.pages.first?.rootChildrenIDs ?? document.rootChildrenIDs
        return rootIDs.compactMap { document.nodes[$0] }
    }
}

// MARK: - Per-node renderer

/// One node, rendered as a tiny SwiftUI view tree. The parent supplies
/// the frame; this view fills it with the right shape / text / image
/// for the node's type.
struct TplNodeView: View {
    let node: CanvasNode

    var body: some View {
        switch node.type {
        case .text:      tplText
        case .image:     tplImage
        case .icon:      tplIcon
        case .divider:   tplDivider
        case .link:      tplLink
        case .gallery:   tplGallery
        case .container: tplContainer
        case .carousel:  tplContainer
        }
    }

    // MARK: text
    @ViewBuilder
    private var tplText: some View {
        let style = node.style
        let family = style.fontFamily ?? .system
        let size = CGFloat(style.fontSize ?? 14)
        let weight = (style.fontWeight ?? .regular).swiftUIWeight
        let textColor = Color(hex: style.textColorHex ?? "#000000")
        let alignment = (style.textAlignment ?? .leading).swiftUIAlignment
        let textAlign = (style.textAlignment ?? .leading).swiftUITextAlignment
        let bgFill: Color? = style.backgroundColorHex.map { Color(hex: $0) }
        let radius = CGFloat(style.cornerRadius)
        let borderW = CGFloat(style.borderWidth)
        let borderColor = style.borderColorHex.map { Color(hex: $0) } ?? .clear

        Text(node.content.text ?? "")
            .font(family.swiftUIFont(size: size, weight: weight))
            .foregroundStyle(textColor)
            .multilineTextAlignment(textAlign)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(CGFloat(style.padding ?? 0))
            .background(bgFill)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(borderColor, lineWidth: borderW)
            )
    }

    // MARK: image
    @ViewBuilder
    private var tplImage: some View {
        let style = node.style
        let radius = CGFloat(style.cornerRadius)
        let borderW = CGFloat(style.borderWidth)
        let borderColor = style.borderColorHex.map { Color(hex: $0) } ?? .clear
        let isCircle = (style.clipShape ?? .rectangle) == .circle

        let base = bundledOrPlaceholderImage(for: node.content.localImagePath)
            .resizable()
            .aspectRatio(contentMode: (style.imageFit ?? .fill) == .fit ? .fit : .fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        if isCircle {
            base
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(borderColor, lineWidth: borderW))
        } else {
            base
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(borderColor, lineWidth: borderW)
                )
        }
    }

    // MARK: icon
    @ViewBuilder
    private var tplIcon: some View {
        let style = node.style
        let plate: Color = style.backgroundColorHex.map { Color(hex: $0) } ?? .clear
        let tint: Color = Color(hex: style.tintColorHex ?? style.textColorHex ?? "#000000")
        let radius = CGFloat(style.cornerRadius)
        let borderW = CGFloat(style.borderWidth)
        let borderColor = style.borderColorHex.map { Color(hex: $0) } ?? .clear
        let glyph = node.content.iconName ?? "heart.fill"

        // The symbol fills 60% of the smaller plate dimension so the
        // glyph reads centered with breathing room — matches the
        // prototype's `width="60%"` SVG sizing.
        GeometryReader { geo in
            let dim = min(geo.size.width, geo.size.height) * 0.6
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(plate)
                Image(systemName: glyph)
                    .resizable().scaledToFit()
                    .foregroundStyle(tint)
                    .frame(width: dim, height: dim)
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(borderColor, lineWidth: borderW)
            )
        }
    }

    // MARK: divider
    @ViewBuilder
    private var tplDivider: some View {
        let style = node.style
        let family = style.dividerStyleFamily ?? .solid
        let color = Color(hex: style.borderColorHex ?? "#000000")
        let thickness = CGFloat(style.dividerThickness ?? 2)

        switch family {
        case .solid:
            Rectangle().fill(color)
                .frame(height: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .dashed:
            DividerLineShape(dash: [thickness * 3, thickness * 2.5])
                .stroke(color, lineWidth: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .dotted:
            DividerLineShape(dash: [0, thickness * 3])
                .stroke(style: StrokeStyle(lineWidth: thickness * 1.4,
                                           lineCap: .round, dash: [0, thickness * 3]))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .double:
            VStack(spacing: thickness * 1.5) {
                Rectangle().fill(color).frame(height: thickness)
                Rectangle().fill(color).frame(height: thickness)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .heartChain, .starChain, .flowerChain, .sparkleChain, .bowDivider:
            ChainDividerView(symbolName: family.chainSymbol ?? "sparkle",
                             color: color,
                             thickness: thickness)
        case .lace, .ribbon, .pixel:
            // Less common families — fall back to a solid line so the
            // preview doesn't render blank for templates that happen to
            // use them. The production canvas paints the real treatment.
            Rectangle().fill(color)
                .frame(height: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: link
    @ViewBuilder
    private var tplLink: some View {
        let style = node.style
        let bg: Color = style.backgroundColorHex.map { Color(hex: $0) } ?? .clear
        let textColor = Color(hex: style.textColorHex ?? "#000000")
        let radius = CGFloat(style.cornerRadius)
        let borderW = CGFloat(style.borderWidth)
        let borderColor = style.borderColorHex.map { Color(hex: $0) } ?? .clear
        let family = style.fontFamily ?? .fraunces
        let size = CGFloat(style.fontSize ?? 16)
        let weight = (style.fontWeight ?? .semibold).swiftUIWeight
        let textAlign = (style.textAlignment ?? .center).swiftUITextAlignment

        Text(node.content.text ?? "")
            .font(family.swiftUIFont(size: size, weight: weight))
            .foregroundStyle(textColor)
            .multilineTextAlignment(textAlign)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(borderColor, lineWidth: borderW)
            )
    }

    // MARK: gallery
    @ViewBuilder
    private var tplGallery: some View {
        let style = node.style
        let radius = CGFloat(style.cornerRadius)
        let borderW = CGFloat(style.borderWidth)
        let borderColor = style.borderColorHex.map { Color(hex: $0) } ?? .clear
        let gap = CGFloat(style.galleryGap ?? 6)
        let paths = node.content.imagePaths ?? []
        // Always 2x2 — matches prototype's `tones[0..3]` template gallery.
        let row1 = Array(paths.prefix(2))
        let row2 = Array(paths.dropFirst(2).prefix(2))

        VStack(spacing: gap) {
            HStack(spacing: gap) {
                ForEach(row1.indices, id: \.self) { idx in
                    bundledOrPlaceholderImage(for: row1[idx])
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
            HStack(spacing: gap) {
                ForEach(row2.indices, id: \.self) { idx in
                    bundledOrPlaceholderImage(for: row2[idx])
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(borderColor, lineWidth: borderW)
        )
    }

    // MARK: container (and carousel approximation)
    @ViewBuilder
    private var tplContainer: some View {
        let style = node.style
        let bg: Color = style.backgroundColorHex.map { Color(hex: $0) } ?? .clear
        let radius = CGFloat(style.cornerRadius)
        let borderW = CGFloat(style.borderWidth)
        let borderColor = style.borderColorHex.map { Color(hex: $0) } ?? .clear

        RoundedRectangle(cornerRadius: radius)
            .fill(bg)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(borderColor, lineWidth: borderW)
            )
    }
}

// MARK: - Bundled image resolver

/// Pull a bundled tone (`bundled:tone-<peach|sage|sky|butter|rose>`) out
/// of the asset catalog. Anything else returns a soft gray placeholder
/// so previews never show a blank black box for paths the picker can't
/// resolve (user-saved templates with their own per-draft assets).
private func bundledOrPlaceholderImage(for path: String?) -> Image {
    guard let path, !path.isEmpty else {
        return Image(systemName: "photo")
    }
    if let name = CanvasImageLoader.bundledName(path) {
        return Image(name)
    }
    if let img = CanvasImageLoader.loadSync(path) {
        return Image(uiImage: img)
    }
    return Image(systemName: "photo")
}

// MARK: - Chain divider helper

/// 5 evenly-spaced glyphs with thin connecting capsule lines, matching
/// `templates-picker.jsx` `DividerSVG` for the chain families.
private struct ChainDividerView: View {
    let symbolName: String
    let color: Color
    let thickness: CGFloat

    var body: some View {
        GeometryReader { geo in
            let count = 5
            let glyphSize = max(8, geo.size.height - 2)
            let totalGlyphWidth = glyphSize * CGFloat(count)
            let segmentWidth = max(0, (geo.size.width - totalGlyphWidth) / CGFloat(count + 1))

            HStack(spacing: 0) {
                Capsule().fill(color)
                    .frame(width: segmentWidth, height: thickness)
                ForEach(0..<count, id: \.self) { idx in
                    Image(systemName: symbolName)
                        .resizable().scaledToFit()
                        .foregroundStyle(color)
                        .frame(width: glyphSize, height: glyphSize)
                    if idx < count - 1 {
                        Capsule().fill(color)
                            .frame(width: segmentWidth, height: thickness)
                    }
                }
                Capsule().fill(color)
                    .frame(width: segmentWidth, height: thickness)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }
}

// MARK: - Plain horizontal-line shape used by dashed dividers

private struct DividerLineShape: Shape {
    var dash: [CGFloat]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: rect.width, y: y))
        return p.strokedPath(StrokeStyle(lineWidth: 1, dash: dash))
    }
}

// MARK: - Mini iPhone bezel

/// Simplified iPhone bezel for the picker thumbnails — rounded inset,
/// black bezel, top speaker pill, soft drop shadow. Matches the
/// prototype's `MiniDevice` and the style shown in the screenshot.
struct MiniDeviceFrame<Content: View>: View {
    let cornerRadius: CGFloat
    let bezelThickness: CGFloat
    let content: () -> Content

    init(cornerRadius: CGFloat = 28,
         bezelThickness: CGFloat = 6,
         @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.bezelThickness = bezelThickness
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(hex: "#1A140E"))

            content()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius - bezelThickness))
                .padding(bezelThickness)

            // Speaker pill
            Capsule()
                .fill(Color.black)
                .frame(width: 40, height: 8)
                .padding(.top, bezelThickness * 1.4)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 12)
    }
}

// MARK: - NodeStyle enum bridges

extension NodeFontWeight {
    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular:  return .regular
        case .medium:   return .medium
        case .semibold: return .semibold
        case .bold:     return .bold
        }
    }
}

extension NodeTextAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
}

