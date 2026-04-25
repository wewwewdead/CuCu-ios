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

    init(backgroundColorHex: String? = nil,
         cornerRadius: Double = 0,
         borderWidth: Double = 0,
         borderColorHex: String? = nil,
         fontFamily: NodeFontFamily? = nil,
         fontSize: Double? = nil,
         textColorHex: String? = nil,
         textAlignment: NodeTextAlignment? = nil,
         imageFit: NodeImageFit? = nil,
         clipShape: NodeClipShape? = nil,
         backgroundImagePath: String? = nil,
         backgroundBlur: Double? = nil,
         backgroundVignette: Double? = nil,
         containerBlur: Double? = nil,
         containerVignette: Double? = nil) {
        self.backgroundColorHex = backgroundColorHex
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColorHex = borderColorHex
        self.fontFamily = fontFamily
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
    }
}

/// System font families. String-backed so JSON stays human-readable and stable
/// across model versions even if the enum is reordered.
enum NodeFontFamily: String, Codable, CaseIterable, Hashable {
    case system
    case serif
    case rounded
    case monospaced
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
