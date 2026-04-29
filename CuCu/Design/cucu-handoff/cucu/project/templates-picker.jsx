// templates-picker.jsx — "Choose a Template" picker sheet & fullscreen preview
const { useState: useState_TP, useEffect: useEffect_TP } = React;

// Render a single node (lighter version of NodeView, no selection chrome,
// scaled positions). Reuses the global helpers ICON_GLYPHS, DividerSVG, ThumbSVG.
function TplNode({ node, scale = 1 }) {
  const baseStyle = {
    position: 'absolute',
    left: node.x * scale, top: node.y * scale,
    width: node.w * scale, height: node.h * scale,
    opacity: node.opacity,
    boxSizing: 'border-box',
  };

  if (node.type === 'text') {
    const fam = FONT_OPTIONS[node.font] || FONT_OPTIONS.fraunces;
    return (
      <div style={{
        ...baseStyle,
        background: node.bg === 'transparent' ? 'transparent' : node.bg,
        borderRadius: (node.radius || 0) * scale,
        border: node.borderW ? `${node.borderW * scale}px solid ${node.borderC}` : 'none',
        padding: (node.padding || 0) * scale,
        fontFamily: fam,
        fontStyle: node.italic ? 'italic' : 'normal',
        fontWeight: node.weight, fontSize: node.size * scale, color: node.color,
        textAlign: node.align,
        display: 'flex', alignItems: 'center',
        justifyContent: node.align === 'center' ? 'center' : node.align === 'right' ? 'flex-end' : 'flex-start',
        lineHeight: 1.18, whiteSpace: 'pre-wrap', letterSpacing: '-0.005em',
      }}>
        <span style={{ width: '100%', textAlign: node.align }}>{node.text}</span>
      </div>
    );
  }
  if (node.type === 'image') {
    return (
      <div style={{
        ...baseStyle,
        borderRadius: node.clip === 'circle' ? '50%' : (node.radius || 0) * scale,
        border: node.borderW ? `${node.borderW * scale}px solid ${node.borderC}` : 'none',
        overflow: 'hidden', background: '#eee',
      }}>
        <ThumbSVG tone={node.tone} />
      </div>
    );
  }
  if (node.type === 'icon') {
    const G = ICON_GLYPHS[node.glyph] || ICON_GLYPHS.heart;
    return (
      <div style={{
        ...baseStyle,
        background: node.plate, borderRadius: (node.radius || 0) * scale,
        border: node.borderW ? `${node.borderW * scale}px solid ${node.borderC}` : 'none',
        display: 'grid', placeItems: 'center',
      }}>
        <svg viewBox="0 0 24 24" width="60%" height="60%" fill={node.tint} stroke={node.tint} strokeLinejoin="round" strokeWidth="0.5">{G}</svg>
      </div>
    );
  }
  if (node.type === 'divider') {
    return (
      <div style={baseStyle}>
        <DividerSVG style={node.style} color={node.color} thickness={node.thickness} w={node.w * scale} h={node.h * scale} />
      </div>
    );
  }
  if (node.type === 'link') {
    return (
      <div style={{
        ...baseStyle,
        background: node.bg, color: node.textColor,
        borderRadius: (node.radius || 0) * scale,
        border: node.borderW ? `${node.borderW * scale}px solid ${node.borderC}` : 'none',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontFamily: FONT_OPTIONS.fraunces,
        fontStyle: 'italic', fontWeight: 600, fontSize: 16 * scale,
        boxShadow: node.borderW ? `0 ${2 * scale}px 0 ${node.borderC}` : 'none',
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        paddingLeft: 8 * scale, paddingRight: 8 * scale,
      }}>
        {node.text}
      </div>
    );
  }
  if (node.type === 'gallery') {
    return (
      <div style={{
        ...baseStyle,
        borderRadius: (node.radius || 0) * scale,
        border: node.borderW ? `${node.borderW * scale}px solid ${node.borderC}` : 'none',
        overflow: 'hidden', display: 'grid',
        gridTemplateColumns: 'repeat(2, 1fr)', gridTemplateRows: 'repeat(2, 1fr)',
        gap: (node.gap || 0) * scale,
      }}>
        {node.tones.map((t, i) => (
          <div key={i} style={{ overflow: 'hidden', borderRadius: 6 * scale }}>
            <ThumbSVG tone={t} />
          </div>
        ))}
      </div>
    );
  }
  if (node.type === 'container') {
    return (<div style={{
      ...baseStyle, background: node.bg, borderRadius: (node.radius || 0) * scale,
      border: node.borderW ? `${node.borderW * scale}px solid ${node.borderC}` : 'none',
    }} />);
  }
  if (node.type === 'carousel') {
    return (
      <div style={{
        ...baseStyle, background: node.bg, borderRadius: (node.radius || 0) * scale,
        border: node.borderW ? `${node.borderW * scale}px solid ${node.borderC}` : 'none',
        display: 'flex', alignItems: 'center', gap: 8 * scale, padding: 8 * scale, overflow: 'hidden',
      }}>
        {[0,1,2,3].map(i => (
          <div key={i} style={{
            flex: `0 0 ${88 * scale}px`, height: '80%', borderRadius: 8 * scale,
            background: i === 0 ? '#FFE3EC' : i === 1 ? '#D8E9C9' : i === 2 ? '#FBE9A8' : '#D9E5F5',
            border: `1px solid #1A140E`,
          }} />
        ))}
      </div>
    );
  }
  return null;
}

// Render a template into a fixed-size box at given scale.
// W/H are the canvas dimensions (320x660). The wrapper gets the scaled size.
function TplCanvas({ tpl, scale }) {
  const W = CANVAS_W, H = CANVAS_H;
  return (
    <div style={{
      position: 'relative',
      width: W * scale, height: H * scale,
      overflow: 'hidden',
      background: tpl.bgColor,
      isolation: 'isolate',
    }}>
      {tpl.bgImage && (
        <div style={{
          position: 'absolute', inset: 0, pointerEvents: 'none',
          backgroundImage: tpl.bgImage,
          backgroundSize: tpl.bgImageSize === 'tile'
            ? `${(40 * scale)}px ${(40 * scale)}px`
            : 'cover',
          backgroundRepeat: tpl.bgImageSize === 'tile' ? 'repeat' : 'no-repeat',
          backgroundPosition: 'center',
          opacity: tpl.bgImageOpacity ?? 1,
        }} />
      )}
      {/* paper grain */}
      <div style={{
        position: 'absolute', inset: 0, pointerEvents: 'none',
        opacity: 0.18, mixBlendMode: 'multiply',
        backgroundImage: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='240' height='240'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 0.10  0 0 0 0 0.08  0 0 0 0 0.05  0 0 0 .25 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>")`,
      }} />
      {tpl.order.map(id => <TplNode key={id} node={tpl.nodes[id]} scale={scale} />)}
    </div>
  );
}

// Mini iPhone bezel for the picker thumbnails.
function MiniDevice({ children, scale }) {
  const W = CANVAS_W * scale, H = CANVAS_H * scale;
  return (
    <div style={{
      width: W + 16, height: H + 16,
      borderRadius: 28 * scale + 8,
      padding: 5,
      background: '#1A140E',
      boxShadow: '0 18px 40px rgba(0,0,0,0.18), inset 0 0 0 1.2px #2a2118',
      position: 'relative',
    }}>
      {/* speaker */}
      <div style={{
        position: 'absolute', top: 10, left: '50%', transform: 'translateX(-50%)',
        width: 50, height: 11, borderRadius: 6, background: '#000', zIndex: 5,
      }} />
      <div style={{
        width: '100%', height: '100%',
        borderRadius: 22 * scale + 4,
        overflow: 'hidden',
        background: '#fff',
      }}>
        {children}
      </div>
    </div>
  );
}

// Single template card in the picker grid.
function TemplateCard({ tpl, palette, onPreview, onUse }) {
  const scale = 0.62;
  return (
    <div style={{
      display: 'flex', flexDirection: 'column', gap: 10,
      padding: 14,
      borderRadius: 18,
      background: palette.card,
      border: `1px solid ${palette.rule}`,
      boxShadow: '0 1px 0 rgba(0,0,0,0.02)',
      transition: 'transform .14s ease, box-shadow .14s ease',
      cursor: 'pointer',
    }}
      onClick={onPreview}
      onMouseEnter={(e) => {
        e.currentTarget.style.transform = 'translateY(-2px)';
        e.currentTarget.style.boxShadow = `0 12px 28px rgba(0,0,0,0.10), 0 2px 0 ${palette.accent}`;
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.transform = 'none';
        e.currentTarget.style.boxShadow = '0 1px 0 rgba(0,0,0,0.02)';
      }}
    >
      {/* thumbnail */}
      <div style={{
        alignSelf: 'center',
        position: 'relative',
        padding: 4,
      }}>
        <MiniDevice scale={scale}>
          <TplCanvas tpl={tpl} scale={scale} />
        </MiniDevice>
      </div>

      {/* meta strip */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 2 }}>
        {tpl.swatch.map((c, i) => (
          <span key={i} style={{
            width: 11, height: 11, borderRadius: 6, background: c,
            border: `1px solid ${palette.rule}`,
          }} />
        ))}
        <span style={{ flex: 1 }} />
        <span style={{
          fontFamily: MONO_FONT, fontSize: 8.5, letterSpacing: '0.16em',
          textTransform: 'uppercase', color: palette.inkFaded, fontWeight: 700,
        }}>0{tpl.idx}</span>
      </div>

      <div>
        <div style={{
          fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
          fontSize: 18, fontWeight: 600, color: palette.ink, lineHeight: 1.05,
        }}>{tpl.name}</div>
        <div style={{
          fontFamily: BODY_FONT, fontSize: 11.5, color: palette.inkFaded,
          marginTop: 3, letterSpacing: '0.01em',
        }}>{tpl.vibe}</div>
      </div>

      {/* actions */}
      <div style={{ display: 'flex', gap: 8, marginTop: 2 }}>
        <button
          onClick={(e) => { e.stopPropagation(); onPreview(); }}
          style={{
            flex: 1, height: 34, borderRadius: 17,
            background: 'transparent', border: `1px solid ${palette.rule}`,
            color: palette.ink, cursor: 'pointer',
            fontFamily: BODY_FONT, fontSize: 12.5, fontWeight: 600,
          }}
        >Preview</button>
        <button
          onClick={(e) => { e.stopPropagation(); onUse(); }}
          style={{
            flex: 1, height: 34, borderRadius: 17,
            background: palette.ink, color: palette.card, border: 'none',
            cursor: 'pointer',
            fontFamily: BODY_FONT, fontSize: 12.5, fontWeight: 600,
            boxShadow: `0 2px 0 ${palette.accent}`,
          }}
        >Use this</button>
      </div>
    </div>
  );
}

// Fullscreen preview overlay — large iPhone bezel, sticky header w/ Use button.
function TemplatePreview({ tpl, palette, onClose, onUse }) {
  if (!tpl) return null;
  // Big-but-fits scale: ~1.05 so the device is a bit larger than the editor's.
  const scale = 1.05;
  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 400,
        background: 'rgba(15,10,8,0.55)',
        backdropFilter: 'blur(8px)',
        display: 'flex', flexDirection: 'column',
        animation: 'fadeIn .15s ease',
      }}
    >
      {/* header */}
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          display: 'flex', alignItems: 'center', gap: 14,
          padding: '14px 22px',
          background: palette.paper,
          borderBottom: `1px solid ${palette.rule}`,
        }}
      >
        <button onClick={onClose} style={{
          height: 34, padding: '0 14px', borderRadius: 17,
          background: palette.card, border: `1px solid ${palette.rule}`,
          color: palette.ink, cursor: 'pointer',
          fontFamily: BODY_FONT, fontSize: 13, fontWeight: 600,
          display: 'inline-flex', alignItems: 'center', gap: 6,
        }}>← Back to templates</button>

        <span style={{ flex: 1 }} />

        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 2 }}>
          <span style={{
            fontFamily: MONO_FONT, fontSize: 9.5, letterSpacing: '0.18em',
            textTransform: 'uppercase', color: palette.inkFaded,
          }}>Preview · 0{tpl.idx} of {TEMPLATES.length}</span>
          <span style={{
            fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
            fontSize: 18, fontWeight: 600, color: palette.ink, lineHeight: 1,
          }}>{tpl.name}</span>
        </div>

        <span style={{ flex: 1 }} />

        <button
          onClick={(e) => { e.stopPropagation(); onUse(); }}
          style={{
            height: 36, padding: '0 18px', borderRadius: 18,
            background: palette.ink, color: palette.card, border: 'none',
            cursor: 'pointer', fontFamily: BODY_FONT, fontSize: 13.5, fontWeight: 600,
            boxShadow: `0 2px 0 ${palette.accent}`,
            display: 'inline-flex', alignItems: 'center', gap: 8,
          }}
        >
          Use this template
          <span style={{ fontFamily: MONO_FONT, fontSize: 10, opacity: .7, letterSpacing: '.06em' }}>↗</span>
        </button>
      </div>

      {/* stage */}
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          flex: 1, display: 'grid',
          gridTemplateColumns: '1fr minmax(360px, 380px) 1fr',
          alignItems: 'center', justifyItems: 'center',
          padding: '24px',
          overflow: 'auto',
        }}
      >
        {/* left annotation rail */}
        <div style={{
          maxWidth: 280, justifySelf: 'end', paddingRight: 24,
          color: palette.card, opacity: 0.85, textAlign: 'right',
        }}>
          <div style={{
            fontFamily: MONO_FONT, fontSize: 10, letterSpacing: '0.18em',
            textTransform: 'uppercase', marginBottom: 8, opacity: .7,
          }}>Vibe</div>
          <div style={{
            fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
            fontSize: 28, fontWeight: 500, lineHeight: 1.05, marginBottom: 18,
          }}>{tpl.vibe}</div>

          <div style={{
            fontFamily: MONO_FONT, fontSize: 10, letterSpacing: '0.18em',
            textTransform: 'uppercase', marginBottom: 8, opacity: .7,
          }}>Palette</div>
          <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end', marginBottom: 18 }}>
            {tpl.swatch.map((c, i) => (
              <span key={i} style={{
                width: 22, height: 22, borderRadius: 11, background: c,
                border: '1px solid rgba(255,255,255,0.4)',
              }} />
            ))}
          </div>

          <div style={{
            fontFamily: BODY_FONT, fontSize: 12.5, lineHeight: 1.5,
          }}>
            All copy, photos &amp; links are placeholders.<br/>
            Tap any block in the editor to fill in your own.
          </div>
        </div>

        {/* device */}
        <div style={{ position: 'relative' }}>
          <MiniDevice scale={scale}>
            <TplCanvas tpl={tpl} scale={scale} />
          </MiniDevice>
        </div>

        {/* right rail — what you can edit */}
        <div style={{
          maxWidth: 280, justifySelf: 'start', paddingLeft: 24,
          color: palette.card, opacity: 0.9,
        }}>
          <div style={{
            fontFamily: MONO_FONT, fontSize: 10, letterSpacing: '0.18em',
            textTransform: 'uppercase', marginBottom: 8, opacity: .7,
          }}>Replace</div>
          <ul style={{
            margin: 0, padding: 0, listStyle: 'none',
            fontFamily: BODY_FONT, fontSize: 13.5, lineHeight: 1.7,
          }}>
            {[
              ['◐', 'Profile photo'],
              ['Aa', 'Your name & bio'],
              ['⟿', 'Your links'],
              ['▦', 'Photo gallery'],
              ['✦', 'Icon row'],
            ].map(([g, l], i) => (
              <li key={i} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <span style={{
                  width: 26, height: 26, borderRadius: 8,
                  background: 'rgba(255,255,255,0.12)',
                  border: '1px solid rgba(255,255,255,0.2)',
                  display: 'grid', placeItems: 'center',
                  fontFamily: g === 'Aa' ? FONT_OPTIONS.fraunces : BODY_FONT,
                  fontStyle: g === 'Aa' ? 'italic' : 'normal',
                  fontSize: 13, fontWeight: 600, color: '#fff',
                }}>{g}</span>
                {l}
              </li>
            ))}
          </ul>

          <div style={{
            marginTop: 22, padding: '12px 14px',
            border: '1px dashed rgba(255,255,255,0.3)', borderRadius: 12,
            fontFamily: FONT_OPTIONS.caveat, fontSize: 17, lineHeight: 1.2,
            color: 'rgba(255,255,255,0.85)',
          }}>
            tip · keep the layout, swap the words.<br/>
            it's already cute.
          </div>
        </div>
      </div>
    </div>
  );
}

// The picker sheet (modal). open prop drives visibility.
function TemplatesPicker({ open, palette, onClose, onApply }) {
  const [previewIdx, setPreviewIdx] = useState_TP(null);

  useEffect_TP(() => {
    if (!open) setPreviewIdx(null);
    const onKey = (e) => {
      if (e.key === 'Escape') {
        if (previewIdx != null) setPreviewIdx(null);
        else onClose();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, previewIdx, onClose]);

  if (!open) return null;

  const list = TEMPLATES.map((t, i) => ({ ...t, idx: i + 1 }));
  const previewTpl = previewIdx != null ? list[previewIdx] : null;

  return (
    <>
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 300,
        background: 'rgba(20,15,10,0.42)',
        backdropFilter: 'blur(6px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 24,
        animation: 'fadeIn .15s ease',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: 'min(1180px, 100%)',
          maxHeight: '92vh',
          background: palette.paper,
          border: `1px solid ${palette.rule}`,
          borderRadius: 22,
          boxShadow: '0 30px 80px rgba(0,0,0,0.22)',
          overflow: 'hidden',
          display: 'flex', flexDirection: 'column',
        }}
      >
        {/* header */}
        <div style={{
          padding: '18px 24px',
          display: 'flex', alignItems: 'center', gap: 14,
          borderBottom: `1px solid ${palette.rule}`,
          background: palette.card,
        }}>
          <div style={{
            width: 38, height: 38, borderRadius: 11,
            background: 'conic-gradient(from 0deg, #FFE5EE, #FBF8F2, #0E0A14, #F2EEE3, #1B1B66, #FFE5EE)',
            border: `1.5px solid ${palette.ink}`,
          }}/>
          <div>
            <div style={{
              fontFamily: MONO_FONT, fontSize: 9.5, letterSpacing: '0.18em',
              textTransform: 'uppercase', color: palette.inkFaded, marginBottom: 2,
            }}>Templates</div>
            <div style={{
              fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
              fontSize: 22, fontWeight: 600, color: palette.ink, lineHeight: 1,
            }}>start from a template</div>
          </div>
          <span style={{ flex: 1 }}/>
          <span style={{
            fontFamily: BODY_FONT, fontSize: 12.5, color: palette.inkSoft,
            maxWidth: 320, textAlign: 'right', lineHeight: 1.4,
          }}>
            pick a vibe, fill in your name &amp; links, you're done.<br/>
            <span style={{ color: palette.inkFaded }}>everything stays editable after.</span>
          </span>
          <button onClick={onClose} style={{
            height: 32, width: 32, borderRadius: 16,
            border: `1px solid ${palette.rule}`, background: palette.cardSoft,
            color: palette.ink, fontFamily: BODY_FONT, fontSize: 14,
            cursor: 'pointer', display: 'grid', placeItems: 'center',
          }}>✕</button>
        </div>

        {/* body grid */}
        <div style={{
          flex: 1, overflowY: 'auto', padding: 24,
          background: palette.paper,
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))',
          gap: 16,
          alignItems: 'start',
        }}>
          {list.map((tpl, i) => (
            <TemplateCard
              key={tpl.id}
              tpl={tpl}
              palette={palette}
              onPreview={() => setPreviewIdx(i)}
              onUse={() => { onApply(tpl); onClose(); }}
            />
          ))}
        </div>

        {/* footer */}
        <div style={{
          padding: '12px 24px',
          background: palette.card,
          borderTop: `1px solid ${palette.rule}`,
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          fontFamily: MONO_FONT, fontSize: 10, color: palette.inkFaded,
          letterSpacing: '0.1em', textTransform: 'uppercase',
        }}>
          <span>{TEMPLATES.length} TEMPLATES · MORE COMING</span>
          <span>TAP A CARD TO PREVIEW · ESC TO CLOSE</span>
          <span>v0.5.0 · TEMPLATES</span>
        </div>
      </div>
    </div>

    {previewTpl && (
      <TemplatePreview
        tpl={previewTpl}
        palette={palette}
        onClose={() => setPreviewIdx(null)}
        onUse={() => { onApply(previewTpl); onClose(); }}
      />
    )}
    </>
  );
}

Object.assign(window, { TemplatesPicker, TplCanvas, MiniDevice });
