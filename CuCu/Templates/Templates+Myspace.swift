import Foundation

// Template 5 — Myspace (y2k)
//
// 2006-coded chaotic energy. Bevelled cyan/purple, glitter, comic/serif
// mash, "About Me" panels, thin black borders, blinkie strip, "Top
// Friends" gallery instead of a clean grid. Source: TPL_MYSPACE.

extension TemplateBuilder {
    static func myspace() -> ProfileDocument {
        let blinkie       = UUID()
        let blinkieTxt    = UUID()
        let aboutFrame    = UUID()
        let aboutHeader   = UUID()
        let aboutLabel    = UUID()
        let avatar        = UUID()
        let bio           = UUID()
        let header        = UUID()
        let tag           = UUID()
        let div1          = UUID()
        let friendsFrame  = UUID()
        let friendsBar    = UUID()
        let friendsLabel  = UUID()
        let gallery       = UUID()
        let link1         = UUID()
        let link2         = UUID()
        let link3         = UUID()
        let counter       = UUID()
        let counterSub    = UUID()

        return assemble(
            bgColor: "#1B1B66",
            bgPatternKey: "sparkles",
            orderedNodes: [
                containerNode(blinkie, x: 0, y: 24, w: 320, h: 28,
                              bg: "#FF66CC", radius: 0, borderW: 2, borderC: "#000000"),
                textNode(blinkieTxt, x: 0, y: 30, w: 320, h: 20,
                         text: "✦ ✦ ✦  WELCOME 2 MY PAGE  ✦ ✦ ✦",
                         font: .caprasimo, weight: .regular, size: 13,
                         color: "#FFFFFF", align: .center),

                containerNode(aboutFrame, x: 14, y: 66, w: 292, h: 142,
                              bg: "#FFFFFF", radius: 6, borderW: 2, borderC: "#000000"),
                containerNode(aboutHeader, x: 14, y: 66, w: 292, h: 22,
                              bg: "#39E6F0", radius: 0, borderW: 2, borderC: "#000000"),
                textNode(aboutLabel, x: 22, y: 68, w: 270, h: 18,
                         text: "★ luna_xo  ·  online",
                         font: .caprasimo, weight: .regular, size: 12,
                         color: "#000000", align: .leading),

                imageNode(avatar, x: 24, y: 96, w: 88, h: 88,
                          tone: "rose", radius: 4,
                          clip: .rectangle, borderW: 2, borderC: "#000000"),

                textNode(bio, x: 122, y: 96, w: 176, h: 96,
                         text: "\"about me ♡\"\nage: 22\nmood: blasting\ny2k mixtapes\non repeat ✿",
                         font: .fraunces, weight: .medium, size: 13,
                         color: "#1B1B66", align: .leading),

                textNode(header, x: 14, y: 218, w: 292, h: 60,
                         text: "★ luna ★",
                         font: .lobster, weight: .regular, size: 48,
                         color: "#FF66CC", align: .center),

                textNode(tag, x: 14, y: 270, w: 292, h: 20,
                         text: "↳ certified glitter enthusiast ⋆˙⟡",
                         font: .patrickHand, weight: .regular, size: 14,
                         color: "#FFD93D", align: .center),

                dividerNode(div1, x: 14, y: 296, w: 292, h: 22,
                            style: .sparkleChain, color: "#39E6F0", thickness: 1.6),

                containerNode(friendsFrame, x: 14, y: 326, w: 292, h: 132,
                              bg: "#FFFFFF", radius: 6, borderW: 2, borderC: "#000000"),
                containerNode(friendsBar, x: 14, y: 326, w: 292, h: 22,
                              bg: "#FFD93D", radius: 0, borderW: 2, borderC: "#000000"),
                textNode(friendsLabel, x: 22, y: 328, w: 270, h: 18,
                         text: "◆ TOP 4 FRIENDS",
                         font: .caprasimo, weight: .regular, size: 12,
                         color: "#000000", align: .leading),

                galleryNode(gallery, x: 22, y: 354, w: 276, h: 96,
                            tones: ["rose", "sky", "butter", "sage"],
                            gap: 6, radius: 4, borderW: 2, borderC: "#000000"),

                linkNode(link1, x: 14, y: 472, w: 292, h: 44,
                         text: "☆ leave me a comment ☆",
                         url: "luna.cucu/comments",
                         bg: "#FF66CC", textColor: "#FFFFFF",
                         borderW: 2, borderC: "#000000", radius: 6),
                linkNode(link2, x: 14, y: 522, w: 142, h: 40,
                         text: "+ add me", url: "#",
                         bg: "#39E6F0", textColor: "#000000",
                         borderW: 2, borderC: "#000000", radius: 6),
                linkNode(link3, x: 164, y: 522, w: 142, h: 40,
                         text: "send msg", url: "#",
                         bg: "#FFD93D", textColor: "#000000",
                         borderW: 2, borderC: "#000000", radius: 6),

                textNode(counter, x: 14, y: 580, w: 292, h: 16,
                         text: "✦ visitors: 0 0 4 2 7 8 1 ✦",
                         font: .fraunces, weight: .bold, size: 11,
                         color: "#39E6F0", align: .center),
                textNode(counterSub, x: 14, y: 600, w: 292, h: 16,
                         text: "thx 4 stopping by!! ♡♡♡",
                         font: .patrickHand, weight: .regular, size: 13,
                         color: "#FFFFFF", align: .center),
            ]
        )
    }
}
