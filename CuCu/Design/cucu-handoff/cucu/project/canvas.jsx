// canvas.jsx — renders profile nodes onto the device canvas
const { useState: useState_C } = React;

// SF-symbol-ish tiny glyphs for icon nodes
const ICON_GLYPHS = {
  heart: <path d="M12 21s-7-4.5-9.5-9C.7 8.5 2.7 4.5 6.5 4.5c2 0 3.5 1.2 4.5 2.7C12 5.7 13.5 4.5 15.5 4.5c3.8 0 5.8 4 4 7.5C19 16.5 12 21 12 21z" />,
  star: <path d="M12 2.5l2.7 6 6.6.6-5 4.4 1.5 6.5L12 16.7 6.2 20l1.5-6.5-5-4.4 6.6-.6z" />,
  flower: <g><circle cx="12" cy="6" r="3.2"/><circle cx="6" cy="12" r="3.2"/><circle cx="18" cy="12" r="3.2"/><circle cx="12" cy="18" r="3.2"/><circle cx="12" cy="12" r="2.6" fill="#fff" opacity=".5"/></g>,
  sparkle: <path d="M12 2c.7 4 3 6.3 7 7-4 .7-6.3 3-7 7-.7-4-3-6.3-7-7 4-.7 6.3-3 7-7z" />,
  bolt: <path d="M14 2 4 14h6l-1 8 11-12h-7z" />,
  bookmark: <path d="M6 3h12v19l-6-4-6 4z" />,
  book: <path d="M4 4h7c1.7 0 3 1.3 3 3v14c0-1.7-1.3-3-3-3H4zM20 4h-7c-1.7 0-3 1.3-3 3v14c0-1.7 1.3-3 3-3h7z" fill="none" stroke="currentColor" strokeWidth="1.6"/>,
  globe: <g fill="none" stroke="currentColor" strokeWidth="1.6"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/></g>,
  camera: <path d="M4 7h4l2-2h4l2 2h4v12H4z M12 17a4 4 0 100-8 4 4 0 000 8z" fill="none" stroke="currentColor" strokeWidth="1.6"/>,
  music: <g fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"><path d="M9 17V5l11-2v12"/><circle cx="6" cy="17" r="3"/><circle cx="17" cy="15" r="3"/></g>,
  envelope: <path d="M3 6h18v12H3z M3 6l9 7 9-7" fill="none" stroke="currentColor" strokeWidth="1.6"/>,
  pin: <path d="M12 2c4 0 7 3 7 7 0 5-7 13-7 13S5 14 5 9c0-4 3-7 7-7zm0 5a2.5 2.5 0 100 5 2.5 2.5 0 000-5z" />,
};

// generated avatar/gallery thumb — simple painterly gradient
function ThumbSVG({ tone = 'peach' }) {
  const palettes = {
    peach: ['#FFD9B8', '#E89A6A', '#3A1F1A'],
    sage:  ['#D8E9C9', '#7FA86C', '#2C3E26'],
    sky:   ['#CFE0F2', '#7AA0CB', '#1F2D45'],
    butter:['#FBE9A8', '#D4A53D', '#3F2E10'],
    rose:  ['#F5C9D4', '#C77993', '#3A1A26'],
  };
  const [a, b, c] = palettes[tone] || palettes.peach;
  return (
    <svg viewBox="0 0 100 100" width="100%" height="100%" preserveAspectRatio="xMidYMid slice" style={{ display: 'block' }}>
      <defs>
        <linearGradient id={`g-${tone}`} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stopColor={a} />
          <stop offset="1" stopColor={b} />
        </linearGradient>
      </defs>
      <rect width="100" height="100" fill={`url(#g-${tone})`} />
      {/* sun-ish */}
      <circle cx="76" cy="22" r="9" fill="#FBF6E9" opacity=".75" />
      {/* hills */}
      <path d="M0 78 C 18 64 38 88 60 72 S 92 70 100 76 V100 H0 Z" fill={c} opacity=".75" />
      <path d="M0 90 C 22 80 44 96 66 86 S 92 88 100 92 V100 H0 Z" fill={c} />
    </svg>
  );
}

// Divider rendering — 4 styles
function DividerSVG({ style, color, thickness, w, h }) {
  const cy = h / 2;
  if (style === 'solid') return <svg width={w} height={h}><line x1="0" y1={cy} x2={w} y2={cy} stroke={color} strokeWidth={thickness}/></svg>;
  if (style === 'dashed') return <svg width={w} height={h}><line x1="0" y1={cy} x2={w} y2={cy} stroke={color} strokeWidth={thickness} strokeDasharray="6 5"/></svg>;
  if (style === 'dotted') return <svg width={w} height={h}><line x1="0" y1={cy} x2={w} y2={cy} stroke={color} strokeWidth={thickness * 1.4} strokeDasharray={`0 ${thickness * 3}`} strokeLinecap="round"/></svg>;
  if (style === 'heartChain' || style === 'sparkleChain' || style === 'starChain' || style === 'flowerChain') {
    const glyph = style === 'heartChain' ? ICON_GLYPHS.heart : style === 'starChain' ? ICON_GLYPHS.star : style === 'flowerChain' ? ICON_GLYPHS.flower : ICON_GLYPHS.sparkle;
    const count = 5;
    const items = [];
    const sz = h - 2;
    for (let i = 0; i < count; i++) {
      const cx = (w / (count + 1)) * (i + 1);
      items.push(
        <g key={i} transform={`translate(${cx - sz / 2} 1)`}>
          <line x1={-sz / 2 - 4} y1={sz/2} x2={-2} y2={sz/2} stroke={color} strokeWidth={thickness} strokeLinecap="round"/>
          <line x1={sz + 2} y1={sz/2} x2={sz + sz / 2 + 4} y2={sz/2} stroke={color} strokeWidth={thickness} strokeLinecap="round"/>
          <g transform={`scale(${sz / 24})`} fill={color} stroke={color} strokeLinejoin="round" strokeWidth="0.8">
            {glyph}
          </g>
        </g>
      );
    }
    return <svg width={w} height={h}>{items}</svg>;
  }
  // default
  return <svg width={w} height={h}><line x1="0" y1={cy} x2={w} y2={cy} stroke={color} strokeWidth={thickness}/></svg>;
}

// Render a single node
function NodeView({ node, selected, onSelect, fonts }) {
  const baseStyle = {
    position: 'absolute',
    left: node.x, top: node.y,
    width: node.w, height: node.h,
    opacity: node.opacity,
    cursor: 'pointer',
    boxSizing: 'border-box',
  };

  let inner = null;

  if (node.type === 'text') {
    const fam = fonts[node.font] || FONT_OPTIONS.fraunces;
    inner = (
      <div style={{
        ...baseStyle,
        background: node.bg === 'transparent' ? 'transparent' : node.bg,
        borderRadius: node.radius,
        border: node.borderW ? `${node.borderW}px solid ${node.borderC}` : 'none',
        padding: node.padding || 0,
        fontFamily: fam,
        fontStyle: node.italic ? 'italic' : 'normal',
        fontWeight: node.weight,
        fontSize: node.size,
        color: node.color,
        textAlign: node.align,
        display: 'flex',
        alignItems: 'center',
        justifyContent: node.align === 'center' ? 'center' : node.align === 'right' ? 'flex-end' : 'flex-start',
        lineHeight: 1.18,
        whiteSpace: 'pre-wrap',
        letterSpacing: '-0.005em',
      }}>
        <span style={{ width: '100%', textAlign: node.align }}>{node.text}</span>
      </div>
    );
  } else if (node.type === 'image') {
    inner = (
      <div style={{
        ...baseStyle,
        borderRadius: node.clip === 'circle' ? '50%' : node.radius,
        border: node.borderW ? `${node.borderW}px solid ${node.borderC}` : 'none',
        overflow: 'hidden',
        background: '#eee',
      }}>
        <ThumbSVG tone={node.tone} />
      </div>
    );
  } else if (node.type === 'icon') {
    const G = ICON_GLYPHS[node.glyph] || ICON_GLYPHS.heart;
    inner = (
      <div style={{
        ...baseStyle,
        background: node.plate,
        borderRadius: node.radius,
        border: node.borderW ? `${node.borderW}px solid ${node.borderC}` : 'none',
        display: 'grid', placeItems: 'center',
      }}>
        <svg viewBox="0 0 24 24" width="60%" height="60%" fill={node.tint} stroke={node.tint} strokeLinejoin="round" strokeWidth="0.5">
          {G}
        </svg>
      </div>
    );
  } else if (node.type === 'divider') {
    inner = (
      <div style={baseStyle}>
        <DividerSVG style={node.style} color={node.color} thickness={node.thickness} w={node.w} h={node.h} />
      </div>
    );
  } else if (node.type === 'link') {
    inner = (
      <div style={{
        ...baseStyle,
        background: node.bg,
        color: node.textColor,
        borderRadius: node.radius,
        border: node.borderW ? `${node.borderW}px solid ${node.borderC}` : 'none',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontFamily: FONT_OPTIONS.fraunces,
        fontStyle: 'italic',
        fontWeight: 600,
        fontSize: 16,
        boxShadow: '0 2px 0 ' + node.borderC,
      }}>
        {node.text}
      </div>
    );
  } else if (node.type === 'gallery') {
    const cols = 2, rows = 2;
    const gap = node.gap;
    inner = (
      <div style={{
        ...baseStyle,
        borderRadius: node.radius,
        border: node.borderW ? `${node.borderW}px solid ${node.borderC}` : 'none',
        overflow: 'hidden',
        display: 'grid',
        gridTemplateColumns: `repeat(${cols}, 1fr)`,
        gridTemplateRows: `repeat(${rows}, 1fr)`,
        gap,
      }}>
        {node.tones.map((t, i) => (
          <div key={i} style={{ overflow: 'hidden', borderRadius: 6 }}>
            <ThumbSVG tone={t} />
          </div>
        ))}
      </div>
    );
  } else if (node.type === 'container') {
    inner = (
      <div style={{
        ...baseStyle,
        background: node.bg,
        borderRadius: node.radius,
        border: node.borderW ? `${node.borderW}px solid ${node.borderC}` : 'none',
      }} />
    );
  } else if (node.type === 'carousel') {
    inner = (
      <div style={{
        ...baseStyle,
        background: node.bg,
        borderRadius: node.radius,
        border: node.borderW ? `${node.borderW}px solid ${node.borderC}` : 'none',
        display: 'flex', alignItems: 'center', gap: 8, padding: 8, overflow: 'hidden',
      }}>
        {[0,1,2,3].map(i => <div key={i} style={{ flex: '0 0 88px', height: '80%', borderRadius: 8, background: '#FFE3EC', border: '1px solid #1A140E' }} />)}
      </div>
    );
  }

  return (
    <div
      onClick={(e) => { e.stopPropagation(); onSelect(node.id); }}
      style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}
    >
      <div style={{ pointerEvents: 'auto' }}>
        {inner}
      </div>
      {selected && (
        <div style={{
          position: 'absolute',
          left: node.x - 6, top: node.y - 6,
          width: node.w + 12, height: node.h + 12,
          border: '1.5px dashed #B8324B',
          borderRadius: (node.clip === 'circle' ? '50%' : (node.radius || 0) + 6),
          pointerEvents: 'none',
        }}>
          {/* corner ticks */}
          {[
            [-3, -3], [-3, 'r'], ['b', -3], ['b', 'r'],
          ].map((p, i) => (
            <div key={i} style={{
              position: 'absolute',
              left: p[0] === 'b' ? 'auto' : p[0],
              right: p[0] === 'b' ? p[1] === 'r' ? -3 : 'auto' : 'auto',
              top: p[1] === 'r' ? -3 : p[1] === -3 ? -3 : 'auto',
              bottom: p[1] === 'r' ? 'auto' : 'auto',
              ...(p[0] === 'b' ? { bottom: -3 } : {}),
              ...(p[1] === 'r' ? { right: -3 } : {}),
              width: 6, height: 6, background: '#FBF8EE',
              border: '1.5px solid #B8324B', borderRadius: 1,
            }} />
          ))}
        </div>
      )}
    </div>
  );
}

function Canvas({ doc, selectedID, onSelect, palette, fonts }) {
  return (
    <div
      onClick={() => onSelect(null)}
      style={{
        position: 'absolute', inset: 0,
        background: doc.bgColor,
        overflow: 'hidden',
      }}
    >
      {/* page background image (overlays color, color shows through transparent areas) */}
      {doc.bgImage && (
        <div style={{
          position: 'absolute', inset: 0, pointerEvents: 'none',
          backgroundImage: doc.bgImage.startsWith('data:') || doc.bgImage.startsWith('http') || doc.bgImage.startsWith('linear') || doc.bgImage.startsWith('radial') || doc.bgImage.startsWith('repeating') || doc.bgImage.startsWith('url(')
            ? (doc.bgImage.startsWith('url(') || doc.bgImage.includes('gradient') ? doc.bgImage : `url("${doc.bgImage}")`)
            : `url("${doc.bgImage}")`,
          backgroundSize: doc.bgImageSize || 'cover',
          backgroundPosition: 'center',
          backgroundRepeat: doc.bgImageSize === 'tile' ? 'repeat' : 'no-repeat',
          opacity: doc.bgImageOpacity ?? 1,
          filter: doc.bgImageBlur ? `blur(${doc.bgImageBlur}px)` : undefined,
        }} />
      )}
      {/* paper grain (kept subtle, always on) */}
      <div style={{
        position: 'absolute', inset: 0, pointerEvents: 'none',
        opacity: 0.22, mixBlendMode: 'multiply',
        backgroundImage: `url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='240' height='240'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 0.10  0 0 0 0 0.08  0 0 0 0 0.05  0 0 0 .25 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>")`,
      }} />
      {/* nodes */}
      {doc.order.map(id => (
        <NodeView
          key={id}
          node={doc.nodes[id]}
          selected={selectedID === id}
          onSelect={onSelect}
          fonts={fonts}
        />
      ))}
    </div>
  );
}

Object.assign(window, { Canvas, NodeView, ThumbSVG, ICON_GLYPHS, DividerSVG });
