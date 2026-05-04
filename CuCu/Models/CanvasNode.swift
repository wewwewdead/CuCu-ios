import CoreGraphics
import Foundation

/// Node type discriminator. String-backed for forward-compatible JSON.
///
/// Old drafts that predate any of the new cases (`icon`, `divider`, `link`,
/// `gallery`) cannot contain those values, so `decodeIfPresent`-driven
/// fields elsewhere don't need a migration. New drafts that contain the new
/// types simply won't open on an older app version — the canvas decoder
/// would fail the type lookup and fall back to the legacy banner.
enum NodeType: String, Codable, Hashable {
    case container
    case text
    case image
    case icon
    case divider
    case link
    case gallery
    /// Container variant whose children render in a horizontally
    /// scrollable strip. Child frames live in the carousel's scroll
    /// content coordinate space.
    case carousel
    /// Note card. Three text regions (title, timestamp, body) inside a
    /// container-style chrome. Body truncates with `…` in the editor;
    /// the published profile expands the full text in a sheet (mirrors
    /// gallery's "view gallery" published-only flow).
    case note
}

enum CanvasNodeRole: String, Codable, Hashable {
    case profileHero
    case profileAvatar
    case profileName
    case profileBio
    case profileMeta
    case fixedDivider
    case sectionCard

    var isSystemOwned: Bool {
        switch self {
        case .profileHero, .profileAvatar, .profileName, .profileBio, .profileMeta, .fixedDivider:
            return true
        case .sectionCard:
            return false
        }
    }
}

enum CanvasResizeBehavior: String, Codable, Hashable {
    case freeform
    case locked
    case verticalOnly
}

/// One element in the scene graph.
///
/// `parentId` is intentionally absent — parentage is owned by `ProfileDocument`
/// via `childrenIDs`. A single source of truth eliminates the "ghost child"
/// class of bugs (e.g., delete forgets to clear parent's list).
struct CanvasNode: Codable, Hashable, Identifiable {
    var id: UUID
    var type: NodeType
    /// User-supplied label, e.g., "Hero Section" on a container. Optional —
    /// `nil` (or empty) means "no custom name", and views fall back to the
    /// type-derived label ("Container", "Text", "Image"). Old drafts that
    /// don't include this field decode unchanged.
    var name: String?
    var childrenIDs: [UUID]
    var frame: NodeFrame
    var zIndex: Int
    var opacity: Double
    /// Optional semantic ownership used by the structured profile builder.
    /// Nil means legacy/freeform behavior and decodes cleanly for older drafts.
    var role: CanvasNodeRole?
    /// Optional edit constraint used by the editor. Nil is treated as freeform
    /// so existing documents keep their original drag/resize behavior.
    var resizeBehavior: CanvasResizeBehavior?
    var style: NodeStyle
    var content: NodeContent

    init(id: UUID = UUID(),
         type: NodeType,
         name: String? = nil,
         childrenIDs: [UUID] = [],
         frame: NodeFrame,
         zIndex: Int = 0,
         opacity: Double = 1.0,
         role: CanvasNodeRole? = nil,
         resizeBehavior: CanvasResizeBehavior? = nil,
         style: NodeStyle = NodeStyle(),
         content: NodeContent = NodeContent()) {
        self.id = id
        self.type = type
        self.name = name
        self.childrenIDs = childrenIDs
        self.frame = frame
        self.zIndex = zIndex
        self.opacity = opacity
        self.role = role
        self.resizeBehavior = resizeBehavior
        self.style = style
        self.content = content
    }
}

extension CanvasNode {
    var isSystemOwnedProfileNode: Bool {
        role?.isSystemOwned == true
    }
}

extension CanvasNode {
    /// Default styled container — visible against the page background and
    /// centered enough to spot when added.
    static func defaultContainer(at origin: CGPoint = CGPoint(x: 32, y: 80),
                                 size: CGSize = CGSize(width: 240, height: 160)) -> CanvasNode {
        CanvasNode(
            type: .container,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: "#FFFFFF",
                cornerRadius: 12,
                borderWidth: 1,
                borderColorHex: "#E5E5EA"
            )
        )
    }

    /// Default styled text node — readable size, transparent background so it
    /// reads cleanly when dropped on a colored container.
    static func defaultText(at origin: CGPoint = CGPoint(x: 32, y: 80),
                            size: CGSize = CGSize(width: 200, height: 44)) -> CanvasNode {
        CanvasNode(
            type: .text,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: nil,
                cornerRadius: 0,
                fontFamily: .system,
                fontWeight: .regular,
                fontSize: 18,
                textColorHex: "#1C1C1E",
                textAlignment: .leading
            ),
            content: NodeContent(text: "Text")
        )
    }

    /// Default styled image node. Square 200×200 so a circle clip yields a
    /// true profile-picture circle out of the box; users can resize freely
    /// after.
    static func defaultImage(localImagePath: String,
                             at origin: CGPoint = CGPoint(x: 32, y: 80),
                             size: CGSize = CGSize(width: 200, height: 200)) -> CanvasNode {
        CanvasNode(
            type: .image,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: nil,
                cornerRadius: 8,
                borderWidth: 0,
                borderColorHex: nil,
                imageFit: .fill,
                clipShape: .rectangle
            ),
            content: NodeContent(localImagePath: localImagePath)
        )
    }

    /// Default styled icon node — pastel-doodle plate behind a heart so
    /// the very first frame shows what an icon *is* without any setup
    /// from the user. They tweak family / glyph / color from the
    /// inspector after dropping it onto the canvas.
    static func defaultIcon(at origin: CGPoint = CGPoint(x: 64, y: 120),
                            size: CGSize = CGSize(width: 80, height: 80)) -> CanvasNode {
        CanvasNode(
            type: .icon,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: "#FFE3EC",
                cornerRadius: 16,
                borderWidth: 1.5,
                borderColorHex: "#1A140E",
                iconStyleFamily: .pastelDoodle,
                tintColorHex: "#B22A4A"
            ),
            content: NodeContent(iconName: "heart.fill")
        )
    }

    /// Default styled divider node — full-page-width horizontal strip
    /// with a sparkle-chain pattern. Height is intentionally tall (28pt)
    /// so chain glyphs have room to render legibly.
    static func defaultDivider(at origin: CGPoint = CGPoint(x: 24, y: 200),
                               size: CGSize = CGSize(width: 320, height: 28)) -> CanvasNode {
        CanvasNode(
            type: .divider,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: nil,
                borderColorHex: "#B22A4A",
                dividerStyleFamily: .sparkleChain,
                dividerThickness: 2
            )
        )
    }

    /// Default styled link node. Card variant (not pill) so the
    /// inspector's Radius slider works on the freshly-added node —
    /// `.pill` always renders as a capsule (radius = height/2) and
    /// silently ignores `style.cornerRadius`. With cornerRadius 24
    /// at the default 48pt height, the visual is identical to the
    /// old pill default; users who want a true grow-with-height
    /// capsule can switch the Variant card in the Style tab back to
    /// Pill.
    static func defaultLink(at origin: CGPoint = CGPoint(x: 32, y: 240),
                            size: CGSize = CGSize(width: 220, height: 48)) -> CanvasNode {
        CanvasNode(
            type: .link,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: "#FBF6E9",
                cornerRadius: 24,
                borderWidth: 1.5,
                borderColorHex: "#1A140E",
                fontFamily: .system,
                fontWeight: .semibold,
                fontSize: 16,
                textColorHex: "#1A140E",
                textAlignment: .center,
                linkStyleVariant: .card
            ),
            content: NodeContent(text: "my link", url: "")
        )
    }

    /// Default styled gallery node. Pre-populated with an empty
    /// `imagePaths` array; the create flow writes paths in immediately
    /// after the user picks photos.
    static func defaultGallery(imagePaths: [String],
                               at origin: CGPoint = CGPoint(x: 24, y: 280),
                               size: CGSize = CGSize(width: 320, height: 240)) -> CanvasNode {
        CanvasNode(
            type: .gallery,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: nil,
                cornerRadius: 12,
                borderWidth: 0,
                borderColorHex: nil,
                galleryLayout: .grid,
                galleryGap: 6
            ),
            content: NodeContent(imagePaths: imagePaths)
        )
    }

    /// Default carousel container. Children added under this node render
    /// as x-axis scroll items rather than full-width pages.
    static func defaultCarousel(at origin: CGPoint = CGPoint(x: 24, y: 320),
                                size: CGSize = CGSize(width: 326, height: 128)) -> CanvasNode {
        CanvasNode(
            type: .carousel,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: "#FBF6E9",
                cornerRadius: 18,
                borderWidth: 1,
                borderColorHex: "#1A140E"
            )
        )
    }

    /// Default styled note card — title row with corner expand glyph,
    /// timestamp row with leading clock symbol, and a body block that
    /// truncates with `…` in the editor. Sample text matches the design
    /// reference so the very first frame conveys what a note *is*.
    static func defaultNote(at origin: CGPoint = CGPoint(x: 24, y: 360),
                            size: CGSize = CGSize(width: 320, height: 180)) -> CanvasNode {
        CanvasNode(
            type: .note,
            frame: NodeFrame(x: Double(origin.x), y: Double(origin.y),
                             width: Double(size.width), height: Double(size.height)),
            style: NodeStyle(
                backgroundColorHex: "#FFFFFF",
                cornerRadius: 18,
                borderWidth: 1,
                borderColorHex: "#1A140E",
                fontFamily: .system,
                fontWeight: .regular,
                fontSize: 15,
                textColorHex: "#1A140E",
                padding: 16
            ),
            content: NodeContent(
                text: "Writing this song is seriously driving me crazy. Some days, nothing feels right – the lyrics won't come, the melody fades, and I just keep starting over and over.",
                noteTitle: "Notes (12)",
                noteTimestamp: "10 min. ago"
            )
        )
    }
}
