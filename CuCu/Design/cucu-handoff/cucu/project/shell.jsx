// shell.jsx — desk surface, device frame, side dock, and add-tray
const { useState: useState_S } = React;

function SideDock({ palette, selectedID, onAction }) {
  const tools = [
    { k: 'pointer', label: 'Move',   glyph: '↖' },
    { k: 'frame',   label: 'Frame',  glyph: '⌗' },
    { k: 'paint',   label: 'Paint',  glyph: '◐' },
    { k: 'text',    label: 'Text',   glyph: 'Aa' },
    { k: 'layers',  label: 'Layers', glyph: '☰' },
  ];
  const [active, setActive] = useState_S('pointer');

  return (
    <div style={{
      display: 'flex', flexDirection: 'column', gap: 4,
      padding: 8, borderRadius: 18,
      background: palette.card,
      border: `1px solid ${palette.rule}`,
      boxShadow: '0 6px 18px rgba(0,0,0,0.05)',
    }}>
      {tools.map(t => {
        const isActive = active === t.k;
        return (
          <button
            key={t.k}
            onClick={() => setActive(t.k)}
            style={{
              width: 44, height: 44,
              borderRadius: 12,
              background: isActive ? palette.ink : 'transparent',
              color: isActive ? palette.card : palette.inkSoft,
              border: 'none', cursor: 'pointer',
              display: 'grid', placeItems: 'center',
              fontFamily: t.k === 'text' ? FONT_OPTIONS.fraunces : BODY_FONT,
              fontSize: t.k === 'text' ? 18 : 16,
              fontWeight: 600, fontStyle: t.k === 'text' ? 'italic' : 'normal',
              transition: 'background .15s, color .15s',
            }}
            title={t.label}
          >{t.glyph}</button>
        );
      })}
      <div style={{ height: 1, background: palette.rule, margin: '4px 6px' }} />
      <button
        style={{
          width: 44, height: 44, borderRadius: 12,
          background: palette.accent, color: palette.card,
          border: 'none', cursor: 'pointer',
          display: 'grid', placeItems: 'center',
          fontSize: 22, fontWeight: 600, lineHeight: 1,
        }}
        title="Add Block"
      >+</button>
    </div>
  );
}

function TopBar({ palette, profileName, onUndo, onRedo, onPublish, onTheme, currentThemeID }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14,
      padding: '14px 22px',
      background: palette.paper,
      borderBottom: `1px solid ${palette.rule}`,
    }}>
      {/* logo */}
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <span style={{
          fontFamily: FONT_OPTIONS.caprasimo, fontSize: 22, color: palette.accent,
        }}>cucu</span>
        <span style={{
          fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.18em',
          textTransform: 'uppercase', color: palette.inkFaded,
        }}>Studio</span>
      </div>

      <div style={{ height: 22, width: 1, background: palette.rule, margin: '0 4px' }} />

      {/* breadcrumb */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, whiteSpace: 'nowrap' }}>
        <span style={{ fontFamily: BODY_FONT, fontSize: 13, color: palette.inkSoft }}>your profile</span>
        <span style={{ color: palette.inkFaded }}>/</span>
        <span style={{
          fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
          fontSize: 16, color: palette.ink, fontWeight: 600,
        }}>{profileName}</span>
        <button style={{
          background: 'transparent', border: 'none', color: palette.inkFaded,
          cursor: 'pointer', fontSize: 13, padding: 2,
        }}>✎</button>
      </div>

      <span style={{ flex: 1 }} />

      {/* status */}
      <span style={{
        fontFamily: MONO_FONT, fontSize: 10, color: palette.moss,
        display: 'inline-flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap',
      }}>
        <span style={{ width: 6, height: 6, borderRadius: 3, background: palette.moss }} />
        SAVED · 2:14 PM
      </span>

      {/* undo / redo */}
      <div style={{ display: 'flex', gap: 4, marginLeft: 8 }}>
        {['↺', '↻'].map((g, i) => (
          <button key={i}
            style={{
              width: 32, height: 32, borderRadius: 8,
              background: palette.card, border: `1px solid ${palette.rule}`,
              color: palette.inkSoft, cursor: 'pointer',
              fontSize: 14, padding: 0,
            }}>{g}</button>
        ))}
      </div>

      {/* theme */}
      <button onClick={onTheme} style={{
        height: 34, padding: '0 12px 0 10px', borderRadius: 17,
        background: palette.card, border: `1px solid ${palette.rule}`,
        color: palette.ink, cursor: 'pointer',
        fontFamily: BODY_FONT, fontSize: 13, fontWeight: 600,
        display: 'inline-flex', alignItems: 'center', gap: 8,
      }}>
        <span style={{
          width: 16, height: 16, borderRadius: 8,
          background: 'conic-gradient(from 0deg, #F8E0D2, #FBE9A8, #D8E9C9, #D9E5F5, #F5C9D4, #F8E0D2)',
          border: `1px solid ${palette.ink}`,
          display: 'inline-block',
        }}/>
        Theme
        {currentThemeID && (
          <span style={{
            fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.12em',
            textTransform: 'uppercase', color: palette.inkFaded,
            paddingLeft: 4, borderLeft: `1px solid ${palette.rule}`,
          }}>{currentThemeID === 'custom' ? 'CUSTOM' : THEMES[currentThemeID]?.name?.split(' ')[0] || ''}</span>
        )}
      </button>

      {/* preview */}
      <button style={{
        height: 34, padding: '0 14px', borderRadius: 17,
        background: palette.card, border: `1px solid ${palette.rule}`,
        color: palette.ink, cursor: 'pointer',
        fontFamily: BODY_FONT, fontSize: 13, fontWeight: 600,
      }}>Preview</button>

      {/* publish */}
      <button onClick={onPublish} style={{
        height: 34, padding: '0 16px', borderRadius: 17,
        background: palette.ink, color: palette.card, border: 'none',
        cursor: 'pointer', fontFamily: BODY_FONT, fontSize: 13, fontWeight: 600,
        display: 'inline-flex', alignItems: 'center', gap: 8,
        boxShadow: `0 2px 0 ${palette.accent}`,
      }}>
        Publish
        <span style={{ fontFamily: MONO_FONT, fontSize: 9.5, opacity: .7, letterSpacing: '.06em' }}>↗</span>
      </button>
    </div>
  );
}

// "rolling" add-tray on the right
function AddTray({ palette, onAdd }) {
  return (
    <div style={{
      display: 'flex', flexDirection: 'column', gap: 6,
      padding: 10, borderRadius: 18,
      background: palette.card,
      border: `1px solid ${palette.rule}`,
      boxShadow: '0 6px 18px rgba(0,0,0,0.05)',
      width: 88,
    }}>
      <div style={{
        fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.16em',
        textTransform: 'uppercase', color: palette.inkFaded,
        textAlign: 'center', padding: '2px 0 6px',
      }}>Add</div>
      {NODE_TYPES.map(t => (
        <button key={t} onClick={() => onAdd(t)}
          style={{
            display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2,
            padding: '8px 6px',
            borderRadius: 12,
            background: 'transparent',
            border: `1px dashed ${palette.rule}`,
            color: palette.inkSoft, cursor: 'pointer',
          }}>
          <span style={{
            fontFamily: t === 'text' ? FONT_OPTIONS.fraunces : BODY_FONT,
            fontStyle: t === 'text' ? 'italic' : 'normal',
            fontSize: 18, color: palette.ink, lineHeight: 1,
          }}>{NODE_GLYPHS[t]}</span>
          <span style={{
            fontFamily: BODY_FONT, fontSize: 10, color: palette.inkSoft,
          }}>{NODE_LABELS[t]}</span>
        </button>
      ))}
    </div>
  );
}

// device frame (custom — nicer for our context than the iOS starter)
function DeviceFrame({ palette, children, hint, scale = 0.72 }) {
  const W = 320, H = 660;
  return (
    <div style={{
      width: W * scale, height: H * scale,
      flex: '0 0 auto', position: 'relative',
    }}>
    <div style={{
      position: 'absolute', top: 0, left: 0,
      width: W, height: H,
      transform: `scale(${scale})`,
      transformOrigin: 'top left',
      borderRadius: 44,
      padding: 9,
      background: palette.ink,
      boxShadow: `
        0 30px 60px rgba(0,0,0,.18),
        inset 0 0 0 1.5px ${palette.inkSoft},
        inset 0 0 0 4px ${palette.ink}
      `,
    }}>
      {/* speaker */}
      <div style={{
        position: 'absolute', top: 18, left: '50%', transform: 'translateX(-50%)',
        width: 86, height: 20, borderRadius: 11, background: '#000',
      }} />

      {/* screen */}
      <div style={{
        position: 'relative',
        width: '100%', height: '100%',
        borderRadius: 38,
        overflow: 'hidden',
        background: palette.card,
      }}>
        {/* status bar */}
        <div style={{
          position: 'absolute', top: 0, left: 0, right: 0, height: 44,
          display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between',
          padding: '0 24px 4px', zIndex: 5,
          fontFamily: BODY_FONT, fontSize: 14, fontWeight: 600,
          color: palette.ink,
          pointerEvents: 'none',
        }}>
          <span>9:41</span>
          <span style={{ display: 'inline-flex', gap: 6, alignItems: 'center' }}>
            {/* signal bars */}
            <svg width="17" height="11" viewBox="0 0 17 11" fill={palette.ink}>
              <rect x="0" y="7" width="3" height="4" rx="0.5"/>
              <rect x="4.5" y="5" width="3" height="6" rx="0.5"/>
              <rect x="9" y="2.5" width="3" height="8.5" rx="0.5"/>
              <rect x="13.5" y="0" width="3" height="11" rx="0.5"/>
            </svg>
            {/* wifi */}
            <svg width="15" height="11" viewBox="0 0 15 11" fill="none" stroke={palette.ink} strokeWidth="1.4" strokeLinecap="round">
              <path d="M1 4 C 4.5 1, 10.5 1, 14 4"/>
              <path d="M3 6.4 C 5.4 4.5, 9.6 4.5, 12 6.4"/>
              <path d="M5 8.6 C 6.3 7.6, 8.7 7.6, 10 8.6"/>
              <circle cx="7.5" cy="10" r="0.6" fill={palette.ink}/>
            </svg>
            {/* battery */}
            <span style={{
              display: 'inline-block', width: 22, height: 11, border: `1.5px solid ${palette.ink}`,
              borderRadius: 3, position: 'relative', marginLeft: 1,
            }}>
              <span style={{ position: 'absolute', top: 1, bottom: 1, left: 1, width: 12, background: palette.ink, borderRadius: 1 }} />
              <span style={{ position: 'absolute', right: -3.5, top: 3, bottom: 3, width: 1.5, background: palette.ink, borderRadius: 1 }} />
            </span>
          </span>
        </div>

        {children}

        {hint}
      </div>
    </div>
    </div>
  );
}

Object.assign(window, { SideDock, TopBar, AddTray, DeviceFrame });
