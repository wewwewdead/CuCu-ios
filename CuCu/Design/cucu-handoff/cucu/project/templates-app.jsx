// templates-app.jsx — host app that shows the CuCu Studio shell with the
// Templates picker open, and lets users pick a template (which logs the
// selection to demonstrate the flow).
const { useState: useState_TA, useEffect: useEffect_TA } = React;

function TemplatesApp() {
  const palette = PALETTES.cream;
  const fonts = FONT_OPTIONS;

  const [pickerOpen, setPickerOpen] = useState_TA(true);
  const [appliedTpl, setAppliedTpl] = useState_TA(null);
  const [doc, setDoc] = useState_TA(() => makeDoc());

  const onApplyTemplate = (tpl) => {
    // Replace the current document with the template's nodes.
    setAppliedTpl(tpl);
    setDoc({
      bgColor: tpl.bgColor,
      bgImage: tpl.bgImage,
      bgImageSize: tpl.bgImageSize,
      bgImageOpacity: tpl.bgImageOpacity ?? 1,
      bgPattern: 'paper',
      nodes: tpl.nodes,
      order: tpl.order,
    });
  };

  return (
    <div style={{
      width: '100vw', minHeight: '100vh',
      background: palette.paper,
      backgroundImage: `radial-gradient(circle at 20% 20%, ${palette.paperDeep} 0, transparent 45%), radial-gradient(circle at 80% 90%, ${palette.paperDeep} 0, transparent 50%)`,
      fontFamily: BODY_FONT, color: palette.ink,
      display: 'flex', flexDirection: 'column', position: 'relative',
    }}>
      <TopBar
        palette={palette}
        profileName={appliedTpl ? appliedTpl.name.toLowerCase() : 'untitled'}
        onTheme={() => {}}
        currentThemeID={null}
      />

      {/* Subtle "templates ribbon" so users can re-open the picker */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '10px 24px',
        background: palette.cardSoft,
        borderBottom: `1px solid ${palette.rule}`,
      }}>
        <span style={{
          fontFamily: MONO_FONT, fontSize: 10, letterSpacing: '0.18em',
          textTransform: 'uppercase', color: palette.inkFaded, fontWeight: 700,
        }}>Templates</span>
        <span style={{
          fontFamily: FONT_OPTIONS.fraunces, fontStyle: 'italic',
          fontSize: 14, color: palette.ink,
        }}>
          {appliedTpl
            ? <>now using <strong style={{ fontStyle: 'normal' }}>{appliedTpl.name}</strong> — fill in the placeholders to make it yours.</>
            : <>browse 5 prebuilt looks. swap copy &amp; photos to make one yours in seconds.</>}
        </span>
        <span style={{ flex: 1 }} />
        <button
          onClick={() => setPickerOpen(true)}
          style={{
            height: 30, padding: '0 14px', borderRadius: 15,
            background: palette.ink, color: palette.card, border: 'none',
            cursor: 'pointer', fontFamily: BODY_FONT, fontSize: 12, fontWeight: 600,
            display: 'inline-flex', alignItems: 'center', gap: 8,
            boxShadow: `0 2px 0 ${palette.accent}`,
          }}
        >
          <span style={{ fontSize: 14, lineHeight: 1 }}>✦</span>
          {appliedTpl ? 'Browse templates' : 'Choose a template'}
        </button>
      </div>

      <div style={{ flex: 1, position: 'relative', display: 'flex', flexDirection: 'column', gap: 14, padding: '14px 24px 18px' }}>
        <div style={{ display: 'flex', gap: 18, alignItems: 'flex-start', justifyContent: 'center' }}>
          <div style={{ alignSelf: 'flex-start', marginTop: 14 }}>
            <SideDock palette={palette} selectedID={null} />
          </div>

          <div style={{ flex: '0 0 auto', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 6,
              fontFamily: MONO_FONT, fontSize: 9.5, color: palette.inkFaded,
              letterSpacing: '0.14em', textTransform: 'uppercase',
              alignSelf: 'flex-start', marginLeft: 4,
            }}>
              <span style={{ width: 6, height: 6, borderRadius: 3, background: palette.moss }} />
              Live · iPhone 14 · 393 × 852 · {appliedTpl ? appliedTpl.name : 'blank'}
            </div>

            <DeviceFrame palette={palette}>
              <Canvas
                doc={doc}
                selectedID={null}
                onSelect={() => {}}
                palette={palette}
                fonts={fonts}
              />
            </DeviceFrame>
          </div>

          <div style={{ alignSelf: 'flex-start', marginTop: 14 }}>
            <AddTray palette={palette} onAdd={() => {}} />
          </div>
        </div>

        <div style={{
          textAlign: 'center', fontFamily: FONT_OPTIONS.caveat, fontSize: 17,
          color: palette.inkFaded, marginTop: 4,
        }}>
          {appliedTpl
            ? `tip · tap any block in the template to replace its text or photo`
            : `tip · pick a template above to skip the blank canvas`}
        </div>
      </div>

      <div style={{
        padding: '10px 22px', borderTop: `1px solid ${palette.rule}`,
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        fontFamily: MONO_FONT, fontSize: 10, color: palette.inkFaded,
        letterSpacing: '0.1em', background: palette.paper,
      }}>
        <span>cucu.studio · v0.5.0 · templates</span>
        <span>{appliedTpl ? `template · ${appliedTpl.id}` : 'no template applied'} · {doc.order.length} blocks</span>
        <span>⌘N for new template · esc to close picker</span>
      </div>

      <TemplatesPicker
        open={pickerOpen}
        palette={palette}
        onClose={() => setPickerOpen(false)}
        onApply={onApplyTemplate}
      />

      <style>{`
        @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
      `}</style>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<TemplatesApp />);
