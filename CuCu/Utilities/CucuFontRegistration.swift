import SwiftUI
import CoreText

/// Registers the bundled Lexend TTFs at app launch via CTFontManager.
///
/// The font files live under `CuCu/Fonts/` and are picked up automatically
/// because the Xcode project uses a file-system-synchronized root group —
/// no Info.plist `UIAppFonts` entry is required because we register at
/// runtime in `.process` scope, which makes the faces available to every
/// `Font.custom("Lexend-…")` call from that point onward.
enum CucuFontRegistration {
    /// Filenames (without `.ttf`) of every TTF that lives under
    /// `CuCu/Fonts/` and should be registered at app launch. Two
    /// groups: the design-system Lexend faces (4 weights, used by
    /// the editor chrome) and the cute / artsy display faces (one
    /// weight each, exposed to the user via `NodeFontFamily`).
    private static let faces = [
        // Design-system body / display
        "Lexend-Regular",
        "Lexend-Medium",
        "Lexend-SemiBold",
        "Lexend-Bold",

        // Editorial display — italic-leaning serif that carries the
        // "scrapbook editorial" tone of the inspector and theme sheet.
        // Static instances at the 9pt optical size; weight / italic
        // selected by name through `Font.cucuEditorial`.
        "Fraunces-Regular",
        "Fraunces-Bold",
        "Fraunces-Italic",
        "Fraunces-BoldItalic",

        // Cute / artsy display faces — see `NodeFontFamily`
        "Caprasimo-Regular",
        "YesevaOne-Regular",
        "AbrilFatface-Regular",
        "Fredoka-Regular",
        "Modak-Regular",
        "Bungee-Regular",
        "Caveat-Regular",
        "Pacifico-Regular",
        "Lobster-Regular",
        "PermanentMarker-Regular",
        "ShadowsIntoLight-Regular",
        "PatrickHand-Regular",
        "PressStart2P-Regular",
    ]

    /// Idempotent. Safe to call repeatedly — `CTFontManager` returns false on
    /// re-register attempts but the font remains usable, so we ignore that
    /// specific failure.
    static func registerBundledFonts() {
        for name in faces {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                #if DEBUG
                print("[CucuFonts] missing bundled font: \(name).ttf")
                #endif
                continue
            }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !ok {
                #if DEBUG
                let cfErr = error?.takeUnretainedValue()
                let domain = (cfErr.flatMap { CFErrorGetDomain($0) }) as String? ?? "?"
                let code = cfErr.map { CFErrorGetCode($0) } ?? -1
                // Code 105 = "already registered" — harmless, expected on hot reload.
                if code != 105 {
                    print("[CucuFonts] register failed for \(name) [\(domain) \(code)]")
                }
                #endif
                error?.release()
            }
        }
    }
}
