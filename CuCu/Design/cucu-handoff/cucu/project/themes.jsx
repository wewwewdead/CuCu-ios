// themes.jsx — curated themes + custom mode
// Each theme defines: app chrome palette + profile defaults (bg, text, link/icon styles, font, divider style)
// Background can be a flat color, a built-in pattern (CSS gradient/SVG), OR a user-uploaded image.

// ─── Built-in background presets (CSS, no external assets) ─────
const BG_IMAGES = {
  none: null,
  paperGrid: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><path d='M0 .5H40M.5 0V40' stroke='%23000' stroke-opacity='.07'/></svg>")`,
  dots: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='22' height='22'><circle cx='2' cy='2' r='1.4' fill='%23000' fill-opacity='.18'/></svg>")`,
  hearts: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><path d='M16 24 C 8 18, 6 12, 10 9 C 13 7, 16 9, 16 12 C 16 9, 19 7, 22 9 C 26 12, 24 18, 16 24 Z' fill='%23B8324B' fill-opacity='.22'/></svg>")`,
  sparkles: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><g fill='%23B8324B' fill-opacity='.28'><path d='M8 8 L9.2 5 L10.4 8 L13 9 L10.4 10 L9.2 13 L8 10 L5 9 Z'/><path d='M30 26 L31 24 L32 26 L34 27 L32 28 L31 30 L30 28 L28 27 Z'/></g></svg>")`,
  checkers: `repeating-conic-gradient(rgba(0,0,0,.05) 0% 25%, transparent 0% 50%) 0 / 24px 24px`,
  sunset: `linear-gradient(180deg, rgba(255,184,140,0.55) 0%, rgba(255,228,200,0) 55%, rgba(184,140,200,0.35) 100%)`,
  meadow: `radial-gradient(60% 50% at 50% 100%, rgba(80,140,90,0.30) 0%, transparent 70%)`,
  hazyDusk: `linear-gradient(180deg, rgba(245,166,181,0.18) 0%, rgba(34,31,44,0) 60%)`,
};

const BG_IMAGE_LIST = [
  { k: 'none',      label: 'None',     hint: 'flat color only' },
  { k: 'paperGrid', label: 'Grid',     hint: 'subtle paper grid' },
  { k: 'dots',      label: 'Dots',     hint: 'polka dots' },
  { k: 'hearts',    label: 'Hearts',   hint: 'tiled hearts' },
  { k: 'sparkles',  label: 'Sparkles', hint: 'tiled sparkles' },
  { k: 'checkers',  label: 'Checkers', hint: 'soft checker' },
  { k: 'sunset',    label: 'Sunset',   hint: 'top-down warm wash' },
  { k: 'meadow',    label: 'Meadow',   hint: 'green ground glow' },
  { k: 'hazyDusk',  label: 'Haze',     hint: 'rose haze on top' },
];

const THEMES = {
  peachCottage: {
    name: 'Peach Cottage',
    sub: 'warm, soft, hand-stitched',
    chromeKey: 'cream',
    swatch: ['#F8E0D2', '#B8324B', '#3A1A1F', '#FFE3EC'],
    profile: {
      bgColor: '#F8E0D2',
      bgImageKey: 'sparkles',
      headerColor: '#3A1A1F',
      bioColor: '#3A1A1F',
      headerFont: 'caprasimo',
      bioFont: 'fraunces',
      iconPlate: '#FFE3EC',
      iconTint: '#B8324B',
      iconBorder: '#3A1A1F',
      linkBg: '#FBF6E9',
      linkText: '#3A1A1F',
      linkBorder: '#3A1A1F',
      linkBgAlt: '#3A1A1F',
      linkTextAlt: '#FBF6E9',
      dividerStyle: 'sparkleChain',
      dividerColor: '#B8324B',
      avatarBorder: '#3A1A1F',
    },
  },
  mintGarden: {
    name: 'Mint Garden',
    sub: 'fresh, breezy, springtime',
    chromeKey: 'mint',
    swatch: ['#E8EFE6', '#3F7A52', '#15281C', '#DDF1D5'],
    profile: {
      bgColor: '#D8E9C9',
      bgImageKey: 'meadow',
      headerColor: '#15281C',
      bioColor: '#15281C',
      headerFont: 'yeseva',
      bioFont: 'fraunces',
      iconPlate: '#DDF1D5',
      iconTint: '#3F7A52',
      iconBorder: '#15281C',
      linkBg: '#F5FAF1',
      linkText: '#15281C',
      linkBorder: '#15281C',
      linkBgAlt: '#3F7A52',
      linkTextAlt: '#F5FAF1',
      dividerStyle: 'flowerChain',
      dividerColor: '#3F7A52',
      avatarBorder: '#15281C',
    },
  },
  duskDiary: {
    name: 'Dusk Diary',
    sub: 'moody, midnight, intimate',
    chromeKey: 'dusk',
    swatch: ['#1B1923', '#F5A6B5', '#F4EFE2', '#3A2A36'],
    profile: {
      bgColor: '#221F2C',
      bgImageKey: 'hazyDusk',
      headerColor: '#F4EFE2',
      bioColor: '#C0B8A2',
      headerFont: 'fraunces',
      bioFont: 'caveat',
      iconPlate: '#3A2A36',
      iconTint: '#F5A6B5',
      iconBorder: '#F4EFE2',
      linkBg: 'transparent',
      linkText: '#F4EFE2',
      linkBorder: '#F4EFE2',
      linkBgAlt: '#F5A6B5',
      linkTextAlt: '#221F2C',
      dividerStyle: 'starChain',
      dividerColor: '#F5A6B5',
      avatarBorder: '#F4EFE2',
    },
  },
  butterZine: {
    name: 'Butter Zine',
    sub: 'punchy, photocopy, cut-and-paste',
    chromeKey: 'cream',
    swatch: ['#FBE9A8', '#1A140E', '#B8324B', '#FFFFFF'],
    profile: {
      bgColor: '#FBE9A8',
      bgImageKey: 'paperGrid',
      headerColor: '#1A140E',
      bioColor: '#1A140E',
      headerFont: 'caprasimo',
      bioFont: 'patrick',
      iconPlate: '#FFFFFF',
      iconTint: '#1A140E',
      iconBorder: '#1A140E',
      linkBg: '#FFFFFF',
      linkText: '#1A140E',
      linkBorder: '#1A140E',
      linkBgAlt: '#1A140E',
      linkTextAlt: '#FBE9A8',
      dividerStyle: 'starChain',
      dividerColor: '#1A140E',
      avatarBorder: '#1A140E',
    },
  },
  bubblegum: {
    name: 'Bubblegum',
    sub: 'sweet, candy, y2k',
    chromeKey: 'cream',
    swatch: ['#F5C9D4', '#B8324B', '#3A1A26', '#FFF1B8'],
    profile: {
      bgColor: '#F5C9D4',
      bgImageKey: 'hearts',
      headerColor: '#3A1A26',
      bioColor: '#3A1A26',
      headerFont: 'lobster',
      bioFont: 'fraunces',
      iconPlate: '#FFF1B8',
      iconTint: '#B8324B',
      iconBorder: '#3A1A26',
      linkBg: '#FFFFFF',
      linkText: '#3A1A26',
      linkBorder: '#3A1A26',
      linkBgAlt: '#B8324B',
      linkTextAlt: '#FFFFFF',
      dividerStyle: 'heartChain',
      dividerColor: '#B8324B',
      avatarBorder: '#3A1A26',
    },
  },
  paperPress: {
    name: 'Paper Press',
    sub: 'editorial, restrained, classic',
    chromeKey: 'cream',
    swatch: ['#FBF6E9', '#1A140E', '#5A4F3F', '#E5E0D2'],
    profile: {
      bgColor: '#FBF6E9',
      bgImageKey: 'none',
      headerColor: '#1A140E',
      bioColor: '#5A4F3F',
      headerFont: 'yeseva',
      bioFont: 'fraunces',
      iconPlate: '#E5E0D2',
      iconTint: '#1A140E',
      iconBorder: '#1A140E',
      linkBg: 'transparent',
      linkText: '#1A140E',
      linkBorder: '#1A140E',
      linkBgAlt: '#1A140E',
      linkTextAlt: '#FBF6E9',
      dividerStyle: 'solid',
      dividerColor: '#1A140E',
      avatarBorder: '#1A140E',
    },
  },
  oceanRoom: {
    name: 'Ocean Room',
    sub: 'cool, blue hour, watercolor',
    chromeKey: 'mint',
    swatch: ['#D9E5F5', '#3A4D7C', '#1F2D45', '#F5C9D4'],
    profile: {
      bgColor: '#D9E5F5',
      bgImageKey: 'sunset',
      headerColor: '#1F2D45',
      bioColor: '#1F2D45',
      headerFont: 'fraunces',
      bioFont: 'caveat',
      iconPlate: '#F5C9D4',
      iconTint: '#3A4D7C',
      iconBorder: '#1F2D45',
      linkBg: '#FBF8EE',
      linkText: '#1F2D45',
      linkBorder: '#1F2D45',
      linkBgAlt: '#3A4D7C',
      linkTextAlt: '#FBF8EE',
      dividerStyle: 'sparkleChain',
      dividerColor: '#3A4D7C',
      avatarBorder: '#1F2D45',
    },
  },
};

// Apply theme to current profile doc
function applyThemeToDoc(doc, theme) {
  const t = theme.profile;
  // bgImage can be a key into BG_IMAGES, a raw url(...), data: URI, or a CSS gradient string
  let bgImage = null;
  if (t.bgImageRaw) bgImage = t.bgImageRaw;
  else if (t.bgImageKey && t.bgImageKey !== 'none') bgImage = BG_IMAGES[t.bgImageKey];

  const next = {
    ...doc,
    bgColor: t.bgColor,
    bgImage,
    bgImageKey: t.bgImageKey || 'none',
    bgImageOpacity: t.bgImageOpacity ?? 1,
    bgImageBlur: t.bgImageBlur ?? 0,
    bgImageSize: t.bgImageSize || (t.bgImageKey && ['paperGrid','dots','hearts','sparkles','checkers'].includes(t.bgImageKey) ? 'tile' : 'cover'),
    nodes: { ...doc.nodes },
  };
  for (const id of doc.order) {
    const n = { ...doc.nodes[id] };
    if (id === 'header') {
      n.color = t.headerColor;
      n.font = t.headerFont;
    } else if (id === 'bio') {
      n.color = t.bioColor;
      n.font = t.bioFont;
    } else if (n.type === 'icon') {
      n.plate = t.iconPlate;
      n.tint = t.iconTint;
      n.borderC = t.iconBorder;
    } else if (n.type === 'link') {
      // alternate primary/secondary by index in order
      const isAlt = id === 'link2';
      n.bg = isAlt ? t.linkBgAlt : t.linkBg;
      n.textColor = isAlt ? t.linkTextAlt : t.linkText;
      n.borderC = t.linkBorder;
    } else if (n.type === 'divider') {
      n.style = t.dividerStyle;
      n.color = t.dividerColor;
    } else if (n.type === 'image' && n.clip === 'circle') {
      n.borderC = t.avatarBorder;
    } else if (n.type === 'text') {
      n.color = t.headerColor;
    }
    next.nodes[id] = n;
  }
  return next;
}

// ─── Theme Sheet UI ─────────────────────────────────────────────
function ThemeChip({ theme, active, onClick, palette }) {
  const t = theme.profile;
  const bgImg = t.bgImageRaw || (t.bgImageKey && t.bgImageKey !== 'none' ? BG_IMAGES[t.bgImageKey] : null);
  const isTile = ['paperGrid','dots','hearts','sparkles','checkers'].includes(t.bgImageKey);
  return (
    <button onClick={onClick} style={{
      position: 'relative',
      border: `1.5px solid ${active ? palette.ink : palette.rule}`,
      borderRadius: 16,
      padding: 0,
      background: palette.cardSoft,
      cursor: 'pointer',
      overflow: 'hidden',
      textAlign: 'left',
      transition: 'transform .12s ease, border-color .12s ease',
      transform: active ? 'translateY(-2px)' : 'none',
      boxShadow: active ? `0 6px 0 ${palette.accent}` : `0 2px 0 ${palette.rule}`,
    }}>
      {/* mini preview */}
      <div style={{
        height: 130, padding: '14px 12px 0',
        background: t.bgColor,
        position: 'relative',
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5,
      }}>
        {/* background image overlay */}
        {bgImg && (
          <div style={{
            position: 'absolute', inset: 0, pointerEvents: 'none',
            backgroundImage: bgImg.includes('gradient') ? bgImg : bgImg,
            backgroundSize: isTile ? '20px 20px' : 'cover',
            backgroundRepeat: isTile ? 'repeat' : 'no-repeat',
            backgroundPosition: 'center',
          }}/>
        )}
        {/* mini header */}
        <span style={{
          fontFamily: FONT_OPTIONS[t.headerFont], fontSize: 17, color: t.headerColor,
          fontWeight: 700, lineHeight: 1, position: 'relative', zIndex: 1,
        }}>aa</span>
        {/* mini avatar */}
        <div style={{
          width: 32, height: 32, borderRadius: 16, overflow: 'hidden',
          border: `1.5px solid ${t.avatarBorder}`,
          position: 'relative', zIndex: 1,
        }}>
          <ThumbSVG tone="peach" />
        </div>
        {/* mini divider */}
        <div style={{ height: 8, width: 60, position: 'relative', zIndex: 1 }}>
          <DividerSVG style={t.dividerStyle} color={t.dividerColor} thickness={1.2} w={60} h={8} />
        </div>
        {/* mini link pills */}
        <div style={{
          display: 'flex', gap: 4, marginTop: 2, position: 'relative', zIndex: 1,
        }}>
          <span style={{
            display: 'inline-block', width: 32, height: 10,
            background: t.linkBg === 'transparent' ? 'transparent' : t.linkBg,
            border: `1px solid ${t.linkBorder}`, borderRadius: 5,
          }}/>
          <span style={{
            display: 'inline-block', width: 32, height: 10,
            background: t.linkBgAlt,
            border: `1px solid ${t.linkBorder}`, borderRadius: 5,
          }}/>
        </div>
        {/* image badge */}
        {bgImg && (
          <span style={{
            position: 'absolute', top: 6, right: 6, zIndex: 2,
            display: 'inline-flex', alignItems: 'center', gap: 3,
            background: 'rgba(255,255,255,0.85)',
            padding: '2px 5px', borderRadius: 8,
            fontFamily: MONO_FONT, fontSize: 7.5, letterSpacing: '0.1em',
            textTransform: 'uppercase', color: '#1A140E', fontWeight: 700,
            border: `1px solid ${t.avatarBorder}`,
          }}>
            <span style={{ fontSize: 8 }}>◉</span>
            IMG
          </span>
        )}
      </div>
      {/* meta strip */}
      <div style={{
        padding: '8px 12px 10px',
        background: palette.card,
        borderTop: `1px solid ${palette.rule}`,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4 }}>
          {theme.swatch.map((c, i) => (
            <span key={i} style={{
              width: 10, height: 10, borderRadius: 5, background: c,
              border: `1px solid ${palette.rule}`,
            }}/>
          ))}
          {active && <span style={{
            marginLeft: 'auto',
            fontFamily: MONO_FONT, fontSize: 8.5, letterSpacing: '0.14em',
            textTransform: 'uppercase', color: palette.accent, fontWeight: 700,
          }}>· On</span>}
        </div>
        <div style={{
          fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
          fontSize: 14, fontWeight: 600, color: palette.ink, lineHeight: 1.1,
        }}>{theme.name}</div>
        <div style={{
          fontFamily: BODY_FONT, fontSize: 10.5, color: palette.inkFaded, marginTop: 2,
        }}>{theme.sub}</div>
      </div>
    </button>
  );
}

function CustomBuilder({ palette, doc, setDoc, onApply }) {
  const [bg, setBg] = useState_T(doc.bgColor);
  const [accent, setAccent] = useState_T('#B8324B');
  const [font, setFont] = useState_T('fraunces');
  const [divider, setDivider] = useState_T('sparkleChain');
  const [bgImageKey, setBgImageKey] = useState_T('none');
  const [bgImageRaw, setBgImageRaw] = useState_T(null); // user-uploaded data URI
  const [bgImageOpacity, setBgImageOpacity] = useState_T(1);
  const [bgImageBlur, setBgImageBlur] = useState_T(0);
  const fileInputRef = React.useRef(null);

  const bgChoices = ['#F8E0D2', '#FBE9A8', '#D8E9C9', '#FBF6E9', '#F5C9D4', '#D9E5F5', '#221F2C', '#FFFFFF'];
  const accentChoices = ['#B8324B', '#3F7A52', '#3A4D7C', '#1A140E', '#D2557A', '#F5A6B5'];

  const onPickFile = (e) => {
    const f = e.target.files?.[0];
    if (!f) return;
    const r = new FileReader();
    r.onload = () => {
      setBgImageRaw(`url("${r.result}")`);
      setBgImageKey('upload');
    };
    r.readAsDataURL(f);
  };
  const removeImage = () => { setBgImageRaw(null); setBgImageKey('none'); };

  const previewBgImg = bgImageRaw || (bgImageKey !== 'none' ? BG_IMAGES[bgImageKey] : null);
  const isTile = ['paperGrid','dots','hearts','sparkles','checkers'].includes(bgImageKey);

  return (
    <div style={{
      border: `1.5px dashed ${palette.rule}`,
      borderRadius: 16,
      padding: 16,
      background: palette.cardSoft,
      display: 'flex', flexDirection: 'column', gap: 14,
    }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
      }}>
        {/* live preview swatch with current image */}
        <div style={{
          width: 38, height: 38, borderRadius: 9,
          background: bg, position: 'relative', overflow: 'hidden',
          border: `1.5px solid ${palette.ink}`,
        }}>
          {previewBgImg && (
            <div style={{
              position: 'absolute', inset: 0,
              backgroundImage: previewBgImg,
              backgroundSize: isTile ? '14px 14px' : 'cover',
              backgroundRepeat: isTile ? 'repeat' : 'no-repeat',
              backgroundPosition: 'center',
              opacity: bgImageOpacity,
              filter: bgImageBlur ? `blur(${bgImageBlur}px)` : undefined,
            }}/>
          )}
        </div>
        <div>
          <div style={{
            fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.16em',
            textTransform: 'uppercase', color: palette.inkFaded,
          }}>Custom</div>
          <div style={{
            fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
            fontSize: 16, fontWeight: 600, color: palette.ink, lineHeight: 1,
          }}>build your own</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <div>
          <div style={{ fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em', textTransform: 'uppercase', color: palette.inkFaded, marginBottom: 6 }}>Background color</div>
          <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
            {bgChoices.map(c => (
              <button key={c} onClick={() => setBg(c)} style={{
                width: 24, height: 24, borderRadius: 12,
                background: c, border: `2px solid ${bg === c ? palette.ink : 'transparent'}`,
                outline: `1px solid ${palette.rule}`, outlineOffset: 1,
                cursor: 'pointer', padding: 0,
              }}/>
            ))}
          </div>
        </div>
        <div>
          <div style={{ fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em', textTransform: 'uppercase', color: palette.inkFaded, marginBottom: 6 }}>Accent</div>
          <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
            {accentChoices.map(c => (
              <button key={c} onClick={() => setAccent(c)} style={{
                width: 24, height: 24, borderRadius: 12,
                background: c, border: `2px solid ${accent === c ? palette.ink : 'transparent'}`,
                outline: `1px solid ${palette.rule}`, outlineOffset: 1,
                cursor: 'pointer', padding: 0,
              }}/>
            ))}
          </div>
        </div>
      </div>

      {/* ─── Background image ─── */}
      <div>
        <div style={{
          display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
          marginBottom: 6, gap: 12,
        }}>
          <span style={{ fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em', textTransform: 'uppercase', color: palette.inkFaded, whiteSpace: 'nowrap' }}>Background image</span>
          <span style={{ fontFamily: BODY_FONT, fontSize: 10.5, color: palette.inkFaded, fontStyle: 'italic', whiteSpace: 'nowrap' }}>overlays the color</span>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(9, 1fr)', gap: 5 }}>
          {BG_IMAGE_LIST.map(({ k, label }) => {
            const isActive = bgImageKey === k && !bgImageRaw;
            const img = BG_IMAGES[k];
            const isT = ['paperGrid','dots','hearts','sparkles','checkers'].includes(k);
            return (
              <button key={k} onClick={() => { setBgImageKey(k); setBgImageRaw(null); }} title={label}
                style={{
                  position: 'relative', height: 48, borderRadius: 9,
                  border: `1.5px solid ${isActive ? palette.ink : palette.rule}`,
                  background: bg, padding: 0, cursor: 'pointer', overflow: 'hidden',
                  outline: isActive ? `2px solid ${accent}` : 'none', outlineOffset: 1,
                }}>
                {img && (
                  <div style={{
                    position: 'absolute', inset: 0,
                    backgroundImage: img,
                    backgroundSize: isT ? '14px 14px' : 'cover',
                    backgroundRepeat: isT ? 'repeat' : 'no-repeat',
                    backgroundPosition: 'center',
                  }}/>
                )}
                {!img && (
                  <span style={{
                    position: 'absolute', inset: 0, display: 'grid', placeItems: 'center',
                    fontFamily: MONO_FONT, fontSize: 8.5, color: palette.inkFaded,
                    letterSpacing: '0.08em', textTransform: 'uppercase',
                  }}>—</span>
                )}
              </button>
            );
          })}
        </div>
        {/* labels strip below to keep tiles clean */}
        <div style={{
          display: 'grid', gridTemplateColumns: 'repeat(9, 1fr)', gap: 5,
          marginTop: 4,
        }}>
          {BG_IMAGE_LIST.map(({ k, label }) => (
            <div key={k} style={{
              fontFamily: BODY_FONT, fontSize: 9.5, color: palette.inkSoft,
              textAlign: 'center', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{label}</div>
          ))}
        </div>

        {/* Upload + remove row */}
        <div style={{
          display: 'flex', gap: 8, marginTop: 8, alignItems: 'center',
        }}>
          <input
            ref={fileInputRef} type="file" accept="image/*" onChange={onPickFile}
            style={{ display: 'none' }}
          />
          <button onClick={() => fileInputRef.current?.click()} style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            height: 32, padding: '0 12px', borderRadius: 16,
            background: palette.card, border: `1px solid ${palette.rule}`,
            color: palette.ink, cursor: 'pointer',
            fontFamily: BODY_FONT, fontSize: 12, fontWeight: 600,
          }}>
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
              <rect x="1.5" y="2.5" width="11" height="9" rx="1.5"/>
              <circle cx="4.5" cy="5.5" r="1"/>
              <path d="M1.5 9 L4.5 6.5 L7 8.5 L10 5.5 L12.5 8"/>
            </svg>
            {bgImageRaw ? 'Replace image' : 'Upload image'}
          </button>
          {(bgImageRaw || bgImageKey !== 'none') && (
            <button onClick={removeImage} style={{
              height: 32, padding: '0 12px', borderRadius: 16,
              background: 'transparent', border: `1px solid ${palette.rule}`,
              color: palette.accent, cursor: 'pointer',
              fontFamily: BODY_FONT, fontSize: 12, fontWeight: 600,
            }}>Remove</button>
          )}
          {bgImageRaw && (
            <span style={{
              fontFamily: MONO_FONT, fontSize: 9.5, letterSpacing: '0.1em',
              color: palette.moss, textTransform: 'uppercase', fontWeight: 700,
            }}>· uploaded</span>
          )}
        </div>

        {/* effects sliders — only show when an image is set */}
        {(bgImageRaw || bgImageKey !== 'none') && (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginTop: 10 }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span style={{ fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em', textTransform: 'uppercase', color: palette.inkFaded }}>
                Opacity · {Math.round(bgImageOpacity * 100)}%
              </span>
              <input type="range" min="0" max="1" step="0.05" value={bgImageOpacity}
                onChange={(e) => setBgImageOpacity(parseFloat(e.target.value))}
                style={{ accentColor: accent }} />
            </label>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span style={{ fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em', textTransform: 'uppercase', color: palette.inkFaded }}>
                Blur · {bgImageBlur}px
              </span>
              <input type="range" min="0" max="20" step="1" value={bgImageBlur}
                onChange={(e) => setBgImageBlur(parseInt(e.target.value))}
                style={{ accentColor: accent }} />
            </label>
          </div>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <div>
          <div style={{ fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em', textTransform: 'uppercase', color: palette.inkFaded, marginBottom: 6 }}>Display Font</div>
          <select value={font} onChange={(e) => setFont(e.target.value)} style={{
            width: '100%', padding: '6px 10px', borderRadius: 10,
            border: `1px solid ${palette.rule}`, background: palette.card,
            fontFamily: FONT_OPTIONS[font], fontSize: 13, color: palette.ink,
          }}>
            {Object.keys(FONT_OPTIONS).map(k => <option key={k} value={k}>{k}</option>)}
          </select>
        </div>
        <div>
          <div style={{ fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em', textTransform: 'uppercase', color: palette.inkFaded, marginBottom: 6 }}>Divider</div>
          <select value={divider} onChange={(e) => setDivider(e.target.value)} style={{
            width: '100%', padding: '6px 10px', borderRadius: 10,
            border: `1px solid ${palette.rule}`, background: palette.card,
            fontFamily: BODY_FONT, fontSize: 13, color: palette.ink,
          }}>
            <option value="solid">Solid line</option>
            <option value="dashed">Dashed</option>
            <option value="dotted">Dotted</option>
            <option value="sparkleChain">Sparkles</option>
            <option value="heartChain">Hearts</option>
            <option value="starChain">Stars</option>
            <option value="flowerChain">Flowers</option>
          </select>
        </div>
      </div>

      <button
        onClick={() => onApply({
          name: 'Custom', sub: 'your blend', chromeKey: 'cream',
          swatch: [bg, accent, '#1A140E', '#FFFFFF'],
          profile: {
            bgColor: bg, headerColor: '#1A140E', bioColor: '#5A4F3F',
            headerFont: font, bioFont: 'fraunces',
            bgImageKey, bgImageRaw, bgImageOpacity, bgImageBlur,
            iconPlate: '#FFFFFF', iconTint: accent, iconBorder: '#1A140E',
            linkBg: '#FFFFFF', linkText: '#1A140E', linkBorder: '#1A140E',
            linkBgAlt: accent, linkTextAlt: '#FFFFFF',
            dividerStyle: divider, dividerColor: accent,
            avatarBorder: '#1A140E',
          },
        })}
        style={{
          height: 36, borderRadius: 18, border: 'none',
          background: palette.ink, color: palette.card,
          fontFamily: BODY_FONT, fontSize: 13, fontWeight: 600,
          cursor: 'pointer', boxShadow: `0 2px 0 ${accent}`,
        }}
      >Apply Custom Theme</button>
    </div>
  );
}

const useState_T = React.useState;

// ─── Main Theme Sheet (modal overlay) ───────────────────────────
function ThemeSheet({ open, onClose, currentThemeID, onPick, palette, doc, setDoc }) {
  if (!open) return null;
  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 200,
        background: 'rgba(20,15,10,0.32)',
        backdropFilter: 'blur(4px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 32,
        animation: 'fadeIn .15s ease',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: 'min(960px, 100%)',
          maxHeight: '90vh',
          background: palette.paper,
          border: `1px solid ${palette.rule}`,
          borderRadius: 22,
          boxShadow: '0 30px 80px rgba(0,0,0,0.18)',
          overflow: 'hidden',
          display: 'flex', flexDirection: 'column',
        }}
      >
        {/* header */}
        <div style={{
          padding: '16px 22px',
          display: 'flex', alignItems: 'center', gap: 14,
          borderBottom: `1px solid ${palette.rule}`,
          background: palette.card,
        }}>
          <div style={{
            width: 36, height: 36, borderRadius: 10,
            background: 'conic-gradient(from 0deg, #F8E0D2, #FBE9A8, #D8E9C9, #D9E5F5, #F5C9D4, #F8E0D2)',
            border: `1.5px solid ${palette.ink}`,
          }}/>
          <div>
            <div style={{
              fontFamily: MONO_FONT, fontSize: 9.5, letterSpacing: '0.18em',
              textTransform: 'uppercase', color: palette.inkFaded, marginBottom: 2,
            }}>Theme</div>
            <div style={{
              fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
              fontSize: 22, fontWeight: 600, color: palette.ink, lineHeight: 1,
            }}>pick a vibe</div>
          </div>
          <span style={{ flex: 1 }}/>
          <span style={{
            fontFamily: BODY_FONT, fontSize: 12, color: palette.inkSoft,
          }}>tap a chip → instant preview</span>
          <button onClick={onClose} style={{
            height: 32, padding: '0 14px', borderRadius: 16,
            border: `1px solid ${palette.rule}`, background: palette.cardSoft,
            color: palette.ink, fontFamily: BODY_FONT, fontSize: 12, fontWeight: 600,
            cursor: 'pointer',
          }}>Done</button>
        </div>

        {/* body */}
        <div style={{
          flex: 1, overflowY: 'auto', padding: 22,
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
          gap: 14,
        }}>
          {Object.entries(THEMES).map(([k, t]) => (
            <ThemeChip
              key={k} theme={t}
              active={currentThemeID === k}
              onClick={() => onPick(k, t)}
              palette={palette}
            />
          ))}
          <div style={{ gridColumn: '1 / -1' }}>
            <CustomBuilder palette={palette} doc={doc} setDoc={setDoc}
              onApply={(t) => onPick('custom', t)} />
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { THEMES, BG_IMAGES, BG_IMAGE_LIST, applyThemeToDoc, ThemeSheet, ThemeChip });
