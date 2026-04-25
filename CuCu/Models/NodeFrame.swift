import CoreGraphics
import Foundation

/// Position and size of a node in its parent's coordinate space. Root frames
/// are in page coordinates. Doubles (not CGFloat) so the Codable JSON shape
/// is platform-independent and round-trips cleanly between iOS and any future
/// web/cross-platform renderer.
struct NodeFrame: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let zero = NodeFrame(x: 0, y: 0, width: 0, height: 0)

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
}
