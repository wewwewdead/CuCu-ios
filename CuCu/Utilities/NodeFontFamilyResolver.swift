import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Bridges `NodeFontFamily` (a pure-data enum that lives in the model
/// layer) to the rendering primitives both UIKit (`UIFont`) and
/// SwiftUI (`Font`) need. Splitting this off keeps `NodeStyle.swift`
/// dependency-free — Models import only Foundation, the resolver
/// here owns the platform-font knowledge.
extension NodeFontFamily {

    /// Friendly name for UI labels (font picker, layers panel, etc.).
    /// Distinct from `rawValue` so the JSON form stays a stable
    /// string while users see "Press Start 2P" rather than
    /// `pressStart2P`.
    var displayName: String {
        switch self {
        case .system:           return "System"
        case .serif:            return "Serif"
        case .rounded:          return "Rounded"
        case .monospaced:       return "Mono"
        case .caprasimo:        return "Caprasimo"
        case .yesevaOne:        return "Yeseva One"
        case .abrilFatface:     return "Abril Fatface"
        case .fraunces:         return "Fraunces"
        case .fredoka:          return "Fredoka"
        case .modak:            return "Modak"
        case .bungee:           return "Bungee"
        case .caveat:           return "Caveat"
        case .pacifico:         return "Pacifico"
        case .lobster:          return "Lobster"
        case .permanentMarker:  return "Permanent Marker"
        case .shadowsIntoLight: return "Shadows Into Light"
        case .patrickHand:      return "Patrick Hand"
        case .pressStart2P:     return "Press Start 2P"
        }
    }

    /// Coarse category — drives the section headers in the font picker
    /// so 17 faces stay browseable. Order matters: the picker walks
    /// `Category.allCases` and groups families by `category`.
    var category: Category {
        switch self {
        case .system, .serif, .rounded, .monospaced:
            return .system
        case .caprasimo, .yesevaOne, .abrilFatface, .fraunces:
            return .display
        case .fredoka, .modak, .bungee:
            return .bubbly
        case .caveat, .pacifico, .lobster, .permanentMarker,
             .shadowsIntoLight, .patrickHand:
            return .handwritten
        case .pressStart2P:
            return .retro
        }
    }

    /// Display category for the font picker. Ordered top-to-bottom.
    enum Category: String, CaseIterable {
        case system, display, bubbly, handwritten, retro

        var label: String {
            switch self {
            case .system:       return "System"
            case .display:      return "Display"
            case .bubbly:       return "Bubbly"
            case .handwritten:  return "Handwritten"
            case .retro:        return "Retro"
            }
        }
    }

    /// PostScript name for bundled custom fonts; nil for system
    /// families. The values match the registered face names emitted
    /// by `CucuFontRegistration.registerBundledFonts()`.
    var customPostScriptName: String? {
        switch self {
        case .system, .serif, .rounded, .monospaced:
            return nil
        case .caprasimo:        return "Caprasimo-Regular"
        case .yesevaOne:        return "YesevaOne-Regular"
        case .abrilFatface:     return "AbrilFatface-Regular"
        // Per-node Fraunces falls back to the regular cut. Bold /
        // italic variants are reachable via `Font.cucuEditorial` for
        // the editor chrome — see `CucuDesignSystem.swift`.
        case .fraunces:         return "Fraunces-Regular"
        case .fredoka:          return "Fredoka"            // variable face
        case .modak:            return "Modak-Regular"
        case .bungee:           return "Bungee-Regular"
        case .caveat:           return "Caveat-Regular"
        case .pacifico:         return "Pacifico-Regular"
        case .lobster:          return "Lobster-Regular"
        case .permanentMarker:  return "PermanentMarker-Regular"
        case .shadowsIntoLight: return "ShadowsIntoLight-Regular"
        case .patrickHand:      return "PatrickHand-Regular"
        case .pressStart2P:     return "PressStart2P-Regular"
        }
    }

    /// `Font.Design` for system families. Custom families return
    /// `.default` (unused — callers branch on `customPostScriptName`
    /// first).
    var design: Font.Design {
        switch self {
        case .serif:      return .serif
        case .rounded:    return .rounded
        case .monospaced: return .monospaced
        default:          return .default
        }
    }

    /// SwiftUI `Font` for this family at the given size + weight. For
    /// custom fonts the requested weight is ignored (most cute faces
    /// ship a single weight); the picker / inspector should reflect
    /// that by hiding the weight card when these are selected.
    func swiftUIFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = customPostScriptName {
            return Font.custom(name, size: size)
        }
        return Font.system(size: size, weight: weight, design: design)
    }

    #if canImport(UIKit)
    /// `UIFont` for the canvas's `TextNodeView` (which uses
    /// `UITextView`). Falls back to the system font of the requested
    /// size + weight if the bundled face fails to resolve at
    /// runtime — empty glyphs are worse than the wrong typeface.
    func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        if let name = customPostScriptName,
           let font = UIFont(name: name, size: size) {
            return font
        }
        let baseFont = UIFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .system:
            return baseFont
        case .serif:
            if let descriptor = baseFont.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return baseFont
        case .rounded:
            if let descriptor = baseFont.fontDescriptor.withDesign(.rounded) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return baseFont
        case .monospaced:
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        default:
            return baseFont
        }
    }
    #endif
}
