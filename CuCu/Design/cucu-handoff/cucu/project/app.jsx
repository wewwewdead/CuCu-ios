// app.jsx — main entrypoint, holds doc state, palette, tweaks
const { useState: useState_A, useEffect: useEffect_A, useMemo: useMemo_A } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "palette": "cream",
  "displayFont": "fraunces",
  "background": "warmPeach",
  "ornament": "sparkles",
  "density": "comfy",
  "showLayersSidebar": false,
  "showWisdom": true
}/*EDITMODE-END*/;

// Background presets
const BG_PRESETS = {
  warmPeach: { color: '#F8E0D2' },
  butter:    { color: '#FBE9A8' },
  sage:      { color: '#D8E9C9' },
  paperCream:{ color: '#FBF6E9' },
  duskRose:  { color: '#E5C4D0' },
  inkNight:  { color: '#1B1923' },
};

// little wisdom strings for the bottom hint
const WISDOM = [
  "tip · long-press a node to lock it",
  "tip · ⌘D duplicates with the same offset",
  "tip · drop colors right onto a node",
  "tip · sparkle dividers love italic captions",
];

function App() {
  const [tweaks, setTweaksState] = useState_A(TWEAK_DEFAULTS);
  const [themeSheetOpen, setThemeSheetOpen] = useState_A(false);
  const [currentThemeID, setCurrentThemeID] = useState_A('peachCottage');
  const setTweak = (k, v) => {
    const edits = typeof k === 'object' ? k : { [k]: v };
    setTweaksState(prev => ({ ...prev, ...edits }));
    try {
      window.parent.postMessage({ type: '__edit_mode_set_keys', edits }, '*');
    } catch (e) {}
  };

  const palette = PALETTES[tweaks.palette] || PALETTES.cream;
  const fonts = FONT_OPTIONS;

  // doc state
  const [doc, setDoc] = useState_A(() => makeDoc());
  const [selectedID, setSelectedID] = useState_A('header');

  // apply background tweak to doc bg
  useEffect_A(() => {
    const bg = BG_PRESETS[tweaks.background]?.color;
    if (bg) setDoc(d => ({ ...d, bgColor: bg }));
  }, [tweaks.background]);

  // apply font tweak to text nodes that haven't been individually overridden recently
  // (simplified: just push to header / bio so the tweak is visible)
  useEffect_A(() => {
    setDoc(d => {
      const next = { ...d, nodes: { ...d.nodes } };
      ['header', 'bio'].forEach(id => {
        if (next.nodes[id]) next.nodes[id] = { ...next.nodes[id], font: tweaks.displayFont };
      });
      return next;
    });
  }, [tweaks.displayFont]);

  const update = (patch) => {
    setDoc(d => ({
      ...d,
      nodes: { ...d.nodes, [selectedID]: { ...d.nodes[selectedID], ...patch } },
    }));
  };

  const node = selectedID ? doc.nodes[selectedID] : null;

  // Apply a theme: repaints profile defaults AND switches chrome palette
  const applyTheme = (id, theme) => {
    setCurrentThemeID(id);
    // chrome
    if (theme.chromeKey && PALETTES[theme.chromeKey]) {
      setTweak('palette', theme.chromeKey);
    }
    // font
    if (theme.profile?.headerFont) {
      setTweak('displayFont', theme.profile.headerFont);
    }
    // background
    const bgMatch = Object.entries(BG_PRESETS).find(
      ([_, v]) => v.color.toLowerCase() === (theme.profile.bgColor || '').toLowerCase()
    );
    if (bgMatch) setTweak('background', bgMatch[0]);
    // ornament tweak based on divider style
    const dividerToOrn = {
      sparkleChain: 'sparkles', heartChain: 'hearts',
      flowerChain: 'flowers', starChain: 'stars',
    };
    if (dividerToOrn[theme.profile.dividerStyle]) {
      setTweak('ornament', dividerToOrn[theme.profile.dividerStyle]);
    }
    // repaint profile
    setDoc(d => applyThemeToDoc(d, theme));
  };



  // Add a node
  const addNode = (type) => {
    const newId = idFor();
    const base = {
      id: newId, type, x: 70, y: 200, w: 180, h: 60, opacity: 1,
    };
    let n = base;
    if (type === 'text') n = { ...base, text: 'new caption', font: tweaks.displayFont, weight: 500, size: 22, color: '#3A1A1F', align: 'center', italic: false, bg: 'transparent', radius: 0, borderW: 0, borderC: '#1A140E', padding: 0 };
    else if (type === 'image') n = { ...base, w: 130, h: 130, radius: 12, borderW: 1.5, borderC: '#3A1A1F', clip: 'rect', tone: 'sage' };
    else if (type === 'icon') n = { ...base, w: 56, h: 56, glyph: 'sparkle', plate: '#FFE3EC', tint: '#B8324B', radius: 14, borderW: 1.5, borderC: '#3A1A1F' };
    else if (type === 'divider') n = { ...base, h: 22, style: 'sparkleChain', color: '#B8324B', thickness: 2 };
    else if (type === 'link') n = { ...base, w: 220, h: 44, text: 'new link', url: 'mira.cucu/x', variant: 'pill', bg: '#FBF6E9', textColor: '#3A1A1F', borderW: 1.5, borderC: '#3A1A1F', radius: 22 };
    else if (type === 'gallery') n = { ...base, w: 240, h: 110, tones: ['peach','sage','sky','butter'], layout: 'grid', gap: 6, fit: 'fill', radius: 12, borderW: 0, borderC: '#1A140E' };
    else if (type === 'carousel') n = { ...base, w: 260, h: 100, bg: '#FBF6E9', radius: 14, borderW: 1.5, borderC: '#3A1A1F' };
    else if (type === 'container') n = { ...base, w: 200, h: 140, bg: '#FBF6E9', radius: 16, borderW: 1.5, borderC: '#3A1A1F' };
    setDoc(d => ({
      ...d,
      nodes: { ...d.nodes, [newId]: n },
      order: [...d.order, newId],
    }));
    setSelectedID(newId);
  };

  const dark = tweaks.palette === 'dusk';

  return (
    <div style={{
      width: '100vw', minHeight: '100vh',
      background: palette.paper,
      backgroundImage: `
        radial-gradient(circle at 20% 20%, ${palette.paperDeep} 0, transparent 45%),
        radial-gradient(circle at 80% 90%, ${palette.paperDeep} 0, transparent 50%)
      `,
      fontFamily: BODY_FONT, color: palette.ink,
      display: 'flex', flexDirection: 'column',
      position: 'relative',
    }}>
      <TopBar
        palette={palette}
        profileName="mira"
        onTheme={() => setThemeSheetOpen(true)}
        currentThemeID={currentThemeID}
      />

      {/* main work area */}
      <div style={{
        flex: 1, position: 'relative',
        display: 'flex', flexDirection: 'column',
        gap: 14,
        padding: '14px 24px 18px',
      }}>
        {/* upper row: dock | device | tray */}
        <div style={{
          display: 'flex', gap: 18,
          alignItems: 'flex-start', justifyContent: 'center',
          flex: '0 0 auto',
        }}>
          {/* left dock */}
          <div style={{ alignSelf: 'flex-start', marginTop: 14 }}>
            <SideDock palette={palette} selectedID={selectedID} />
          </div>

          {/* center: device */}
          <div style={{
            flex: '0 0 auto',
            display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6,
            position: 'relative',
          }}>
            {/* annotation tag */}
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 6,
              fontFamily: MONO_FONT, fontSize: 9.5, color: palette.inkFaded,
              letterSpacing: '0.14em', textTransform: 'uppercase',
              alignSelf: 'flex-start', marginLeft: 4,
              whiteSpace: 'nowrap',
            }}>
              <span style={{
                width: 6, height: 6, borderRadius: 3, background: palette.accent,
              }} />
              Live · iPhone 14 · 393 × 852
            </div>

            <DeviceFrame palette={palette}>
              <Canvas
                doc={doc}
                selectedID={selectedID}
                onSelect={setSelectedID}
                palette={palette}
                fonts={fonts}
              />
            </DeviceFrame>
          </div>

          {/* right add tray */}
          <div style={{ alignSelf: 'flex-start', marginTop: 14 }}>
            <AddTray palette={palette} onAdd={addNode} />
          </div>
        </div>

        {/* bottom inspector dock — full-width below the device */}
        <div style={{ flex: '0 0 auto' }}>
          <InspectorDock
            node={node}
            palette={palette}
            update={update}
            onClose={() => setSelectedID(null)}
          />
          {tweaks.showWisdom && (
            <div style={{
              marginTop: 8, textAlign: 'center',
              fontFamily: FONT_OPTIONS.caveat, fontSize: 16, color: palette.inkFaded,
            }}>{WISDOM[0]}</div>
          )}
        </div>
      </div>

      {/* keyline / footer */}
      <div style={{
        padding: '10px 22px',
        borderTop: `1px solid ${palette.rule}`,
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        fontFamily: MONO_FONT, fontSize: 10, color: palette.inkFaded,
        letterSpacing: '0.1em', background: palette.paper,
      }}>
        <span>cucu.studio · v0.4.2 · build 2026.04</span>
        <span>node {selectedID || '—'} · {doc.order.length} blocks · zoom 100%</span>
        <span>⌘S to publish · ⌘Z to undo · ? for help</span>
      </div>

      {/* tweaks panel — self-managed open state */}
      <TweaksPanel title="Tweaks">
        <TweakSection label="Theme">
          <TweakRadio
            label="Palette"
            value={tweaks.palette}
            options={[
              { value: 'cream', label: 'Cream' },
              { value: 'mint', label: 'Mint' },
              { value: 'dusk', label: 'Dusk' },
            ]}
            onChange={(v) => setTweak('palette', v)}
          />
          <TweakSelect
            label="Display Font"
            value={tweaks.displayFont}
            options={[
              { value: 'fraunces', label: 'Fraunces' },
              { value: 'caprasimo', label: 'Caprasimo' },
              { value: 'lobster', label: 'Lobster' },
              { value: 'caveat', label: 'Caveat' },
              { value: 'patrick', label: 'Patrick Hand' },
              { value: 'yeseva', label: 'Yeseva One' },
            ]}
            onChange={(v) => setTweak('displayFont', v)}
          />
        </TweakSection>

        <TweakSection label="Profile Canvas">
          <TweakSelect
            label="Background"
            value={tweaks.background}
            options={[
              { value: 'warmPeach', label: 'Warm Peach' },
              { value: 'butter', label: 'Butter' },
              { value: 'sage', label: 'Sage' },
              { value: 'paperCream', label: 'Paper Cream' },
              { value: 'duskRose', label: 'Dusk Rose' },
              { value: 'inkNight', label: 'Ink Night' },
            ]}
            onChange={(v) => setTweak('background', v)}
          />
          <TweakRadio
            label="Density"
            value={tweaks.density}
            options={[
              { value: 'tight', label: 'Tight' },
              { value: 'comfy', label: 'Comfy' },
              { value: 'roomy', label: 'Roomy' },
            ]}
            onChange={(v) => setTweak('density', v)}
          />
        </TweakSection>

        <TweakSection label="Ornament">
          <TweakRadio
            label="Style"
            value={tweaks.ornament}
            options={[
              { value: 'sparkles', label: 'Sparkles' },
              { value: 'hearts', label: 'Hearts' },
              { value: 'flowers', label: 'Flowers' },
              { value: 'stars', label: 'Stars' },
            ]}
            onChange={(v) => {
              setTweak('ornament', v);
              setDoc(d => ({
                ...d,
                nodes: {
                  ...d.nodes,
                  div1: d.nodes.div1 ? {
                    ...d.nodes.div1,
                    style: { sparkles: 'sparkleChain', hearts: 'heartChain', flowers: 'flowerChain', stars: 'starChain' }[v]
                  } : d.nodes.div1,
                },
              }));
            }}
          />
        </TweakSection>

        <TweakSection label="Workspace">
          <TweakToggle
            label="Show wisdom strip"
            value={tweaks.showWisdom}
            onChange={(v) => setTweak('showWisdom', v)}
          />
          <TweakToggle
            label="Show layers sidebar"
            value={tweaks.showLayersSidebar}
            onChange={(v) => setTweak('showLayersSidebar', v)}
          />
        </TweakSection>
      </TweaksPanel>

      <ThemeSheet
        open={themeSheetOpen}
        onClose={() => setThemeSheetOpen(false)}
        currentThemeID={currentThemeID}
        onPick={(id, theme) => applyTheme(id, theme)}
        palette={palette}
        doc={doc}
        setDoc={setDoc}
      />
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
