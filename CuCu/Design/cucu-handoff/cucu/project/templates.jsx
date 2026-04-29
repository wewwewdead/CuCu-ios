// templates.jsx — 5 prebuilt profile templates
// Each template is a self-contained `doc` (same shape as makeDoc() in editor.jsx)
// rendered through the existing Canvas → NodeView pipeline. Compositions are
// intentionally pushed: overlapping nodes, asymmetric layouts, sticker collage.
// The iPhone canvas is 320×660 (the DeviceFrame's inner W×H).

const CANVAS_W = 320;
const CANVAS_H = 660;

// Helper to build a node with sane defaults so each template stays terse.
const N = (id, type, props) => ({ id, type, opacity: 1, ...props });

// ── 1. KAWAII ──────────────────────────────────────────────────
// Hyper-cute, pastel, sticker-collage. Pink + butter + mint, hearts everywhere,
// rotated stickers, hand-script bio in Caveat, Lobster header.
const TPL_KAWAII = {
  id: 'kawaii',
  name: 'Kawaii',
  vibe: 'kawaii · pastel · sticker collage',
  swatch: ['#FFD9E5', '#FFF1B8', '#D8E9C9', '#B8324B'],
  bgColor: '#FFE5EE',
  bgImage: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><path d='M16 24 C 8 18, 6 12, 10 9 C 13 7, 16 9, 16 12 C 16 9, 19 7, 22 9 C 26 12, 24 18, 16 24 Z' fill='%23FF6FA0' fill-opacity='.18'/></svg>")`,
  bgImageSize: 'tile',
  bgImageOpacity: 1,
  nodes: {
    // floating sticker container behind the avatar — soft yellow blob
    blob1: N('blob1', 'container', { x: 30, y: 92, w: 130, h: 130, bg: '#FFF1B8', radius: 65, borderW: 2, borderC: '#3A1A26' }),
    // mint container behind that, peeking out
    blob2: N('blob2', 'container', { x: 175, y: 110, w: 110, h: 110, bg: '#D8E9C9', radius: 55, borderW: 2, borderC: '#3A1A26' }),
    // header — Lobster, tilted vibe via no native rotation, but giant
    header: N('header', 'text', {
      x: 24, y: 30, w: 272, h: 56,
      text: 'sugar bun ♡', font: 'lobster', weight: 400, italic: false, size: 42,
      color: '#B8324B', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // little tagline under header — Patrick Hand
    sub: N('sub', 'text', {
      x: 24, y: 78, w: 272, h: 18,
      text: 'ﾟ✿ﾟ ・♡ welcome to my corner ♡・ ﾟ✿ﾟ', font: 'patrick', weight: 400, italic: false, size: 13,
      color: '#3A1A26', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // avatar, off-center left, big border
    avatar: N('avatar', 'image', {
      x: 50, y: 110, w: 96, h: 96, radius: 48, borderW: 3, borderC: '#3A1A26', clip: 'circle', tone: 'rose',
    }),
    // tiny heart sticker on top of avatar (icon)
    sticker1: N('sticker1', 'icon', {
      x: 130, y: 100, w: 36, h: 36, glyph: 'heart',
      plate: '#FFFFFF', tint: '#B8324B', radius: 18, borderW: 2, borderC: '#3A1A26',
    }),
    // sparkle sticker on right blob
    sticker2: N('sticker2', 'icon', {
      x: 260, y: 88, w: 32, h: 32, glyph: 'sparkle',
      plate: '#FFFFFF', tint: '#D2557A', radius: 16, borderW: 2, borderC: '#3A1A26',
    }),
    // bio inside the right blob — Caveat handwritten
    bio: N('bio', 'text', {
      x: 175, y: 130, w: 110, h: 70,
      text: 'collector of\nsmall joys &\nplush bunnies', font: 'caveat', weight: 700, italic: false, size: 16,
      color: '#3A1A26', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // heart-chain divider
    div1: N('div1', 'divider', { x: 30, y: 240, w: 260, h: 22, style: 'heartChain', color: '#B8324B', thickness: 1.6 }),
    // icon row — heart, star, flower
    icon1: N('icon1', 'icon', { x: 50, y: 274, w: 56, h: 56, glyph: 'heart',
      plate: '#FFD9E5', tint: '#B8324B', radius: 28, borderW: 2, borderC: '#3A1A26' }),
    icon2: N('icon2', 'icon', { x: 132, y: 274, w: 56, h: 56, glyph: 'star',
      plate: '#FFF1B8', tint: '#D2557A', radius: 28, borderW: 2, borderC: '#3A1A26' }),
    icon3: N('icon3', 'icon', { x: 214, y: 274, w: 56, h: 56, glyph: 'flower',
      plate: '#D8E9C9', tint: '#3F7A52', radius: 28, borderW: 2, borderC: '#3A1A26' }),
    // 2x2 gallery — the soft polaroid grid
    gallery: N('gallery', 'gallery', {
      x: 36, y: 350, w: 248, h: 110, tones: ['rose','butter','sage','peach'],
      layout: 'grid', gap: 6, fit: 'fill', radius: 14, borderW: 2, borderC: '#3A1A26',
    }),
    // candy link pills
    link1: N('link1', 'link', { x: 36, y: 478, w: 248, h: 44,
      text: 'my plushie shop ♡', url: 'sugarbun.cucu/shop', variant: 'pill',
      bg: '#FFFFFF', textColor: '#B8324B', borderW: 2, borderC: '#3A1A26', radius: 22 }),
    link2: N('link2', 'link', { x: 36, y: 532, w: 248, h: 44,
      text: 'sticker swap', url: 'sugarbun.cucu/swap', variant: 'pill',
      bg: '#B8324B', textColor: '#FFFFFF', borderW: 2, borderC: '#3A1A26', radius: 22 }),
    // bottom signature — tiny patrick
    sig: N('sig', 'text', {
      x: 30, y: 590, w: 260, h: 18,
      text: '⊹  thanks for visiting!  ⊹', font: 'patrick', weight: 400, italic: false, size: 12,
      color: '#3A1A26', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
  },
  order: ['blob1','blob2','header','sub','avatar','sticker1','sticker2','bio','div1','icon1','icon2','icon3','gallery','link1','link2','sig'],
};

// ── 2. MINIMALIST ──────────────────────────────────────────────
// Editorial, restrained. Off-white, near-black ink, generous whitespace, single
// hairline rule. Yeseva display + Hanken body; no decoration except a thin
// running mono caption. The composition: heavy left-aligned name, tiny avatar
// floating top-right, link pills as outlined ghost buttons.
const TPL_MINIMAL = {
  id: 'minimal',
  name: 'Minimalist',
  vibe: 'minimal · editorial · restrained',
  swatch: ['#FBF8F2', '#1A1A1A', '#7A7A7A', '#E8E4D8'],
  bgColor: '#FBF8F2',
  bgImage: null,
  nodes: {
    // running ID strip top-left — mono
    runner: N('runner', 'text', {
      x: 24, y: 32, w: 200, h: 14,
      text: '— PROFILE NO. 042 / 26', font: 'fraunces', weight: 400, italic: false, size: 10,
      color: '#9A9A9A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    runnerR: N('runnerR', 'text', {
      x: 96, y: 32, w: 200, h: 14,
      text: 'EST. 2026', font: 'fraunces', weight: 500, italic: false, size: 10,
      color: '#9A9A9A', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // tiny avatar pinned top-right under the strip
    avatar: N('avatar', 'image', {
      x: 240, y: 62, w: 56, h: 56, radius: 28, borderW: 1, borderC: '#1A1A1A', clip: 'circle', tone: 'sage',
    }),
    // huge editorial name, left-aligned, two lines
    header: N('header', 'text', {
      x: 24, y: 92, w: 210, h: 130,
      text: 'theo\nclark.', font: 'yeseva', weight: 400, italic: false, size: 56,
      color: '#1A1A1A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // hairline rule
    div1: N('div1', 'divider', { x: 24, y: 240, w: 272, h: 2, style: 'solid', color: '#1A1A1A', thickness: 1 }),
    // role caption — small mono-ish
    role: N('role', 'text', {
      x: 24, y: 252, w: 272, h: 16,
      text: 'WRITER · EDITOR · QUIET TYPE', font: 'fraunces', weight: 600, italic: false, size: 11,
      color: '#1A1A1A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // bio, italic Fraunces, two columns of breathing room
    bio: N('bio', 'text', {
      x: 24, y: 282, w: 272, h: 90,
      text: 'I write slow essays on\nrooms, light, and the\nthings people leave\nbehind.',
      font: 'fraunces', weight: 400, italic: true, size: 18,
      color: '#3A3A3A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // contact label
    contactLabel: N('contactLabel', 'text', {
      x: 24, y: 388, w: 272, h: 14,
      text: 'INDEX', font: 'fraunces', weight: 600, italic: false, size: 10,
      color: '#9A9A9A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // ghost link 01
    link1: N('link1', 'link', { x: 24, y: 408, w: 272, h: 50,
      text: '01  Recent essays  →', url: 'theo.cucu/essays', variant: 'pill',
      bg: 'transparent', textColor: '#1A1A1A', borderW: 1, borderC: '#1A1A1A', radius: 0 }),
    link2: N('link2', 'link', { x: 24, y: 460, w: 272, h: 50,
      text: '02  Field notes  →', url: 'theo.cucu/notes', variant: 'pill',
      bg: 'transparent', textColor: '#1A1A1A', borderW: 1, borderC: '#1A1A1A', radius: 0 }),
    link3: N('link3', 'link', { x: 24, y: 512, w: 272, h: 50,
      text: '03  Correspondence  →', url: 'theo.cucu/mail', variant: 'pill',
      bg: 'transparent', textColor: '#1A1A1A', borderW: 1, borderC: '#1A1A1A', radius: 0 }),
    // bottom mono colophon
    colo: N('colo', 'text', {
      x: 24, y: 600, w: 272, h: 14,
      text: 'SET IN YESEVA · FRAUNCES', font: 'fraunces', weight: 500, italic: false, size: 9,
      color: '#9A9A9A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    coloR: N('coloR', 'text', {
      x: 24, y: 600, w: 272, h: 14,
      text: 'PG. 01', font: 'fraunces', weight: 500, italic: false, size: 9,
      color: '#9A9A9A', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
  },
  order: ['runner','runnerR','avatar','header','div1','role','bio','contactLabel','link1','link2','link3','colo','coloR'],
};

// ── 3. K-POP ──────────────────────────────────────────────────
// Bold, dark gradient, fan-account energy. Black background with hot pink/cyan
// pops, big sans-italic name, "stage" carousel, fancam links. Header uses
// Yeseva (high contrast serif), accents in Caprasimo for sticker labels.
// Trendy 2026 K-pop visual coding: glossy butter-cream paper base, photocard
// collage layout, hot-pink + cherry-red bubble graphics with white outlines,
// "PHOTOCARD / OFFICIAL" stamp blocks, ticket-stub link rows. Less generic
// "neon dark", more deluxe-album fan kit energy.
const TPL_KPOP = {
  id: 'kpop',
  name: 'Kpop',
  vibe: 'k-pop · photocard · deluxe edition',
  swatch: ['#FFE7EE', '#FF3D7A', '#1A0E1F', '#FFD93D'],
  bgColor: '#FFE7EE',
  bgImage: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><g fill='%23FF3D7A' fill-opacity='.18'><path d='M8 8 L9.2 5 L10.4 8 L13 9 L10.4 10 L9.2 13 L8 10 L5 9 Z'/><path d='M30 26 L31 24 L32 26 L34 27 L32 28 L31 30 L30 28 L28 27 Z'/></g></svg>")`,
  bgImageSize: 'tile',
  bgImageOpacity: 1,
  nodes: {
    // ticket-stub strip top
    ticketBar: N('ticketBar', 'container', {
      x: 0, y: 24, w: 320, h: 26, bg: '#1A0E1F', radius: 0, borderW: 0, borderC: '#1A0E1F',
    }),
    ticketTxt: N('ticketTxt', 'text', {
      x: 12, y: 26, w: 296, h: 22,
      text: '✦ TOUR \'26 · LE FANTÔME · SEOUL → TOKYO → LA · ✦',
      font: 'fraunces', weight: 700, italic: false, size: 9.5,
      color: '#FFD93D', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),

    // big squared photocard — main hero, slightly off-center, with thick frame
    photocard: N('photocard', 'container', {
      x: 32, y: 70, w: 200, h: 260, bg: '#FFFFFF', radius: 6, borderW: 3, borderC: '#1A0E1F',
    }),
    photo: N('photo', 'image', {
      x: 40, y: 78, w: 184, h: 220, radius: 2, borderW: 0, borderC: '#1A0E1F', clip: 'rect', tone: 'rose',
    }),
    cardLabel: N('cardLabel', 'text', {
      x: 40, y: 304, w: 184, h: 22,
      text: 'PHOTOCARD · 01/12', font: 'fraunces', weight: 700, italic: false, size: 9.5,
      color: '#1A0E1F', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),

    // floating "OFFICIAL" round stamp on top-right
    stamp: N('stamp', 'icon', {
      x: 230, y: 80, w: 70, h: 70, glyph: 'sparkle',
      plate: '#FF3D7A', tint: '#FFFFFF', radius: 35, borderW: 3, borderC: '#1A0E1F',
    }),
    stampTxt: N('stampTxt', 'text', {
      x: 220, y: 152, w: 90, h: 20,
      text: '★ OFFICIAL ★', font: 'caprasimo', weight: 400, italic: false, size: 11,
      color: '#1A0E1F', align: 'center', bg: '#FFD93D', radius: 10, borderW: 2, padding: 0, borderC: '#1A0E1F',
    }),

    // little date sticker bottom-right of photocard
    dateChip: N('dateChip', 'text', {
      x: 240, y: 250, w: 64, h: 30,
      text: '04 · 26', font: 'caprasimo', weight: 400, italic: false, size: 16,
      color: '#FFFFFF', align: 'center', bg: '#FF3D7A', radius: 8, borderW: 2, borderC: '#1A0E1F', padding: 0,
    }),

    // bubble-letter wordmark name — Lobster, hot pink with thick black "outline"
    // (we fake the outline by stacking two text nodes)
    headerShadow: N('headerShadow', 'text', {
      x: 14, y: 348, w: 296, h: 70,
      text: 'jiwoo♡', font: 'lobster', weight: 400, italic: false, size: 60,
      color: '#1A0E1F', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    header: N('header', 'text', {
      x: 16, y: 346, w: 296, h: 70,
      text: 'jiwoo♡', font: 'lobster', weight: 400, italic: false, size: 60,
      color: '#FF3D7A', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),

    // group / role tag chip row — three pill chips
    chip1: N('chip1', 'link', { x: 22, y: 414, w: 92, h: 28,
      text: '♡ MAIN VOCAL', url: '#', variant: 'pill',
      bg: '#FFFFFF', textColor: '#1A0E1F', borderW: 2, borderC: '#1A0E1F', radius: 14 }),
    chip2: N('chip2', 'link', { x: 120, y: 414, w: 80, h: 28,
      text: 'DANCE', url: '#', variant: 'pill',
      bg: '#FFD93D', textColor: '#1A0E1F', borderW: 2, borderC: '#1A0E1F', radius: 14 }),
    chip3: N('chip3', 'link', { x: 206, y: 414, w: 92, h: 28,
      text: 'BIAS · 99', url: '#', variant: 'pill',
      bg: '#FF3D7A', textColor: '#FFFFFF', borderW: 2, borderC: '#1A0E1F', radius: 14 }),

    // tagline
    tag: N('tag', 'text', {
      x: 24, y: 450, w: 272, h: 22,
      text: '"five stars in a row, one comeback to go ✦"',
      font: 'fraunces', weight: 500, italic: true, size: 13.5,
      color: '#1A0E1F', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),

    // sparkle divider in cherry red
    div1: N('div1', 'divider', { x: 24, y: 478, w: 272, h: 18, style: 'sparkleChain', color: '#FF3D7A', thickness: 1.6 }),

    // ticket-stub link 01 — perforated edge feel via outlined chunky pill
    link1: N('link1', 'link', { x: 16, y: 506, w: 288, h: 48,
      text: '▶  fancam · ep.07', url: 'jiwoo.cucu/cam', variant: 'pill',
      bg: '#1A0E1F', textColor: '#FFD93D', borderW: 2, borderC: '#1A0E1F', radius: 10 }),
    link2: N('link2', 'link', { x: 16, y: 560, w: 138, h: 44,
      text: 'lightstick', url: 'jiwoo.cucu/stick', variant: 'pill',
      bg: '#FF3D7A', textColor: '#FFFFFF', borderW: 2, borderC: '#1A0E1F', radius: 10 }),
    link3: N('link3', 'link', { x: 166, y: 560, w: 138, h: 44,
      text: 'fan club ➜', url: 'jiwoo.cucu/dc', variant: 'pill',
      bg: '#FFFFFF', textColor: '#1A0E1F', borderW: 2, borderC: '#1A0E1F', radius: 10 }),

    // bottom serial / catalogue line — looks like the back of an album
    serial: N('serial', 'text', {
      x: 16, y: 614, w: 200, h: 12,
      text: 'CAT. NO. KPOP-026 · DELUXE',
      font: 'fraunces', weight: 700, italic: false, size: 8.5,
      color: '#1A0E1F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    serialR: N('serialR', 'text', {
      x: 104, y: 614, w: 200, h: 12,
      text: '★ unofficial fan profile',
      font: 'fraunces', weight: 500, italic: true, size: 8.5,
      color: '#1A0E1F', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // tiny barcode-ish row of dashes
    barcode: N('barcode', 'text', {
      x: 16, y: 630, w: 288, h: 14,
      text: '▮▮ ▮ ▮▮▮ ▮ ▮▮ ▮▮▮▮ ▮ ▮▮ ▮ ▮▮▮ ▮ ▮▮ ▮▮ ▮ ▮▮▮',
      font: 'fraunces', weight: 700, italic: false, size: 10,
      color: '#1A0E1F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
  },
  order: [
    'ticketBar','ticketTxt',
    'photocard','photo','cardLabel',
    'stamp','stampTxt','dateChip',
    'headerShadow','header',
    'chip1','chip2','chip3',
    'tag','div1',
    'link1','link2','link3',
    'serial','serialR','barcode',
  ],
};

// ── 4. PORTFOLIO ───────────────────────────────────────────────
// Clean designer/dev portfolio. Cream paper, navy ink, work grid hero, role
// pills. Asymmetric: avatar small top-left, name takes the right column,
// gallery is the dominant block.
const TPL_PORTFOLIO = {
  id: 'portfolio',
  name: 'Studio Index',
  vibe: 'portfolio · case-study · clean',
  swatch: ['#F2EEE3', '#1F2D45', '#D2A85A', '#FFFFFF'],
  bgColor: '#F2EEE3',
  bgImage: null,
  nodes: {
    // tiny avatar top-left
    avatar: N('avatar', 'image', {
      x: 24, y: 32, w: 44, h: 44, radius: 22, borderW: 1, borderC: '#1F2D45', clip: 'circle', tone: 'butter',
    }),
    // status dot text
    status: N('status', 'text', {
      x: 76, y: 32, w: 200, h: 14,
      text: '● AVAILABLE FOR WORK', font: 'fraunces', weight: 600, italic: false, size: 10,
      color: '#3F7A52', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    statusSub: N('statusSub', 'text', {
      x: 76, y: 50, w: 200, h: 14,
      text: 'q3 / 2026 — booking sept', font: 'fraunces', weight: 400, italic: true, size: 11,
      color: '#5A4F3F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // header — designer name, large
    header: N('header', 'text', {
      x: 24, y: 92, w: 272, h: 48,
      text: 'Aria Hoshino', font: 'fraunces', weight: 700, italic: false, size: 32,
      color: '#1F2D45', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // role line
    role: N('role', 'text', {
      x: 24, y: 132, w: 272, h: 22,
      text: 'product designer & art director', font: 'fraunces', weight: 400, italic: true, size: 15,
      color: '#5A4F3F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // role pills container — three little pills
    pill1: N('pill1', 'link', { x: 24, y: 164, w: 70, h: 26,
      text: 'identity', url: '#', variant: 'pill',
      bg: '#FFFFFF', textColor: '#1F2D45', borderW: 1, borderC: '#1F2D45', radius: 13 }),
    pill2: N('pill2', 'link', { x: 100, y: 164, w: 64, h: 26,
      text: 'web', url: '#', variant: 'pill',
      bg: '#FFFFFF', textColor: '#1F2D45', borderW: 1, borderC: '#1F2D45', radius: 13 }),
    pill3: N('pill3', 'link', { x: 170, y: 164, w: 84, h: 26,
      text: 'editorial', url: '#', variant: 'pill',
      bg: '#1F2D45', textColor: '#F2EEE3', borderW: 1, borderC: '#1F2D45', radius: 13 }),
    // section label — selected work
    workLabel: N('workLabel', 'text', {
      x: 24, y: 208, w: 200, h: 14,
      text: '— SELECTED WORK', font: 'fraunces', weight: 700, italic: false, size: 11,
      color: '#1F2D45', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    workCount: N('workCount', 'text', {
      x: 24, y: 208, w: 272, h: 14,
      text: '12 PROJECTS', font: 'fraunces', weight: 500, italic: false, size: 10,
      color: '#9A8C72', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // big gallery hero
    gallery: N('gallery', 'gallery', {
      x: 24, y: 230, w: 272, h: 200, tones: ['butter','sky','sage','peach'],
      layout: 'grid', gap: 4, fit: 'fill', radius: 8, borderW: 1, borderC: '#1F2D45',
    }),
    // hairline divider
    div1: N('div1', 'divider', { x: 24, y: 446, w: 272, h: 4, style: 'solid', color: '#1F2D45', thickness: 1 }),
    // contact links
    link1: N('link1', 'link', { x: 24, y: 460, w: 272, h: 44,
      text: 'View case studies →', url: 'aria.cucu/work', variant: 'pill',
      bg: '#1F2D45', textColor: '#F2EEE3', borderW: 0, borderC: '#1F2D45', radius: 0 }),
    link2: N('link2', 'link', { x: 24, y: 510, w: 132, h: 44,
      text: 'Email', url: 'mailto:hello', variant: 'pill',
      bg: 'transparent', textColor: '#1F2D45', borderW: 1, borderC: '#1F2D45', radius: 0 }),
    link3: N('link3', 'link', { x: 164, y: 510, w: 132, h: 44,
      text: 'Read.cv', url: 'aria.cucu/cv', variant: 'pill',
      bg: 'transparent', textColor: '#1F2D45', borderW: 1, borderC: '#1F2D45', radius: 0 }),
    // bottom row — index numbers
    foot: N('foot', 'text', {
      x: 24, y: 580, w: 272, h: 14,
      text: 'TOKYO · NEW YORK', font: 'fraunces', weight: 600, italic: false, size: 10,
      color: '#5A4F3F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    footR: N('footR', 'text', {
      x: 24, y: 580, w: 272, h: 14,
      text: '↗ aria.studio', font: 'fraunces', weight: 600, italic: false, size: 10,
      color: '#5A4F3F', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    foot2: N('foot2', 'text', {
      x: 24, y: 596, w: 272, h: 14,
      text: '+12 years independent practice', font: 'fraunces', weight: 400, italic: true, size: 11,
      color: '#9A8C72', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
  },
  order: ['avatar','status','statusSub','header','role','pill1','pill2','pill3','workLabel','workCount','gallery','div1','link1','link2','link3','foot','footR','foot2'],
};

// ── 5. MYSPACE ────────────────────────────────────────────────
// 2006-coded chaotic energy. Bevelled cyan/purple, glitter, comic/serif mash,
// "About Me" panels, thin black borders, blinkie strip, "top friends" gallery
// instead of a clean grid. Embraces visual noise.
const TPL_MYSPACE = {
  id: 'myspace',
  name: 'Myspace',
  vibe: 'myspace · y2k · about-me chaos',
  swatch: ['#1B1B66', '#FF66CC', '#39E6F0', '#FFD93D'],
  bgColor: '#1B1B66',
  bgImage: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><g fill='%2339E6F0' fill-opacity='.45'><path d='M8 8 L9.2 5 L10.4 8 L13 9 L10.4 10 L9.2 13 L8 10 L5 9 Z'/><path d='M30 26 L31 24 L32 26 L34 27 L32 28 L31 30 L30 28 L28 27 Z'/></g></svg>")`,
  bgImageSize: 'tile',
  bgImageOpacity: 1,
  nodes: {
    // top blinkie banner
    blinkie: N('blinkie', 'container', {
      x: 0, y: 24, w: 320, h: 28, bg: '#FF66CC', radius: 0, borderW: 2, borderC: '#000000',
    }),
    blinkieTxt: N('blinkieTxt', 'text', {
      x: 0, y: 30, w: 320, h: 20,
      text: '✦ ✦ ✦  WELCOME 2 MY PAGE  ✦ ✦ ✦', font: 'caprasimo', weight: 400, italic: false, size: 13,
      color: '#FFFFFF', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // top panel — "About" frame
    aboutFrame: N('aboutFrame', 'container', {
      x: 14, y: 66, w: 292, h: 142, bg: '#FFFFFF', radius: 6, borderW: 2, borderC: '#000000',
    }),
    aboutHeader: N('aboutHeader', 'container', {
      x: 14, y: 66, w: 292, h: 22, bg: '#39E6F0', radius: 0, borderW: 2, borderC: '#000000',
    }),
    aboutLabel: N('aboutLabel', 'text', {
      x: 22, y: 68, w: 270, h: 18,
      text: '★ luna_xo  ·  online', font: 'caprasimo', weight: 400, italic: false, size: 12,
      color: '#000000', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // avatar inside the white frame, square w/ thin border
    avatar: N('avatar', 'image', {
      x: 24, y: 96, w: 88, h: 88, radius: 4, borderW: 2, borderC: '#000000', clip: 'rect', tone: 'rose',
    }),
    // bio — handwritten, two lines, multi-color via fraunces italic w/ pink
    bio: N('bio', 'text', {
      x: 122, y: 96, w: 176, h: 96,
      text: '"about me ♡"\nage: 22\nmood: blasting\ny2k mixtapes\non repeat ✿',
      font: 'fraunces', weight: 500, italic: true, size: 13,
      color: '#1B1B66', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // big sparkle name BELOW avatar panel — Lobster pink with glow
    header: N('header', 'text', {
      x: 14, y: 218, w: 292, h: 60,
      text: '★ luna ★', font: 'lobster', weight: 400, italic: false, size: 48,
      color: '#FF66CC', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // tagline glitter
    tag: N('tag', 'text', {
      x: 14, y: 270, w: 292, h: 20,
      text: '↳ certified glitter enthusiast ⋆˙⟡', font: 'patrick', weight: 400, italic: false, size: 14,
      color: '#FFD93D', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // sparkle divider
    div1: N('div1', 'divider', { x: 14, y: 296, w: 292, h: 22, style: 'sparkleChain', color: '#39E6F0', thickness: 1.6 }),
    // top friends panel header
    friendsFrame: N('friendsFrame', 'container', {
      x: 14, y: 326, w: 292, h: 132, bg: '#FFFFFF', radius: 6, borderW: 2, borderC: '#000000',
    }),
    friendsBar: N('friendsBar', 'container', {
      x: 14, y: 326, w: 292, h: 22, bg: '#FFD93D', radius: 0, borderW: 2, borderC: '#000000',
    }),
    friendsLabel: N('friendsLabel', 'text', {
      x: 22, y: 328, w: 270, h: 18,
      text: '◆ TOP 4 FRIENDS', font: 'caprasimo', weight: 400, italic: false, size: 12,
      color: '#000000', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // tiny gallery as "top friends"
    gallery: N('gallery', 'gallery', {
      x: 22, y: 354, w: 276, h: 96, tones: ['rose','sky','butter','sage'],
      layout: 'grid', gap: 6, fit: 'fill', radius: 4, borderW: 2, borderC: '#000000',
    }),
    // chunky bevel link
    link1: N('link1', 'link', { x: 14, y: 472, w: 292, h: 44,
      text: '☆ leave me a comment ☆', url: 'luna.cucu/comments', variant: 'pill',
      bg: '#FF66CC', textColor: '#FFFFFF', borderW: 2, borderC: '#000000', radius: 6 }),
    link2: N('link2', 'link', { x: 14, y: 522, w: 142, h: 40,
      text: '+ add me', url: '#', variant: 'pill',
      bg: '#39E6F0', textColor: '#000000', borderW: 2, borderC: '#000000', radius: 6 }),
    link3: N('link3', 'link', { x: 164, y: 522, w: 142, h: 40,
      text: 'send msg', url: '#', variant: 'pill',
      bg: '#FFD93D', textColor: '#000000', borderW: 2, borderC: '#000000', radius: 6 }),
    // hit counter
    counter: N('counter', 'text', {
      x: 14, y: 580, w: 292, h: 16,
      text: '✦ visitors: 0 0 4 2 7 8 1 ✦', font: 'fraunces', weight: 700, italic: false, size: 11,
      color: '#39E6F0', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    counterSub: N('counterSub', 'text', {
      x: 14, y: 600, w: 292, h: 16,
      text: 'thx 4 stopping by!! ♡♡♡', font: 'patrick', weight: 400, italic: false, size: 13,
      color: '#FFFFFF', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
  },
  order: ['blinkie','blinkieTxt','aboutFrame','aboutHeader','aboutLabel','avatar','bio','header','tag','div1','friendsFrame','friendsBar','friendsLabel','gallery','link1','link2','link3','counter','counterSub'],
};

// ── 6. COOL KID ───────────────────────────────────────────────
// Streetwear/skate energy. Dark olive + safety-orange + bone white. Mono caps,
// big stencil-feel header (Yeseva), photo grid bottom, "lvl 99" badge,
// asymmetric hero with ID-card framing.
const TPL_COOLKID = {
  id: 'coolkid',
  name: 'Cool Kid',
  vibe: 'cool kid · streetwear · stencil',
  swatch: ['#1F2018', '#FF5A1F', '#E8E2D0', '#9DA180'],
  bgColor: '#1F2018',
  bgImage: null,
  nodes: {
    // top serial strip
    strip: N('strip', 'text', {
      x: 18, y: 28, w: 180, h: 14,
      text: '◢ SUBJECT // ID-09', font: 'fraunces', weight: 700, italic: false, size: 10,
      color: '#FF5A1F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    stripR: N('stripR', 'text', {
      x: 122, y: 28, w: 180, h: 14,
      text: 'ISSUE 026', font: 'fraunces', weight: 700, italic: false, size: 10,
      color: '#E8E2D0', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // ID-card frame for big photo
    idFrame: N('idFrame', 'container', {
      x: 18, y: 52, w: 200, h: 230, bg: '#2B2C22', radius: 4, borderW: 2, borderC: '#FF5A1F',
    }),
    photo: N('photo', 'image', {
      x: 26, y: 60, w: 184, h: 184, radius: 2, borderW: 0, borderC: '#000', clip: 'rect', tone: 'sage',
    }),
    photoLabel: N('photoLabel', 'text', {
      x: 26, y: 250, w: 184, h: 22,
      text: 'NO. 09 / SUBJECT FILE',
      font: 'fraunces', weight: 700, italic: false, size: 9.5,
      color: '#FF5A1F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // big stencil name on the right side, vertical stack
    headerL1: N('headerL1', 'text', {
      x: 224, y: 60, w: 80, h: 50,
      text: 'KAI', font: 'yeseva', weight: 400, italic: false, size: 44,
      color: '#E8E2D0', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    headerL2: N('headerL2', 'text', {
      x: 224, y: 110, w: 80, h: 50,
      text: 'NOR', font: 'yeseva', weight: 400, italic: false, size: 44,
      color: '#FF5A1F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // lvl badge
    lvlBadge: N('lvlBadge', 'text', {
      x: 224, y: 174, w: 78, h: 28,
      text: 'LVL · 99', font: 'caprasimo', weight: 400, italic: false, size: 13,
      color: '#1F2018', align: 'center', bg: '#FF5A1F', radius: 0, borderW: 2, borderC: '#E8E2D0', padding: 0,
    }),
    locTag: N('locTag', 'text', {
      x: 224, y: 210, w: 80, h: 18,
      text: '↳ TOKYO', font: 'fraunces', weight: 700, italic: false, size: 11,
      color: '#9DA180', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // dashed orange line
    div1: N('div1', 'divider', { x: 18, y: 296, w: 284, h: 8, style: 'dashed', color: '#FF5A1F', thickness: 2 }),
    // bio block
    bio: N('bio', 'text', {
      x: 18, y: 312, w: 284, h: 56,
      text: 'designer · skater · always\nshooting on 35mm — never sleeps,\ndrinks too much matcha.',
      font: 'fraunces', weight: 500, italic: false, size: 13,
      color: '#E8E2D0', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // 2x2 photo grid
    galleryLabel: N('galleryLabel', 'text', {
      x: 18, y: 376, w: 284, h: 14,
      text: '— FIELD KIT', font: 'fraunces', weight: 700, italic: false, size: 10,
      color: '#FF5A1F', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    gallery: N('gallery', 'gallery', {
      x: 18, y: 394, w: 284, h: 110, tones: ['sage','butter','sky','rose'],
      layout: 'grid', gap: 4, fit: 'fill', radius: 0, borderW: 1.5, borderC: '#E8E2D0',
    }),
    // chunky links
    link1: N('link1', 'link', { x: 18, y: 518, w: 284, h: 46,
      text: '◆ portfolio · 26', url: 'kainor.cucu/work', variant: 'pill',
      bg: '#FF5A1F', textColor: '#1F2018', borderW: 0, borderC: '#FF5A1F', radius: 0 }),
    link2: N('link2', 'link', { x: 18, y: 568, w: 138, h: 42,
      text: 'shop', url: '#', variant: 'pill',
      bg: 'transparent', textColor: '#E8E2D0', borderW: 1.5, borderC: '#E8E2D0', radius: 0 }),
    link3: N('link3', 'link', { x: 164, y: 568, w: 138, h: 42,
      text: 'IG ↗', url: '#', variant: 'pill',
      bg: 'transparent', textColor: '#E8E2D0', borderW: 1.5, borderC: '#E8E2D0', radius: 0 }),
    // bottom barcode line
    foot: N('foot', 'text', {
      x: 18, y: 624, w: 284, h: 12,
      text: '▮ ▮▮▮ ▮ ▮▮ ▮▮ ▮ ▮▮▮ ▮▮ ▮ ▮▮ ▮▮▮ · CAT.09',
      font: 'fraunces', weight: 700, italic: false, size: 9,
      color: '#9DA180', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
  },
  order: ['strip','stripR','idFrame','photo','photoLabel','headerL1','headerL2','lvlBadge','locTag','div1','bio','galleryLabel','gallery','link1','link2','link3','foot'],
};

// ── 7. ARTSY ──────────────────────────────────────────────────
// Cutesy/artsy gallerist. Warm linen background, hand-cut paper feel, mixed
// fonts (Caveat handwriting + Fraunces serif), torn-paper containers, soft
// muted palette. The avatar is a tilted "polaroid" with caption underneath,
// the bio is handwritten, links look like tape labels.
const TPL_ARTSY = {
  id: 'artsy',
  name: 'Artsy',
  vibe: 'artsy · cutesy · paper collage',
  swatch: ['#F4ECDA', '#C44536', '#3F4A3A', '#E8C28E'],
  bgColor: '#F4ECDA',
  bgImage: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><circle cx='2' cy='2' r='1.4' fill='%233F4A3A' fill-opacity='.13'/></svg>")`,
  bgImageSize: 'tile',
  bgImageOpacity: 1,
  nodes: {
    // tiny mono masthead
    masthead: N('masthead', 'text', {
      x: 24, y: 30, w: 272, h: 14,
      text: '— SKETCHBOOK · NO. 12', font: 'fraunces', weight: 700, italic: false, size: 10,
      color: '#3F4A3A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    mastR: N('mastR', 'text', {
      x: 96, y: 30, w: 200, h: 14,
      text: 'spring · 26', font: 'fraunces', weight: 500, italic: true, size: 10,
      color: '#3F4A3A', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // big serif handlettered name
    header: N('header', 'text', {
      x: 24, y: 56, w: 272, h: 56,
      text: 'wren\nfields.', font: 'fraunces', weight: 700, italic: false, size: 38,
      color: '#3F4A3A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // handwritten subtitle, as if penned in
    subtitle: N('subtitle', 'text', {
      x: 24, y: 152, w: 200, h: 26,
      text: 'painter, tiny things, mostly yellow.',
      font: 'caveat', weight: 700, italic: false, size: 18,
      color: '#C44536', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // polaroid avatar — white card with photo inside, caption below
    polaroid: N('polaroid', 'container', {
      x: 196, y: 78, w: 100, h: 116, bg: '#FFFFFF', radius: 4, borderW: 1, borderC: '#3F4A3A',
    }),
    avatar: N('avatar', 'image', {
      x: 202, y: 84, w: 88, h: 88, radius: 2, borderW: 0, borderC: '#000', clip: 'rect', tone: 'butter',
    }),
    polaroidCap: N('polaroidCap', 'text', {
      x: 196, y: 174, w: 100, h: 18,
      text: "me, '24",
      font: 'caveat', weight: 700, italic: false, size: 14,
      color: '#3F4A3A', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // a heart sticker between blocks
    heart: N('heart', 'icon', {
      x: 168, y: 188, w: 36, h: 36, glyph: 'heart',
      plate: '#E8C28E', tint: '#C44536', radius: 18, borderW: 1, borderC: '#3F4A3A',
    }),
    // flower divider in muted green
    div1: N('div1', 'divider', { x: 24, y: 222, w: 272, h: 22, style: 'flowerChain', color: '#3F4A3A', thickness: 1.4 }),
    // "today" handwritten note panel — ivory card
    notePanel: N('notePanel', 'container', {
      x: 24, y: 258, w: 272, h: 116, bg: '#FBF5E5', radius: 6, borderW: 1, borderC: '#3F4A3A',
    }),
    noteLabel: N('noteLabel', 'text', {
      x: 36, y: 268, w: 248, h: 14,
      text: 'TODAY ·', font: 'fraunces', weight: 700, italic: false, size: 9,
      color: '#C44536', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    note: N('note', 'text', {
      x: 36, y: 284, w: 248, h: 80,
      text: 'pressing flowers,\nlearning to stretch canvas,\ndrawing the same lemon\nfor the seventh time —',
      font: 'caveat', weight: 700, italic: false, size: 18,
      color: '#3F4A3A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    // works gallery label
    worksLabel: N('worksLabel', 'text', {
      x: 24, y: 388, w: 272, h: 14,
      text: '— RECENT WORKS', font: 'fraunces', weight: 700, italic: false, size: 10,
      color: '#3F4A3A', align: 'left', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    worksCount: N('worksCount', 'text', {
      x: 24, y: 388, w: 272, h: 14,
      text: '04 · 12',
      font: 'fraunces', weight: 500, italic: true, size: 10,
      color: '#9A8C72', align: 'right', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
    gallery: N('gallery', 'gallery', {
      x: 24, y: 406, w: 272, h: 110, tones: ['butter','rose','sage','peach'],
      layout: 'grid', gap: 6, fit: 'fill', radius: 4, borderW: 1, borderC: '#3F4A3A',
    }),
    // tape-label links
    link1: N('link1', 'link', { x: 24, y: 528, w: 272, h: 44,
      text: 'open studio · saturdays', url: 'wren.cucu/studio', variant: 'pill',
      bg: '#FBF5E5', textColor: '#3F4A3A', borderW: 1, borderC: '#3F4A3A', radius: 4 }),
    link2: N('link2', 'link', { x: 24, y: 578, w: 130, h: 40,
      text: 'shop prints', url: '#', variant: 'pill',
      bg: '#C44536', textColor: '#FBF5E5', borderW: 1, borderC: '#3F4A3A', radius: 4 }),
    link3: N('link3', 'link', { x: 162, y: 578, w: 134, h: 40,
      text: 'newsletter ✿', url: '#', variant: 'pill',
      bg: 'transparent', textColor: '#3F4A3A', borderW: 1, borderC: '#3F4A3A', radius: 4 }),
    sig: N('sig', 'text', {
      x: 24, y: 626, w: 272, h: 14,
      text: 'with love, from the studio ✿',
      font: 'caveat', weight: 700, italic: false, size: 14,
      color: '#C44536', align: 'center', bg: 'transparent', radius: 0, borderW: 0, padding: 0,
    }),
  },
  order: ['masthead','mastR','header','subtitle','polaroid','avatar','polaroidCap','heart','div1','notePanel','noteLabel','note','worksLabel','worksCount','gallery','link1','link2','link3','sig'],
};

const TEMPLATES = [TPL_KAWAII, TPL_MINIMAL, TPL_KPOP, TPL_PORTFOLIO, TPL_MYSPACE, TPL_COOLKID, TPL_ARTSY];

Object.assign(window, { TEMPLATES, CANVAS_W, CANVAS_H });
