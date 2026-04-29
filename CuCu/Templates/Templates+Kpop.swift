import Foundation

// Template 3 — Kpop (photocard deluxe)
//
// 2026-trendy K-pop visual coding: glossy butter-cream paper base,
// photocard collage layout, hot-pink + cherry-red bubble graphics with
// thick black outlines, "PHOTOCARD / OFFICIAL" stamp blocks, ticket-stub
// link rows. Source: TPL_KPOP.

extension TemplateBuilder {
    static func kpop() -> ProfileDocument {
        let ticketBar    = UUID()
        let ticketTxt    = UUID()
        let photocard    = UUID()
        let photo        = UUID()
        let cardLabel    = UUID()
        let stamp        = UUID()
        let stampTxt     = UUID()
        let dateChip     = UUID()
        let header       = UUID()
        let chip1        = UUID()
        let chip2        = UUID()
        let chip3        = UUID()
        let tag          = UUID()
        let div1         = UUID()
        let link1        = UUID()
        let link2        = UUID()
        let link3        = UUID()
        let serial       = UUID()
        let serialR      = UUID()
        let barcode      = UUID()

        return assemble(
            bgColor: "#FFE7EE",
            bgPatternKey: "sparkles",
            orderedNodes: [
                containerNode(ticketBar, x: 0, y: 24, w: 320, h: 26,
                              bg: "#1A0E1F", radius: 0, borderW: 0, borderC: "#1A0E1F"),
                textNode(ticketTxt, x: 12, y: 26, w: 296, h: 22,
                         text: "✦ TOUR '26 · LE FANTÔME · SEOUL → TOKYO → LA · ✦",
                         font: .fraunces, weight: .bold, size: 9.5,
                         color: "#FFD93D", align: .center),

                containerNode(photocard, x: 32, y: 70, w: 200, h: 260,
                              bg: "#FFFFFF", radius: 6, borderW: 3, borderC: "#1A0E1F"),
                imageNode(photo, x: 40, y: 78, w: 184, h: 220,
                          tone: "rose", radius: 2, clip: .rectangle),
                textNode(cardLabel, x: 40, y: 304, w: 184, h: 22,
                         text: "PHOTOCARD · 01/12",
                         font: .fraunces, weight: .bold, size: 9.5,
                         color: "#1A0E1F", align: .center),

                iconNode(stamp, x: 230, y: 80, w: 70, h: 70,
                         glyph: "sparkle",
                         plate: "#FF3D7A", tint: "#FFFFFF",
                         radius: 35, borderW: 3, borderC: "#1A0E1F"),
                textNode(stampTxt, x: 220, y: 152, w: 90, h: 20,
                         text: "★ OFFICIAL ★",
                         font: .caprasimo, weight: .regular, size: 11,
                         color: "#1A0E1F", align: .center,
                         bg: "#FFD93D", radius: 10, borderW: 2, borderC: "#1A0E1F"),

                textNode(dateChip, x: 240, y: 250, w: 64, h: 30,
                         text: "04 · 26",
                         font: .caprasimo, weight: .regular, size: 16,
                         color: "#FFFFFF", align: .center,
                         bg: "#FF3D7A", radius: 8, borderW: 2, borderC: "#1A0E1F"),

                // Single editable wordmark. The HTML prototype used two
                // stacked text nodes with a 2px offset to fake an
                // outlined-bubble-letter look; that breaks editing in
                // the real canvas (each node is independently editable
                // so changing the name only updates the top node and
                // the "shadow" still reads the old value). Dropped the
                // shadow until `NodeStyle` grows a real text-stroke /
                // text-shadow field.
                textNode(header, x: 14, y: 346, w: 296, h: 70,
                         text: "jiwoo♡",
                         font: .lobster, weight: .regular, size: 60,
                         color: "#FF3D7A", align: .center),

                linkNode(chip1, x: 22, y: 414, w: 92, h: 28,
                         text: "♡ MAIN VOCAL", url: "#",
                         bg: "#FFFFFF", textColor: "#1A0E1F",
                         borderW: 2, borderC: "#1A0E1F", radius: 14,
                         font: .fraunces, weight: .bold, size: 11),
                linkNode(chip2, x: 120, y: 414, w: 80, h: 28,
                         text: "DANCE", url: "#",
                         bg: "#FFD93D", textColor: "#1A0E1F",
                         borderW: 2, borderC: "#1A0E1F", radius: 14,
                         font: .fraunces, weight: .bold, size: 11),
                linkNode(chip3, x: 206, y: 414, w: 92, h: 28,
                         text: "BIAS · 99", url: "#",
                         bg: "#FF3D7A", textColor: "#FFFFFF",
                         borderW: 2, borderC: "#1A0E1F", radius: 14,
                         font: .fraunces, weight: .bold, size: 11),

                textNode(tag, x: 24, y: 450, w: 272, h: 22,
                         text: "\"five stars in a row, one comeback to go ✦\"",
                         font: .fraunces, weight: .medium, size: 13.5,
                         color: "#1A0E1F", align: .center),

                dividerNode(div1, x: 24, y: 478, w: 272, h: 18,
                            style: .sparkleChain, color: "#FF3D7A", thickness: 1.6),

                linkNode(link1, x: 16, y: 506, w: 288, h: 48,
                         text: "▶  fancam · ep.07",
                         url: "jiwoo.cucu/cam",
                         bg: "#1A0E1F", textColor: "#FFD93D",
                         borderW: 2, borderC: "#1A0E1F", radius: 10),
                linkNode(link2, x: 16, y: 560, w: 138, h: 44,
                         text: "lightstick",
                         url: "jiwoo.cucu/stick",
                         bg: "#FF3D7A", textColor: "#FFFFFF",
                         borderW: 2, borderC: "#1A0E1F", radius: 10),
                linkNode(link3, x: 166, y: 560, w: 138, h: 44,
                         text: "fan club ➜",
                         url: "jiwoo.cucu/dc",
                         bg: "#FFFFFF", textColor: "#1A0E1F",
                         borderW: 2, borderC: "#1A0E1F", radius: 10),

                textNode(serial, x: 16, y: 614, w: 200, h: 12,
                         text: "CAT. NO. KPOP-026 · DELUXE",
                         font: .fraunces, weight: .bold, size: 8.5,
                         color: "#1A0E1F", align: .leading),
                textNode(serialR, x: 104, y: 614, w: 200, h: 12,
                         text: "★ unofficial fan profile",
                         font: .fraunces, weight: .medium, size: 8.5,
                         color: "#1A0E1F", align: .trailing),
                textNode(barcode, x: 16, y: 630, w: 288, h: 14,
                         text: "▮▮ ▮ ▮▮▮ ▮ ▮▮ ▮▮▮▮ ▮ ▮▮ ▮ ▮▮▮ ▮ ▮▮ ▮▮ ▮ ▮▮▮",
                         font: .fraunces, weight: .bold, size: 10,
                         color: "#1A0E1F", align: .leading),
            ]
        )
    }
}
