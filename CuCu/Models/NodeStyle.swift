import Foundation

/// Visual styling for a node. Superset across node types — a text node ignores
/// border fields and a container node ignores font fields. Optionality keeps
/// JSON payloads small and lets new fields ship without breaking older drafts.
struct NodeStyle: Codable, Hashable {
    var backgroundColorHex: String?
    var cornerRadius: Double
    var borderWidth: Double
    var borderColorHex: String?

    var fontFamily: NodeFontFamily?
    var fontWeight: NodeFontWeight?
    var fontSize: Double?
    var textColorHex: String?
    var textAlignment: NodeTextAlignment?

    var imageFit: NodeImageFit?
    var clipShape: NodeClipShape?

    /// Optional relative path (resolved via `LocalCanvasAssetStore`) of
    /// an image rendered behind the node's children, on top of
    /// `backgroundColorHex`. Used by container nodes to host a photo
    /// background. `nil` = color only. Backward compatible — old drafts
    /// without this field decode unchanged.
    var backgroundImagePath: String?
    /// Gaussian blur radius applied to `backgroundImagePath` when set.
    /// `nil` (or 0) means no blur. Same range we expose for the page
    /// background (0…30).
    var backgroundBlur: Double?
    /// Vignette intensity applied to `backgroundImagePath`. `nil`
    /// (or 0) means no vignette.
    var backgroundVignette: Double?

    /// Frosted-glass blur applied to the **whole container** (background
    /// image + all nested children). `0...1` — alpha-fades a
    /// `UIVisualEffectView` overlay on top of the container's contents.
    /// Distinct from `backgroundBlur` which is a precise CoreImage
    /// Gaussian on the background image only.
    var containerBlur: Double?
    /// Radial darkening at the corners of the **whole container**.
    /// `0...1` controls how dark the corners become. Distinct from
    /// `backgroundVignette` which only fades the background image.
    var containerVignette: Double?

    /// Frosted-glass blur drawn **behind a text node** — samples
    /// whatever is rendered behind the text on the canvas (page bg,
    /// sibling nodes, parent container) and shows a blurred copy. The
    /// text glyphs render sharp on top. `0...1` — alpha-fades a
    /// `UIVisualEffectView` overlay sitting at the back of the text
    /// node's subview stack.
    ///
    /// Intentionally separate from `containerBlur` so the user can
    /// frost a text label without affecting any container it lives in
    /// (and vice versa). When `> 0`, `TextNodeView` clears the text
    /// node's own `backgroundColorHex` fill so the blur is visible
    /// instead of being painted over.
    var textBackdropBlur: Double?

    // MARK: - New-element styling
    //
    // The remaining fields are all leaf-type-specific. Each one is
    // optional so adding it doesn't widen the JSON for nodes that don't
    // need it, and old drafts that predate a field decode unchanged.

    /// Cute-aesthetic family that drives the look of an `.icon` node —
    /// background plate shape, colored halo, doodle overlay, etc. The
    /// SF Symbol itself comes from `NodeContent.iconName`.
    var iconStyleFamily: NodeIconStyleFamily?
    /// Per-node tint color (hex). Used today by `.icon` nodes for the
    /// glyph color when distinct from text color is desired. Reuses
    /// `textColorHex` would conflate "text label color" with "icon
    /// glyph color"; a dedicated field keeps both meaningful.
    var tintColorHex: String?

    /// Pattern family for `.divider` nodes — solid, dashed, sparkle
    /// chain, lace, etc. `borderColorHex` carries the divider color.
    var dividerStyleFamily: NodeDividerStyleFamily?
    /// Stroke / glyph thickness for divider rendering, in points.
    /// Defaults to 2 if `nil`. Distinct from `borderWidth` — a divider
    /// has no perimeter border, so reusing that field would overload it.
    var dividerThickness: Double?

    /// Visual treatment for `.link` nodes — pill, card, underlined
    /// text, button, badge.
    var linkStyleVariant: NodeLinkStyleVariant?

    /// Layout for `.gallery` nodes — grid, row, collage.
    var galleryLayout: NodeGalleryLayout?
    /// Inter-image gap inside a gallery, in points.
    var galleryGap: Double?

    /// Inner padding around text inside a `.text` node (used by
    /// `TextNodeView` to inset its `UITextView` from the node frame).
    /// Applies uniformly to all four sides. `nil` falls back to a
    /// small default — the renderer is the single source of truth
    /// for what that default is so older drafts keep their look.
    var padding: Double?
    /// Extra line spacing in points for text content (rendered via
    /// `NSMutableParagraphStyle.lineSpacing`). `nil` or `0` keeps the
    /// font's natural line height.
    var lineSpacing: Double?

    init(backgroundColorHex: String? = nil,
         cornerRadius: Double = 0,
         borderWidth: Double = 0,
         borderColorHex: String? = nil,
         fontFamily: NodeFontFamily? = nil,
         fontWeight: NodeFontWeight? = nil,
         fontSize: Double? = nil,
         textColorHex: String? = nil,
         textAlignment: NodeTextAlignment? = nil,
         imageFit: NodeImageFit? = nil,
         clipShape: NodeClipShape? = nil,
         backgroundImagePath: String? = nil,
         backgroundBlur: Double? = nil,
         backgroundVignette: Double? = nil,
         containerBlur: Double? = nil,
         containerVignette: Double? = nil,
         textBackdropBlur: Double? = nil,
         iconStyleFamily: NodeIconStyleFamily? = nil,
         tintColorHex: String? = nil,
         dividerStyleFamily: NodeDividerStyleFamily? = nil,
         dividerThickness: Double? = nil,
         linkStyleVariant: NodeLinkStyleVariant? = nil,
         galleryLayout: NodeGalleryLayout? = nil,
         galleryGap: Double? = nil,
         padding: Double? = nil,
         lineSpacing: Double? = nil) {
        self.backgroundColorHex = backgroundColorHex
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColorHex = borderColorHex
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight
        self.fontSize = fontSize
        self.textColorHex = textColorHex
        self.textAlignment = textAlignment
        self.imageFit = imageFit
        self.clipShape = clipShape
        self.backgroundImagePath = backgroundImagePath
        self.backgroundBlur = backgroundBlur
        self.backgroundVignette = backgroundVignette
        self.containerBlur = containerBlur
        self.containerVignette = containerVignette
        self.textBackdropBlur = textBackdropBlur
        self.iconStyleFamily = iconStyleFamily
        self.tintColorHex = tintColorHex
        self.dividerStyleFamily = dividerStyleFamily
        self.dividerThickness = dividerThickness
        self.linkStyleVariant = linkStyleVariant
        self.galleryLayout = galleryLayout
        self.galleryGap = galleryGap
        self.padding = padding
        self.lineSpacing = lineSpacing
    }
}

extension NodeStyle {
    private enum CodingKeys: String, CodingKey {
        case backgroundColorHex
        case cornerRadius
        case borderWidth
        case borderColorHex
        case fontFamily
        case fontWeight
        case fontSize
        case textColorHex
        case textAlignment
        case imageFit
        case clipShape
        case backgroundImagePath
        case backgroundBlur
        case backgroundVignette
        case containerBlur
        case containerVignette
        case textBackdropBlur
        case iconStyleFamily
        case tintColorHex
        case dividerStyleFamily
        case dividerThickness
        case linkStyleVariant
        case galleryLayout
        case galleryGap
        case padding
        case lineSpacing
    }

    /// Custom decoder so old drafts decode cleanly when new fields are
    /// added. Each new field reads `decodeIfPresent` so a JSON written
    /// before that field existed simply lands as `nil` / default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex)
        self.cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        self.borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        self.borderColorHex = try c.decodeIfPresent(String.self, forKey: .borderColorHex)
        self.fontFamily = try c.decodeIfPresent(NodeFontFamily.self, forKey: .fontFamily)
        self.fontWeight = try c.decodeIfPresent(NodeFontWeight.self, forKey: .fontWeight)
        self.fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        self.textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex)
        self.textAlignment = try c.decodeIfPresent(NodeTextAlignment.self, forKey: .textAlignment)
        self.imageFit = try c.decodeIfPresent(NodeImageFit.self, forKey: .imageFit)
        self.clipShape = try c.decodeIfPresent(NodeClipShape.self, forKey: .clipShape)
        self.backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        self.backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur)
        self.backgroundVignette = try c.decodeIfPresent(Double.self, forKey: .backgroundVignette)
        self.containerBlur = try c.decodeIfPresent(Double.self, forKey: .containerBlur)
        self.containerVignette = try c.decodeIfPresent(Double.self, forKey: .containerVignette)
        self.textBackdropBlur = try c.decodeIfPresent(Double.self, forKey: .textBackdropBlur)
        self.iconStyleFamily = try c.decodeIfPresent(NodeIconStyleFamily.self, forKey: .iconStyleFamily)
        self.tintColorHex = try c.decodeIfPresent(String.self, forKey: .tintColorHex)
        self.dividerStyleFamily = try c.decodeIfPresent(NodeDividerStyleFamily.self, forKey: .dividerStyleFamily)
        self.dividerThickness = try c.decodeIfPresent(Double.self, forKey: .dividerThickness)
        self.linkStyleVariant = try c.decodeIfPresent(NodeLinkStyleVariant.self, forKey: .linkStyleVariant)
        self.galleryLayout = try c.decodeIfPresent(NodeGalleryLayout.self, forKey: .galleryLayout)
        self.galleryGap = try c.decodeIfPresent(Double.self, forKey: .galleryGap)
        self.padding = try c.decodeIfPresent(Double.self, forKey: .padding)
        self.lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing)
    }
}

/// Font families available to text and link nodes. String-backed so
/// JSON stays human-readable and stable across model versions even if
/// the enum is reordered.
///
/// Two groups:
///
/// 1. **System families** (`system`, `serif`, `rounded`, `monospaced`) —
///    resolved through `Font.system(design:)`/`UIFont.systemFont` so
///    they always render even on first launch with no font registration.
///
/// 2. **Bundled cute / artsy faces** (Caprasimo, Pacifico, Lobster,
///    Caveat, Permanent Marker, Shadows Into Light, Patrick Hand,
///    Bungee, Fredoka, Modak, Press Start 2P, Yeseva One, Abril
///    Fatface) — registered at app launch from `CuCu/Fonts/` and
///    resolved through `Font.custom`/`UIFont(name:size:)`. These
///    expand the user's vocabulary beyond the four built-ins so a
///    profile can read scrapbook, signature-handwriting, pixel-retro,
///    fashion-display, etc.
///
/// New cases at the bottom of the enum are forward-compatible: old
/// drafts decode unchanged because every reader uses
/// `decodeIfPresent` for `fontFamily` (which falls back to `.system`
/// when missing). Drafts saved on a newer build that contain a new
/// case won't open on an older binary, but the app's deployment
/// target moves with the model so this is fine.
enum NodeFontFamily: String, Codable, CaseIterable, Hashable {
    // System families
    case system
    case serif
    case rounded
    case monospaced

    // Bundled cute / artsy display faces
    case caprasimo            // chunky cute serif
    case yesevaOne            // elegant cute serif
    case abrilFatface         // bold display serif
    case fraunces             // editorial italic-leaning serif

    // Bundled bubbly / blocky display
    case fredoka              // rounded chunky
    case modak                // extra-bold bubbly
    case bungee               // blocky display

    // Bundled handwritten
    case caveat               // signature script
    case pacifico             // flowing script
    case lobster              // bold cursive
    case permanentMarker      // sketchy bold
    case shadowsIntoLight     // soft handwriting
    case patrickHand          // friendly handwriting

    // Bundled retro
    case pressStart2P         // pixel
}

extension NodeFontFamily {
    /// Forward-compatible decoder. The synthesized String-rawValue
    /// `init(from:)` would throw `DecodingError.dataCorrupted` on an
    /// unknown raw value, which means a draft saved on a future
    /// build that adds a new font case fails to load on an older
    /// binary. Treating unknown values as `.system` lets the rest
    /// of the document continue to render — the user just sees the
    /// system font on that one node until they reopen on a newer
    /// build. Encoder stays the synthesized rawValue path so old
    /// binaries don't *write* `"system"` over a future case they
    /// happened to round-trip through memory.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NodeFontFamily(rawValue: raw) ?? .system
    }
}

enum NodeFontWeight: String, Codable, CaseIterable, Hashable {
    case regular
    case medium
    case semibold
    case bold
}

enum NodeTextAlignment: String, Codable, CaseIterable, Hashable {
    case leading
    case center
    case trailing
}

/// How an image fills its node frame. Maps directly to UIView.ContentMode
/// in `ImageNodeView`.
enum NodeImageFit: String, Codable, CaseIterable, Hashable {
    /// Crop to fill the entire frame (`.scaleAspectFill`).
    case fill
    /// Letterbox to fit entirely inside the frame (`.scaleAspectFit`).
    case fit
}

/// Outer clipping for image nodes. `circle` makes a square frame render as
/// a profile-picture circle; non-square frames render as a capsule (the
/// shorter side determines the corner radius). Listed as an enum rather than
/// a Bool so we can add `roundedSquare`, `hexagon`, etc. later without
/// migrating drafts.
enum NodeClipShape: String, Codable, CaseIterable, Hashable {
    case rectangle
    case circle
}

// MARK: - Icon style families
//
// Each family describes a *visual recipe* applied around the SF Symbol
// glyph: background plate, halo, doodle accents, weight, color
// treatment. The icon name (heart, star, etc.) is independent — the
// same heart can render as `pastelDoodle` or `cyberCute` and feel
// like a different sticker each time.

enum NodeIconStyleFamily: String, Codable, CaseIterable, Hashable {
    case pastelDoodle    // soft pastel disk + doodled offset shadow
    case y2kCute         // chrome bevel + glossy highlight
    case pixelCute       // chunky pixel-frame, hard edges
    case handDrawn       // wobbly outline + sketchy halo
    case sticker         // thick white border + drop shadow ("die-cut")
    case softMinimal     // no plate, low-weight glyph in muted tone
    case glossyKawaii    // candy gradient disk + shine
    case scrapbook       // washi-tape rectangle behind glyph
    case dreamy          // soft outer glow + gradient tint
    case coquette        // dusty rose disk + bow accent
    case retroWeb        // hard outline + 90s palette
    case cyberCute       // neon stroke + dark plate

    /// Display name used by the inspector menu.
    var label: String {
        switch self {
        case .pastelDoodle: return "Pastel Doodle"
        case .y2kCute: return "Y2K Cute"
        case .pixelCute: return "Pixel Cute"
        case .handDrawn: return "Hand-Drawn"
        case .sticker: return "Sticker"
        case .softMinimal: return "Soft Minimal"
        case .glossyKawaii: return "Glossy Kawaii"
        case .scrapbook: return "Scrapbook"
        case .dreamy: return "Dreamy"
        case .coquette: return "Coquette"
        case .retroWeb: return "Retro Web"
        case .cyberCute: return "Cyber Cute"
        }
    }
}

// MARK: - Divider style families

enum NodeDividerStyleFamily: String, Codable, CaseIterable, Hashable {
    case solid
    case dashed
    case dotted
    case double
    case sparkleChain
    case starChain
    case flowerChain
    case heartChain
    case bowDivider
    case lace
    case ribbon
    case pixel

    var label: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        case .double: return "Double"
        case .sparkleChain: return "Sparkle Chain"
        case .starChain: return "Star Chain"
        case .flowerChain: return "Flower Chain"
        case .heartChain: return "Heart Chain"
        case .bowDivider: return "Bow Divider"
        case .lace: return "Lace"
        case .ribbon: return "Ribbon"
        case .pixel: return "Pixel"
        }
    }

    /// SF Symbol used for the chain-style families. `nil` for line-style
    /// families (solid/dashed/dotted/double/lace/ribbon/pixel) which are
    /// drawn with stroke patterns instead.
    var chainSymbol: String? {
        switch self {
        case .sparkleChain: return "sparkle"
        case .starChain:    return "star.fill"
        case .flowerChain:  return "camera.macro"
        case .heartChain:   return "heart.fill"
        case .bowDivider:   return "ribbon"
        default: return nil
        }
    }
}

// MARK: - Link style variants

enum NodeLinkStyleVariant: String, Codable, CaseIterable, Hashable {
    case pill          // capsule-shaped solid background
    case card          // rectangular tile with title + subtitle
    case underlined    // plain text with a wavy underline
    case button        // rectangular fill + bold title
    case badge         // small chip with bracketed text

    var label: String {
        switch self {
        case .pill: return "Pill"
        case .card: return "Card"
        case .underlined: return "Underlined"
        case .button: return "Button"
        case .badge: return "Badge"
        }
    }
}

// MARK: - Gallery layouts

enum NodeGalleryLayout: String, Codable, CaseIterable, Hashable {
    case grid          // 2-3 column tile grid
    case row           // horizontal strip (no scroll, fits-to-width)
    case collage       // overlapping rotated tiles

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .row: return "Row"
        case .collage: return "Collage"
        }
    }
}
