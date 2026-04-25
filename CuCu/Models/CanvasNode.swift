import CoreGraphics
import Foundation

/// Node type discriminator. String-backed for forward-compatible JSON.
enum NodeType: String, Codable, Hashable {
    case container
    case text
    case image
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
    var style: NodeStyle
    var content: NodeContent

    init(id: UUID = UUID(),
         type: NodeType,
         name: String? = nil,
         childrenIDs: [UUID] = [],
         frame: NodeFrame,
         zIndex: Int = 0,
         opacity: Double = 1.0,
         style: NodeStyle = NodeStyle(),
         content: NodeContent = NodeContent()) {
        self.id = id
        self.type = type
        self.name = name
        self.childrenIDs = childrenIDs
        self.frame = frame
        self.zIndex = zIndex
        self.opacity = opacity
        self.style = style
        self.content = content
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
}
