// inspector.jsx — bottom-sheet inspector that adapts to selected node type
const { useState: useState_I } = React;

// ─── reusable tool atoms ─────────────────────────────────────────
function ToolCard({ label, children, span = 1, palette, width }) {
  // span maps to a min-width for the horizontal tool rail
  const w = width ?? (span === 3 ? 260 : span === 2 ? 200 : 152);
  return (
    <div style={{
      flex: `0 0 ${w}px`,
      width: w,
      background: palette.card,
      border: `1px solid ${palette.rule}`,
      borderRadius: 12,
      padding: '8px 10px 10px',
      display: 'flex', flexDirection: 'column', gap: 6,
      minHeight: 76,
    }}>
      <div style={{
        fontFamily: MONO_FONT, fontSize: 9, letterSpacing: '0.14em',
        textTransform: 'uppercase', color: palette.inkFaded, fontWeight: 600,
      }}>{label}</div>
      {children}
    </div>
  );
}

function Pill({ active, onClick, children, palette, mono = false }) {
  return (
    <button
      onClick={onClick}
      style={{
        height: 32, padding: '0 12px',
        borderRadius: 16,
        border: `1px solid ${active ? palette.ink : palette.rule}`,
        background: active ? palette.ink : palette.cardSoft,
        color: active ? palette.card : palette.ink,
        fontFamily: mono ? MONO_FONT : BODY_FONT,
        fontSize: 12, fontWeight: 600, letterSpacing: mono ? '0.02em' : 0,
        cursor: 'pointer', whiteSpace: 'nowrap',
      }}
    >{children}</button>
  );
}

function Swatch({ color, active, onClick, palette, size = 28, ring = true }) {
  return (
    <button
      onClick={onClick}
      style={{
        width: size, height: size, borderRadius: '50%',
        background: color === 'transparent' ? `linear-gradient(135deg, ${palette.cardSoft} 50%, ${palette.rule} 50%)` : color,
        border: `2px solid ${active ? palette.ink : 'rgba(0,0,0,0)'}`,
        outline: ring ? `1px solid ${palette.rule}` : 'none',
        outlineOffset: 1,
        cursor: 'pointer', padding: 0,
      }}
    />
  );
}

function Slider({ label, value, min, max, step = 1, onChange, palette, suffix = '' }) {
  const pct = ((value - min) / (max - min)) * 100;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
        <span style={{ fontFamily: BODY_FONT, fontSize: 12, color: palette.inkSoft }}>{label}</span>
        <span style={{ fontFamily: MONO_FONT, fontSize: 11, color: palette.ink, fontWeight: 600 }}>{value}{suffix}</span>
      </div>
      <div style={{ position: 'relative', height: 22, display: 'flex', alignItems: 'center' }}>
        <div style={{ position: 'absolute', inset: '9px 0', borderRadius: 2, background: palette.rule }} />
        <div style={{ position: 'absolute', left: 0, top: 9, bottom: 9, width: `${pct}%`, background: palette.accent, borderRadius: 2 }} />
        <div style={{ position: 'absolute', left: `calc(${pct}% - 8px)`, width: 16, height: 16, borderRadius: 8, background: palette.card, border: `2px solid ${palette.ink}` }} />
        <input
          type="range" min={min} max={max} step={step} value={value}
          onChange={(e) => onChange(parseFloat(e.target.value))}
          style={{ position: 'absolute', inset: 0, opacity: 0, width: '100%', cursor: 'pointer' }}
        />
      </div>
    </div>
  );
}

function PillRow({ options, value, onChange, palette, mono = false }) {
  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
      {options.map(o => (
        <Pill key={o.v} active={o.v === value} onClick={() => onChange(o.v)} palette={palette} mono={mono}>
          {o.label}
        </Pill>
      ))}
    </div>
  );
}

// ─── COLOR PALETTES (per-node fills) ────────────────────────────
const NODE_FILLS = ['#FBF8EE', '#FFE3EC', '#FFF1B8', '#DDF1D5', '#D9E5F5', '#3A1A1F', '#B8324B', '#3F7A52', '#F5C9D4', 'transparent'];
const TEXT_COLORS = ['#3A1A1F', '#1A140E', '#B8324B', '#3F7A52', '#3A4D7C', '#FBF6E9'];
const ICON_PLATES = ['#FFE3EC', '#FFF1B8', '#DDF1D5', '#D9E5F5', '#F5C9D4', '#FBF6E9', '#3A1A1F'];

// ─── TYPE-SPECIFIC INSPECTORS ───────────────────────────────────

function TextInspector({ node, update, palette }) {
  return (
    <>
      <ToolCard label="Copy" span={3} palette={palette}>
        <textarea
          value={node.text}
          onChange={(e) => update({ text: e.target.value })}
          rows={2}
          style={{
            border: `1px solid ${palette.rule}`,
            borderRadius: 10,
            padding: '8px 10px',
            fontFamily: FONT_OPTIONS[node.font],
            fontSize: 14,
            fontStyle: node.italic ? 'italic' : 'normal',
            fontWeight: node.weight,
            color: palette.ink,
            background: palette.cardSoft,
            resize: 'none', outline: 'none',
          }}
        />
      </ToolCard>

      <ToolCard label="Typeface" span={2} palette={palette}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 6 }}>
          {Object.entries(FONT_OPTIONS).map(([k, v]) => {
            const active = node.font === k;
            const previewName = { fraunces: 'Aa', caprasimo: 'Aa', lobster: 'Aa', caveat: 'Aa', patrick: 'Aa', yeseva: 'Aa' }[k];
            const labelText = { fraunces: 'Fraunces', caprasimo: 'Caprasimo', lobster: 'Lobster', caveat: 'Caveat', patrick: 'Patrick', yeseva: 'Yeseva' }[k];
            return (
              <button
                key={k}
                onClick={() => update({ font: k })}
                style={{
                  border: `1px solid ${active ? palette.ink : palette.rule}`,
                  background: active ? palette.ink : palette.cardSoft,
                  color: active ? palette.card : palette.ink,
                  borderRadius: 10,
                  padding: '8px 4px 6px',
                  display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2,
                  cursor: 'pointer',
                }}
              >
                <span style={{ fontFamily: v, fontSize: 22, lineHeight: 1 }}>{previewName}</span>
                <span style={{ fontFamily: MONO_FONT, fontSize: 8.5, letterSpacing: '0.06em', opacity: .8 }}>{labelText.toUpperCase()}</span>
              </button>
            );
          })}
        </div>
      </ToolCard>

      <ToolCard label="Size & Weight" palette={palette}>
        <Slider label="Size" value={node.size} min={10} max={64} onChange={(v) => update({ size: v })} palette={palette} suffix="px" />
        <PillRow
          options={[{v:400,label:'Reg'},{v:500,label:'Med'},{v:700,label:'Bold'}]}
          value={node.weight}
          onChange={(v) => update({ weight: v })}
          palette={palette}
        />
      </ToolCard>

      <ToolCard label="Alignment" palette={palette}>
        <PillRow
          options={[{v:'left',label:'⇤'},{v:'center',label:'⇔'},{v:'right',label:'⇥'}]}
          value={node.align}
          onChange={(v) => update({ align: v })}
          palette={palette}
        />
        <Pill active={node.italic} onClick={() => update({ italic: !node.italic })} palette={palette}>
          <span style={{ fontStyle: 'italic', fontFamily: 'Georgia, serif' }}>Italic</span>
        </Pill>
      </ToolCard>

      <ToolCard label="Text Color" palette={palette}>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {TEXT_COLORS.map(c => <Swatch key={c} color={c} active={node.color === c} onClick={() => update({ color: c })} palette={palette} />)}
        </div>
      </ToolCard>
    </>
  );
}

function ImageInspector({ node, update, palette }) {
  const tones = ['peach', 'sage', 'sky', 'butter', 'rose'];
  return (
    <>
      <ToolCard label="Source" span={2} palette={palette}>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <div style={{
            width: 52, height: 52, borderRadius: node.clip === 'circle' ? '50%' : 10,
            border: `1px solid ${palette.rule}`, overflow: 'hidden', flex: '0 0 52px',
          }}>
            <ThumbSVG tone={node.tone} />
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6, flex: 1 }}>
            <div style={{ display: 'flex', gap: 6 }}>
              <Pill active palette={palette}>Replace</Pill>
              <Pill palette={palette}>Crop</Pill>
              <Pill palette={palette}>Filter</Pill>
            </div>
            <div style={{ fontFamily: MONO_FONT, fontSize: 10, color: palette.inkFaded }}>portrait_03.heic · 2048×2048</div>
          </div>
        </div>
      </ToolCard>

      <ToolCard label="Tone" palette={palette}>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {tones.map(t => (
            <button key={t} onClick={() => update({ tone: t })}
              style={{
                width: 30, height: 30, borderRadius: 8,
                border: `2px solid ${node.tone === t ? palette.ink : palette.rule}`,
                overflow: 'hidden', padding: 0, cursor: 'pointer',
              }}>
              <ThumbSVG tone={t} />
            </button>
          ))}
        </div>
      </ToolCard>

      <ToolCard label="Shape" palette={palette}>
        <PillRow
          options={[{v:'rect',label:'Rect'},{v:'circle',label:'Circle'}]}
          value={node.clip}
          onChange={(v) => update({ clip: v })}
          palette={palette}
        />
        {node.clip !== 'circle' && (
          <Slider label="Radius" value={node.radius} min={0} max={60} onChange={(v) => update({ radius: v })} palette={palette} suffix="px" />
        )}
      </ToolCard>

      <ToolCard label="Border" palette={palette}>
        <Slider label="Width" value={node.borderW} min={0} max={6} step={0.5} onChange={(v) => update({ borderW: v })} palette={palette} suffix="px" />
        <div style={{ display: 'flex', gap: 5 }}>
          {['#3A1A1F','#B8324B','#3F7A52','#FBF6E9'].map(c => <Swatch key={c} color={c} active={node.borderC === c} onClick={() => update({ borderC: c })} palette={palette} size={22} />)}
        </div>
      </ToolCard>

      <ToolCard label="Opacity" palette={palette}>
        <Slider label="Alpha" value={Math.round(node.opacity * 100)} min={0} max={100} onChange={(v) => update({ opacity: v / 100 })} palette={palette} suffix="%" />
      </ToolCard>
    </>
  );
}

function IconInspector({ node, update, palette }) {
  const glyphs = ['heart','star','flower','sparkle','bolt','bookmark','book','globe','camera','music','envelope','pin'];
  return (
    <>
      <ToolCard label="Glyph" span={3} palette={palette}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(12, 1fr)', gap: 4 }}>
          {glyphs.map(g => (
            <button key={g} onClick={() => update({ glyph: g })}
              style={{
                aspectRatio: '1/1',
                borderRadius: 8,
                border: `1px solid ${node.glyph === g ? palette.ink : palette.rule}`,
                background: node.glyph === g ? palette.ink : palette.cardSoft,
                color: node.glyph === g ? palette.card : palette.ink,
                display: 'grid', placeItems: 'center', cursor: 'pointer', padding: 4,
              }}>
              <svg viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor" stroke="currentColor" strokeWidth="0.5" strokeLinejoin="round">
                {ICON_GLYPHS[g]}
              </svg>
            </button>
          ))}
        </div>
      </ToolCard>

      <ToolCard label="Plate" palette={palette}>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {ICON_PLATES.map(c => <Swatch key={c} color={c} active={node.plate === c} onClick={() => update({ plate: c })} palette={palette} />)}
        </div>
      </ToolCard>

      <ToolCard label="Tint" palette={palette}>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {TEXT_COLORS.map(c => <Swatch key={c} color={c} active={node.tint === c} onClick={() => update({ tint: c })} palette={palette} />)}
        </div>
      </ToolCard>

      <ToolCard label="Shape" palette={palette}>
        <Slider label="Radius" value={node.radius} min={0} max={24} onChange={(v) => update({ radius: v })} palette={palette} suffix="px" />
      </ToolCard>
    </>
  );
}

function DividerInspector({ node, update, palette }) {
  const styles = [
    { v: 'solid', label: '———' },
    { v: 'dashed', label: '- - -' },
    { v: 'dotted', label: '· · ·' },
    { v: 'sparkleChain', label: '✦‿✦' },
    { v: 'heartChain', label: '♡‿♡' },
    { v: 'starChain', label: '★‿★' },
    { v: 'flowerChain', label: '✿‿✿' },
  ];
  return (
    <>
      <ToolCard label="Style" span={2} palette={palette}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 6 }}>
          {styles.map(s => {
            const active = node.style === s.v;
            return (
              <button key={s.v} onClick={() => update({ style: s.v })}
                style={{
                  border: `1px solid ${active ? palette.ink : palette.rule}`,
                  background: active ? palette.ink : palette.cardSoft,
                  borderRadius: 10, padding: 6, cursor: 'pointer',
                  display: 'grid', placeItems: 'center', height: 34,
                }}>
                <div style={{ width: '100%', color: active ? palette.card : palette.ink }}>
                  <DividerSVG style={s.v} color={active ? palette.card : palette.ink} thickness={1.5} w={70} h={20} />
                </div>
              </button>
            );
          })}
        </div>
      </ToolCard>

      <ToolCard label="Color" palette={palette}>
        <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
          {TEXT_COLORS.map(c => <Swatch key={c} color={c} active={node.color === c} onClick={() => update({ color: c })} palette={palette} size={22} />)}
        </div>
      </ToolCard>

      <ToolCard label="Thickness" palette={palette}>
        <Slider label="Stroke" value={node.thickness} min={1} max={6} step={0.5} onChange={(v) => update({ thickness: v })} palette={palette} suffix="px" />
      </ToolCard>
    </>
  );
}

function LinkInspector({ node, update, palette }) {
  return (
    <>
      <ToolCard label="Label" palette={palette}>
        <input value={node.text} onChange={(e) => update({ text: e.target.value })}
          style={{ border: `1px solid ${palette.rule}`, background: palette.cardSoft, borderRadius: 10, padding: '8px 10px', fontFamily: BODY_FONT, fontSize: 13, color: palette.ink, outline: 'none' }}/>
      </ToolCard>
      <ToolCard label="URL" palette={palette}>
        <input value={node.url} onChange={(e) => update({ url: e.target.value })}
          style={{ border: `1px solid ${palette.rule}`, background: palette.cardSoft, borderRadius: 10, padding: '8px 10px', fontFamily: MONO_FONT, fontSize: 11, color: palette.ink, outline: 'none' }}/>
      </ToolCard>

      <ToolCard label="Variant" palette={palette}>
        <PillRow
          options={[{v:'pill',label:'Pill'},{v:'card',label:'Card'},{v:'tag',label:'Tag'}]}
          value={node.variant}
          onChange={(v) => update({ variant: v, radius: v === 'pill' ? 22 : v === 'tag' ? 6 : 14 })}
          palette={palette}
        />
      </ToolCard>

      <ToolCard label="Fill" palette={palette}>
        <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
          {NODE_FILLS.filter(c => c !== 'transparent').slice(0, 7).map(c => <Swatch key={c} color={c} active={node.bg === c} onClick={() => update({ bg: c })} palette={palette} size={22} />)}
        </div>
      </ToolCard>

      <ToolCard label="Text" palette={palette}>
        <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
          {TEXT_COLORS.map(c => <Swatch key={c} color={c} active={node.textColor === c} onClick={() => update({ textColor: c })} palette={palette} size={22} />)}
        </div>
      </ToolCard>

      <ToolCard label="Border" palette={palette}>
        <Slider label="Width" value={node.borderW} min={0} max={4} step={0.5} onChange={(v) => update({ borderW: v })} palette={palette} suffix="px" />
        <Slider label="Radius" value={node.radius} min={0} max={28} onChange={(v) => update({ radius: v })} palette={palette} suffix="px" />
      </ToolCard>
    </>
  );
}

function GalleryInspector({ node, update, palette }) {
  const tones = ['peach', 'sage', 'sky', 'butter', 'rose'];
  return (
    <>
      <ToolCard label="Photos" span={2} palette={palette}>
        <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
          {node.tones.map((t, i) => (
            <div key={i} style={{ position: 'relative' }}>
              <button onClick={() => {
                const next = [...node.tones]; next[i] = tones[(tones.indexOf(t) + 1) % tones.length];
                update({ tones: next });
              }} style={{
                width: 44, height: 44, borderRadius: 8,
                border: `1px solid ${palette.rule}`,
                overflow: 'hidden', padding: 0, cursor: 'pointer',
              }}>
                <ThumbSVG tone={t} />
              </button>
            </div>
          ))}
          <button onClick={() => update({ tones: [...node.tones, 'peach'] })}
            style={{ width: 44, height: 44, borderRadius: 8, border: `1.5px dashed ${palette.rule}`, background: 'transparent', color: palette.inkFaded, fontSize: 22, cursor: 'pointer' }}>+</button>
        </div>
      </ToolCard>

      <ToolCard label="Layout" palette={palette}>
        <PillRow
          options={[{v:'grid',label:'Grid'},{v:'mosaic',label:'Mosaic'},{v:'strip',label:'Strip'}]}
          value={node.layout}
          onChange={(v) => update({ layout: v })}
          palette={palette}
        />
      </ToolCard>

      <ToolCard label="Spacing" palette={palette}>
        <Slider label="Gap" value={node.gap} min={0} max={20} onChange={(v) => update({ gap: v })} palette={palette} suffix="px" />
        <Slider label="Radius" value={node.radius} min={0} max={28} onChange={(v) => update({ radius: v })} palette={palette} suffix="px" />
      </ToolCard>
    </>
  );
}

function CarouselInspector({ node, update, palette }) {
  return (
    <>
      <ToolCard label="Items" palette={palette}>
        <PillRow options={[3,4,5,6].map(n=>({v:n,label:String(n)}))} value={4} onChange={()=>{}} palette={palette} mono />
      </ToolCard>
      <ToolCard label="Auto-play" palette={palette}>
        <PillRow options={[{v:'off',label:'Off'},{v:'slow',label:'Slow'},{v:'fast',label:'Fast'}]} value={'slow'} onChange={()=>{}} palette={palette}/>
      </ToolCard>
      <ToolCard label="Indicator" palette={palette}>
        <PillRow options={[{v:'dots',label:'Dots'},{v:'bars',label:'Bars'},{v:'none',label:'None'}]} value={'dots'} onChange={()=>{}} palette={palette}/>
      </ToolCard>
    </>
  );
}

function ContainerInspector({ node, update, palette }) {
  return (
    <>
      <ToolCard label="Fill" palette={palette}>
        <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
          {NODE_FILLS.map(c => <Swatch key={c} color={c} active={node.bg === c} onClick={() => update({ bg: c })} palette={palette} size={22} />)}
        </div>
      </ToolCard>
      <ToolCard label="Border" palette={palette}>
        <Slider label="Width" value={node.borderW || 0} min={0} max={6} step={0.5} onChange={(v) => update({ borderW: v })} palette={palette} suffix="px" />
        <Slider label="Radius" value={node.radius || 0} min={0} max={40} onChange={(v) => update({ radius: v })} palette={palette} suffix="px" />
      </ToolCard>
      <ToolCard label="Layout" palette={palette}>
        <PillRow options={[{v:'free',label:'Free'},{v:'stack',label:'Stack'},{v:'grid',label:'Grid'}]} value={'free'} onChange={()=>{}} palette={palette}/>
      </ToolCard>
    </>
  );
}

// ─── COMMON FRAME ROW (always visible) ──────────────────────────
function FrameRow({ node, update, palette }) {
  return (
    <div style={{
      display: 'flex', gap: 8, alignItems: 'center',
      padding: '7px 12px', borderTop: `1px solid ${palette.rule}`,
      fontFamily: MONO_FONT, fontSize: 10, color: palette.inkSoft,
      background: palette.cardSoft, flexWrap: 'nowrap', overflow: 'hidden',
    }}>
      <span style={{ letterSpacing: '0.14em', textTransform: 'uppercase', fontSize: 9, color: palette.inkFaded, flex: '0 0 auto' }}>Frame</span>
      {[
        ['X', 'x'], ['Y', 'y'], ['W', 'w'], ['H', 'h'],
      ].map(([label, k]) => (
        <span key={k} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, flex: '0 0 auto' }}>
          <span style={{ color: palette.inkFaded }}>{label}</span>
          <span style={{
            background: palette.card, border: `1px solid ${palette.rule}`,
            borderRadius: 5, padding: '2px 5px', minWidth: 28, textAlign: 'center',
            color: palette.ink, fontWeight: 600, fontSize: 10,
          }}>{Math.round(node[k])}</span>
        </span>
      ))}
      <span style={{ flex: 1 }} />
      <button style={{ background: 'transparent', border: 'none', color: palette.accent, cursor: 'pointer', fontFamily: MONO_FONT, fontSize: 10, fontWeight: 700, padding: 0, flex: '0 0 auto' }}>Delete</button>
    </div>
  );
}

// ─── HEADER ROW ─────────────────────────────────────────────────
function InspectorHeader({ node, palette, onClose, onCollapse, collapsed, hideCollapse }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '12px 16px',
      borderBottom: `1px solid ${palette.rule}`,
      background: palette.card,
    }}>
      <div style={{
        width: 36, height: 36, borderRadius: 10,
        background: palette.accent, color: palette.card,
        display: 'grid', placeItems: 'center', fontWeight: 700,
        fontFamily: BODY_FONT, fontSize: 15, flex: '0 0 36px',
      }}>{NODE_GLYPHS[node.type]}</div>
      <div style={{ display: 'flex', flexDirection: 'column', minWidth: 0, flex: '0 0 auto' }}>
        <span style={{
          fontFamily: MONO_FONT, fontSize: 9.5, letterSpacing: '0.18em',
          textTransform: 'uppercase', color: palette.inkFaded,
          marginBottom: 4, lineHeight: 1, whiteSpace: 'nowrap',
        }}>Editing · {node.id}</span>
        <span style={{
          fontFamily: FONT_OPTIONS.fraunces, fontSize: 19,
          color: palette.ink, fontWeight: 600, fontStyle: 'italic',
          lineHeight: 1, whiteSpace: 'nowrap',
        }}>
          {NODE_LABELS[node.type]}
        </span>
      </div>

      {/* breadcrumb pill in header center */}
      <div style={{
        marginLeft: 14,
        display: 'inline-flex', alignItems: 'center', gap: 8,
        fontFamily: MONO_FONT, fontSize: 10, color: palette.inkFaded,
        letterSpacing: '0.1em',
        background: palette.cardSoft, padding: '6px 10px',
        borderRadius: 99, border: `1px solid ${palette.rule}`,
      }}>
        <span>x{Math.round(node.x)}</span>
        <span style={{ opacity: .4 }}>·</span>
        <span>y{Math.round(node.y)}</span>
        <span style={{ opacity: .4 }}>·</span>
        <span>{Math.round(node.w)}×{Math.round(node.h)}</span>
      </div>

      <span style={{ flex: 1 }} />

      {!hideCollapse && (
        <button onClick={onCollapse} style={{
          width: 28, height: 28, border: `1px solid ${palette.rule}`, borderRadius: 8,
          background: palette.cardSoft, cursor: 'pointer', color: palette.inkSoft,
          fontSize: 13, lineHeight: 1, padding: 0,
        }}>{collapsed ? '▴' : '▾'}</button>
      )}
      <button onClick={onClose} style={{
        height: 28, padding: '0 12px', border: `1px solid ${palette.rule}`, borderRadius: 14,
        background: palette.cardSoft, cursor: 'pointer', color: palette.inkSoft,
        fontFamily: BODY_FONT, fontSize: 12, fontWeight: 600,
      }}>Done</button>
    </div>
  );
}

// ─── MAIN INSPECTOR (legacy: inside-device sheet) ──────────────
function Inspector({ node, palette, update, onClose }) {
  const [collapsed, setCollapsed] = useState_I(false);
  if (!node) return null;
  const body = inspectorBody(node, update, palette);

  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      background: palette.paper,
      borderTop: `1px solid ${palette.rule}`,
      borderTopLeftRadius: 22, borderTopRightRadius: 22,
      boxShadow: '0 -20px 40px rgba(0,0,0,0.06), 0 -2px 0 ' + palette.rule,
      transition: 'transform .25s ease',
      transform: collapsed ? 'translateY(calc(100% - 60px))' : 'translateY(0)',
      maxHeight: '54%',
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{
        width: 40, height: 4, background: palette.rule, borderRadius: 2,
        margin: '6px auto 0', flex: '0 0 auto',
      }} />
      <div style={{ flex: '0 0 auto' }}>
        <InspectorHeader node={node} palette={palette} onClose={onClose} onCollapse={() => setCollapsed(!collapsed)} collapsed={collapsed} />
      </div>
      {!collapsed && (
        <>
          <div style={{
            display: 'flex', gap: 8, padding: '10px 12px',
            overflowX: 'auto', overflowY: 'hidden',
            flex: '1 1 auto', minHeight: 0,
          }}>
            {body}
          </div>
          <div style={{ flex: '0 0 auto' }}>
            <FrameRow node={node} update={update} palette={palette} />
          </div>
        </>
      )}
    </div>
  );
}

// ─── INSPECTOR DOCK (full-width desk dock) ─────────────────────
function inspectorBody(node, update, palette) {
  if (node.type === 'text') return <TextInspector node={node} update={update} palette={palette} />;
  if (node.type === 'image') return <ImageInspector node={node} update={update} palette={palette} />;
  if (node.type === 'icon') return <IconInspector node={node} update={update} palette={palette} />;
  if (node.type === 'divider') return <DividerInspector node={node} update={update} palette={palette} />;
  if (node.type === 'link') return <LinkInspector node={node} update={update} palette={palette} />;
  if (node.type === 'gallery') return <GalleryInspector node={node} update={update} palette={palette} />;
  if (node.type === 'carousel') return <CarouselInspector node={node} update={update} palette={palette} />;
  if (node.type === 'container') return <ContainerInspector node={node} update={update} palette={palette} />;
  return null;
}

function InspectorDock({ node, palette, update, onClose }) {
  if (!node) {
    return (
      <div style={{
        width: '100%', borderRadius: 18,
        background: palette.card, border: `1px solid ${palette.rule}`,
        padding: '22px 24px', display: 'flex', alignItems: 'center', gap: 14,
        boxShadow: '0 6px 18px rgba(0,0,0,0.04)',
      }}>
        <div style={{
          width: 36, height: 36, borderRadius: 10,
          border: `1.5px dashed ${palette.rule}`,
          display: 'grid', placeItems: 'center', color: palette.inkFaded, fontSize: 18,
        }}>↖</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          <span style={{ fontFamily: MONO_FONT, fontSize: 9.5, letterSpacing: '0.16em', textTransform: 'uppercase', color: palette.inkFaded }}>Inspector</span>
          <span style={{ fontFamily: FONT_OPTIONS.fraunces, fontSize: 17, fontStyle: 'italic', color: palette.ink }}>tap a block to start tinkering</span>
        </div>
      </div>
    );
  }

  const body = inspectorBody(node, update, palette);

  return (
    <div style={{
      width: '100%',
      background: palette.card,
      border: `1px solid ${palette.rule}`,
      borderRadius: 18,
      boxShadow: '0 6px 18px rgba(0,0,0,0.04)',
      display: 'flex', flexDirection: 'column',
      overflow: 'hidden',
    }}>
      <InspectorHeader node={node} palette={palette} onClose={onClose} onCollapse={() => {}} collapsed={false} hideCollapse />
      <div style={{
        display: 'flex', gap: 10, padding: '12px 14px',
        overflowX: 'auto', overflowY: 'hidden',
        background: palette.paper,
      }}>
        {body}
      </div>
      <FrameRow node={node} update={update} palette={palette} />
    </div>
  );
}

Object.assign(window, { Inspector, InspectorDock, ToolCard, Pill, Slider, PillRow, Swatch });
