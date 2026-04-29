import Foundation

// Template 6 — Cool Kid (streetwear / skate)
//
// Dark olive + safety-orange + bone white. Mono caps, big stencil-feel
// header, photo grid bottom, "lvl 99" badge, asymmetric hero with
// ID-card framing. Source: TPL_COOLKID.

extension TemplateBuilder {
    static func coolKid() -> ProfileDocument {
        let strip        = UUID()
        let stripR       = UUID()
        let idFrame      = UUID()
        let photo        = UUID()
        let photoLabel   = UUID()
        let headerL1     = UUID()
        let headerL2     = UUID()
        let lvlBadge     = UUID()
        let locTag       = UUID()
        let div1         = UUID()
        let bio          = UUID()
        let galleryLabel = UUID()
        let gallery      = UUID()
        let link1        = UUID()
        let link2        = UUID()
        let link3        = UUID()
        let foot         = UUID()

        return assemble(
            bgColor: "#1F2018",
            bgPatternKey: nil,
            orderedNodes: [
                textNode(strip, x: 18, y: 28, w: 180, h: 14,
                         text: "◢ SUBJECT // ID-09",
                         font: .fraunces, weight: .bold, size: 10,
                         color: "#FF5A1F", align: .leading),
                textNode(stripR, x: 122, y: 28, w: 180, h: 14,
                         text: "ISSUE 026",
                         font: .fraunces, weight: .bold, size: 10,
                         color: "#E8E2D0", align: .trailing),

                containerNode(idFrame, x: 18, y: 52, w: 200, h: 230,
                              bg: "#2B2C22", radius: 4, borderW: 2, borderC: "#FF5A1F"),
                imageNode(photo, x: 26, y: 60, w: 184, h: 184,
                          tone: "sage", radius: 2, clip: .rectangle),
                textNode(photoLabel, x: 26, y: 250, w: 184, h: 22,
                         text: "NO. 09 / SUBJECT FILE",
                         font: .fraunces, weight: .bold, size: 9.5,
                         color: "#FF5A1F", align: .leading),

                textNode(headerL1, x: 224, y: 60, w: 80, h: 50,
                         text: "KAI",
                         font: .yesevaOne, weight: .regular, size: 44,
                         color: "#E8E2D0", align: .leading),
                textNode(headerL2, x: 224, y: 110, w: 80, h: 50,
                         text: "NOR",
                         font: .yesevaOne, weight: .regular, size: 44,
                         color: "#FF5A1F", align: .leading),

                textNode(lvlBadge, x: 224, y: 174, w: 78, h: 28,
                         text: "LVL · 99",
                         font: .caprasimo, weight: .regular, size: 13,
                         color: "#1F2018", align: .center,
                         bg: "#FF5A1F", radius: 0, borderW: 2, borderC: "#E8E2D0"),
                textNode(locTag, x: 224, y: 210, w: 80, h: 18,
                         text: "↳ TOKYO",
                         font: .fraunces, weight: .bold, size: 11,
                         color: "#9DA180", align: .leading),

                dividerNode(div1, x: 18, y: 296, w: 284, h: 8,
                            style: .dashed, color: "#FF5A1F", thickness: 2),

                textNode(bio, x: 18, y: 312, w: 284, h: 56,
                         text: "designer · skater · always\nshooting on 35mm — never sleeps,\ndrinks too much matcha.",
                         font: .fraunces, weight: .medium, size: 13,
                         color: "#E8E2D0", align: .leading),

                textNode(galleryLabel, x: 18, y: 376, w: 284, h: 14,
                         text: "— FIELD KIT",
                         font: .fraunces, weight: .bold, size: 10,
                         color: "#FF5A1F", align: .leading),
                galleryNode(gallery, x: 18, y: 394, w: 284, h: 110,
                            tones: ["sage", "butter", "sky", "rose"],
                            gap: 4, radius: 0, borderW: 1.5, borderC: "#E8E2D0"),

                linkNode(link1, x: 18, y: 518, w: 284, h: 46,
                         text: "◆ portfolio · 26",
                         url: "kainor.cucu/work",
                         bg: "#FF5A1F", textColor: "#1F2018",
                         borderW: 0, borderC: "#FF5A1F", radius: 0),
                linkNode(link2, x: 18, y: 568, w: 138, h: 42,
                         text: "shop", url: "#",
                         bg: nil, textColor: "#E8E2D0",
                         borderW: 1.5, borderC: "#E8E2D0", radius: 0),
                linkNode(link3, x: 164, y: 568, w: 138, h: 42,
                         text: "IG ↗", url: "#",
                         bg: nil, textColor: "#E8E2D0",
                         borderW: 1.5, borderC: "#E8E2D0", radius: 0),

                textNode(foot, x: 18, y: 624, w: 284, h: 12,
                         text: "▮ ▮▮▮ ▮ ▮▮ ▮▮ ▮ ▮▮▮ ▮▮ ▮ ▮▮ ▮▮▮ · CAT.09",
                         font: .fraunces, weight: .bold, size: 9,
                         color: "#9DA180", align: .leading),
            ]
        )
    }
}
