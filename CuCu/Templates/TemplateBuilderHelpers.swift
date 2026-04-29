import Foundation

// MARK: - Coordinate scale
//
// Prototype coords were authored against a 320×660 mini iPhone canvas;
// CuCu pages are 390pt wide. Earlier this scaled the prototype's full
// 320pt design space onto the page's full 390pt width — content sat
// flush against the canvas edges, which on a typical iPhone 15 (which
// renders the canvas edge-to-edge with the screen) made every node
// touch the device bezel with no breathing room.
//
// Now we map the prototype's 320pt design onto a slightly narrower
// `templateContentWidth` (360pt) and shift it horizontally by
// `templateContentInset` (15pt) so each template lives in canvas-x
// 15..375 — symmetrical 15pt of canvas-bg gutter on either side.
// Crucially the *page background* still fills the full 390pt page
// width (and the page itself fills the screen on most phones), so
// users see breathing room around content rather than paper-color
// whitespace around the canvas. Best of both worlds.

/// Authored width of a template's content area, inside the page. Less
/// than `ProfileDocument.defaultPageWidth` so content has visible
/// gutter on either side without exposing the desk surface.
let templateContentWidth: Double = 360

/// Horizontal offset every node frame gets shifted by, so the content
/// area sits centred inside the page. `(390 - 360) / 2 = 15`.
let templateContentInset: Double = (ProfileDocument.defaultPageWidth - templateContentWidth) / 2

/// 360 ÷ 320 = 1.125. Slightly smaller than the previous 1.21875 — the
/// 6% trim is what produces the side gutters.
let templateScale: Double = templateContentWidth / 320.0

/// Page height the templates are sized into. Tracks the new scale so
/// vertical proportions stay consistent with the prototype layout.
/// Stays well under `ProfileDocument.defaultPageHeight` of 1000.
let templatePageHeight: Double = 660 * templateScale

@inline(__always)
private func sc(_ v: Double) -> Double { v * templateScale }

@inline(__always)
private func tFrame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NodeFrame {
    // Shift x by the content inset so x=0 in prototype-coords lands at
    // x=15 in canvas-coords. Width is unchanged (we already shrunk via
    // `templateScale`), so the right edge sits at 15 + (320*scale) = 375
    // — the same 15pt gutter on the trailing side.
    NodeFrame(
        x: sc(x) + templateContentInset,
        y: sc(y),
        width: sc(w),
        height: sc(h)
    )
}

// MARK: - Helpers used by every template

enum TemplateBuilder {
    // Kept inside the enum so private helpers below can sit alongside the
    // seven build entry points without leaking into module scope. The
    // seven `static func ...()` builders live in this file's extensions
    // (one per template) further down.
}

// MARK: - Node constructors
//
// One per node type, matching the prototype's `N(id, type, props)`
// shape but type-checked. All accept prototype-space coordinates and
// scale them in one spot. Defaults match the prototype's defaults so
// templates don't have to repeat them on every call.

extension TemplateBuilder {

    static func textNode(_ id: UUID,
                                     x: Double, y: Double, w: Double, h: Double,
                                     text: String,
                                     font: NodeFontFamily,
                                     weight: NodeFontWeight = .regular,
                                     size: Double,
                                     color: String,
                                     align: NodeTextAlignment = .leading,
                                     bg: String? = nil,
                                     radius: Double = 0,
                                     borderW: Double = 0,
                                     borderC: String? = nil,
                                     padding: Double = 0) -> CanvasNode {
        CanvasNode(
            id: id,
            type: .text,
            frame: tFrame(x, y, w, h),
            style: NodeStyle(
                backgroundColorHex: bg,
                cornerRadius: sc(radius),
                borderWidth: sc(borderW),
                borderColorHex: borderC,
                fontFamily: font,
                fontWeight: weight,
                fontSize: sc(size),
                textColorHex: color,
                textAlignment: align,
                padding: padding > 0 ? sc(padding) : nil
            ),
            content: NodeContent(text: text)
        )
    }

    static func imageNode(_ id: UUID,
                                      x: Double, y: Double, w: Double, h: Double,
                                      tone: String,
                                      radius: Double = 0,
                                      clip: NodeClipShape = .rectangle,
                                      borderW: Double = 0,
                                      borderC: String? = nil) -> CanvasNode {
        CanvasNode(
            id: id,
            type: .image,
            frame: tFrame(x, y, w, h),
            style: NodeStyle(
                cornerRadius: sc(radius),
                borderWidth: sc(borderW),
                borderColorHex: borderC,
                imageFit: .fill,
                clipShape: clip
            ),
            content: NodeContent(localImagePath: "bundled:tone-\(tone)")
        )
    }

    static func iconNode(_ id: UUID,
                                     x: Double, y: Double, w: Double, h: Double,
                                     glyph: String,
                                     plate: String,
                                     tint: String,
                                     radius: Double = 0,
                                     borderW: Double = 0,
                                     borderC: String? = nil,
                                     family: NodeIconStyleFamily = .plain) -> CanvasNode {
        CanvasNode(
            id: id,
            type: .icon,
            frame: tFrame(x, y, w, h),
            style: NodeStyle(
                backgroundColorHex: plate,
                cornerRadius: sc(radius),
                borderWidth: sc(borderW),
                borderColorHex: borderC,
                iconStyleFamily: family,
                tintColorHex: tint
            ),
            content: NodeContent(iconName: glyph)
        )
    }

    static func dividerNode(_ id: UUID,
                                        x: Double, y: Double, w: Double, h: Double,
                                        style: NodeDividerStyleFamily,
                                        color: String,
                                        thickness: Double = 2) -> CanvasNode {
        CanvasNode(
            id: id,
            type: .divider,
            frame: tFrame(x, y, w, h),
            style: NodeStyle(
                borderColorHex: color,
                dividerStyleFamily: style,
                dividerThickness: sc(thickness)
            )
        )
    }

    static func linkNode(_ id: UUID,
                                     x: Double, y: Double, w: Double, h: Double,
                                     text: String,
                                     url: String = "#",
                                     bg: String?,
                                     textColor: String,
                                     borderW: Double = 0,
                                     borderC: String? = nil,
                                     radius: Double = 0,
                                     font: NodeFontFamily = .fraunces,
                                     weight: NodeFontWeight = .semibold,
                                     size: Double = 16,
                                     align: NodeTextAlignment = .center) -> CanvasNode {
        CanvasNode(
            id: id,
            type: .link,
            frame: tFrame(x, y, w, h),
            style: NodeStyle(
                backgroundColorHex: bg,
                cornerRadius: sc(radius),
                borderWidth: sc(borderW),
                borderColorHex: borderC,
                fontFamily: font,
                fontWeight: weight,
                fontSize: sc(size),
                textColorHex: textColor,
                textAlignment: align,
                linkStyleVariant: .pill
            ),
            content: NodeContent(text: text, url: url)
        )
    }

    static func galleryNode(_ id: UUID,
                                        x: Double, y: Double, w: Double, h: Double,
                                        tones: [String],
                                        gap: Double = 6,
                                        radius: Double = 0,
                                        borderW: Double = 0,
                                        borderC: String? = nil,
                                        layout: NodeGalleryLayout = .grid) -> CanvasNode {
        CanvasNode(
            id: id,
            type: .gallery,
            frame: tFrame(x, y, w, h),
            style: NodeStyle(
                cornerRadius: sc(radius),
                borderWidth: sc(borderW),
                borderColorHex: borderC,
                galleryLayout: layout,
                galleryGap: sc(gap)
            ),
            content: NodeContent(imagePaths: tones.map { "bundled:tone-\($0)" })
        )
    }

    static func containerNode(_ id: UUID,
                                          x: Double, y: Double, w: Double, h: Double,
                                          bg: String,
                                          radius: Double = 0,
                                          borderW: Double = 0,
                                          borderC: String? = nil) -> CanvasNode {
        CanvasNode(
            id: id,
            type: .container,
            frame: tFrame(x, y, w, h),
            style: NodeStyle(
                backgroundColorHex: bg,
                cornerRadius: sc(radius),
                borderWidth: sc(borderW),
                borderColorHex: borderC
            )
        )
    }
}

// MARK: - Document assembly
//
// Wraps a sequence of nodes into a `ProfileDocument` with a single
// page. Z-order follows the array order (first element renders behind,
// last on top) — matches the prototype's `order` array. zIndex is set
// from the index so renderers that consult zIndex see the same order.

extension TemplateBuilder {

    static func assemble(bgColor: String,
                                     bgPatternKey: String? = nil,
                                     orderedNodes: [CanvasNode]) -> ProfileDocument {
        var nodes: [UUID: CanvasNode] = [:]
        var rootIDs: [UUID] = []

        for (index, node) in orderedNodes.enumerated() {
            var stamped = node
            stamped.zIndex = index
            nodes[stamped.id] = stamped
            rootIDs.append(stamped.id)
        }

        let page = PageStyle(
            height: templatePageHeight,
            backgroundHex: bgColor,
            backgroundPatternKey: bgPatternKey,
            rootChildrenIDs: rootIDs
        )

        return ProfileDocument(
            pageWidth: ProfileDocument.defaultPageWidth,
            pageHeight: templatePageHeight,
            pageBackgroundHex: bgColor,
            pages: [page],
            nodes: nodes
        )
    }
}
