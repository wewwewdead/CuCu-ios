// editor.jsx — CuCu profile editor mock
// Real working canvas with selectable nodes, bottom-sheet inspector,
// and live tool-cards.

const { useState, useEffect, useRef, useMemo, Fragment } = React;

// ─── Palettes ──────────────────────────────────────────────────────────
const PALETTES = {
  cream: {
    name: 'Cream',
    paper: '#F2EFE6',
    paperDeep: '#E5E0D2',
    card: '#FBF8EE',
    cardSoft: '#EFEAD8',
    ink: '#1F1A12',
    inkSoft: '#5A4F3F',
    inkFaded: '#9B8E72',
    rule: 'rgba(31,26,18,0.14)',
    accent: '#B8324B',
    accentSoft: '#F1D4D9',
    moss: '#4D7C50',
    sky: '#D9E5F5',
    canvasBG: '#F8F2DF',
    chipFill: '#F3D9DC',
    chipStroke: '#C49199',
    chipInk: '#5A1A26',
  },
  mint: {
    name: 'Mint',
    paper: '#E8EFE6',
    paperDeep: '#D6E1D2',
    card: '#F5FAF1',
    cardSoft: '#E1ECDB',
    ink: '#15281C',
    inkSoft: '#42594A',
    inkFaded: '#85998A',
    rule: 'rgba(21,40,28,0.14)',
    accent: '#D2557A',
    accentSoft: '#F4D6E0',
    moss: '#3F7A52',
    sky: '#D5E5DC',
    canvasBG: '#EAF3E5',
    chipFill: '#E5EFD8',
    chipStroke: '#9DB78D',
    chipInk: '#1F3522',
  },
  dusk: {
    name: 'Dusk',
    paper: '#1B1923',
    paperDeep: '#15131C',
    card: '#262433',
    cardSoft: '#1E1C28',
    ink: '#F4EFE2',
    inkSoft: '#C0B8A2',
    inkFaded: '#7C7565',
    rule: 'rgba(244,239,226,0.18)',
    accent: '#F5A6B5',
    accentSoft: '#3A2A36',
    moss: '#9BCDA0',
    sky: '#33304A',
    canvasBG: '#221F2C',
    chipFill: '#3A2A36',
    chipStroke: '#7A5A6A',
    chipInk: '#FBE4E9',
  },
};

// ─── Display fonts ─────────────────────────────────────────────────────
const FONT_OPTIONS = {
  fraunces: '"Fraunces", "Iowan Old Style", Georgia, serif',
  caprasimo: '"Caprasimo", "Cooper Black", Georgia, serif',
  lobster: '"Lobster", "Brush Script MT", cursive',
  caveat: '"Caveat", "Bradley Hand", cursive',
  patrick: '"Patrick Hand", "Comic Sans MS", cursive',
  yeseva: '"Yeseva One", "Bodoni 72", serif',
};
const BODY_FONT = '"Hanken Grotesk", -apple-system, system-ui, sans-serif';
const MONO_FONT = '"JetBrains Mono", ui-monospace, monospace';

// ─── Sample profile ────────────────────────────────────────────────────
const NODE_TYPES = ['container', 'text', 'image', 'icon', 'divider', 'link', 'gallery', 'carousel'];
const NODE_LABELS = {
  container: 'Container', text: 'Text', image: 'Image', icon: 'Icon',
  divider: 'Divider', link: 'Link', gallery: 'Gallery', carousel: 'Carousel',
};
const NODE_GLYPHS = {
  container: '▢', text: 'Aa', image: '◐', icon: '✦',
  divider: '〰', link: '⟿', gallery: '▦', carousel: '◀▶',
};

// Nice tiny utilities
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const idFor = (() => { let n = 0; return () => `n${++n}`; })();

// Initial doc — small profile snippet: header text, image (avatar), bio text, two links, divider
const makeDoc = () => ({
  bgColor: '#F8E0D2',
  bgPattern: 'paper',
  nodes: {
    header: {
      id: 'header', type: 'text',
      text: 'mira ✿', font: 'caprasimo', weight: 700, size: 38,
      color: '#3A1A1F', align: 'center',
      x: 50, y: 70, w: 220, h: 52, opacity: 1,
      bg: 'transparent', radius: 0, borderW: 0, borderC: '#1A140E',
      padding: 0,
    },
    avatar: {
      id: 'avatar', type: 'image',
      x: 105, y: 130, w: 110, h: 110, opacity: 1,
      radius: 60, borderW: 2, borderC: '#3A1A1F',
      clip: 'circle', fit: 'fill',
      tone: 'peach', // generated thumbnail tone
    },
    div1: {
      id: 'div1', type: 'divider',
      style: 'sparkleChain', color: '#B8324B', thickness: 2,
      x: 60, y: 252, w: 200, h: 22, opacity: 1,
    },
    bio: {
      id: 'bio', type: 'text',
      text: 'collector of small joys.\nbasement gardener.', font: 'fraunces', weight: 400, italic: true, size: 15,
      color: '#3A1A1F', align: 'center',
      x: 40, y: 282, w: 240, h: 50, opacity: 1,
      bg: 'transparent', radius: 0, borderW: 0, borderC: '#1A140E',
      padding: 0,
    },
    icon1: {
      id: 'icon1', type: 'icon',
      glyph: 'heart', plate: '#FFE3EC', tint: '#B8324B',
      x: 70, y: 350, w: 48, h: 48, opacity: 1,
      radius: 14, borderW: 1.5, borderC: '#3A1A1F',
    },
    icon2: {
      id: 'icon2', type: 'icon',
      glyph: 'star', plate: '#FFF1B8', tint: '#B8324B',
      x: 136, y: 350, w: 48, h: 48, opacity: 1,
      radius: 14, borderW: 1.5, borderC: '#3A1A1F',
    },
    icon3: {
      id: 'icon3', type: 'icon',
      glyph: 'flower', plate: '#DDF1D5', tint: '#3F7A52',
      x: 202, y: 350, w: 48, h: 48, opacity: 1,
      radius: 14, borderW: 1.5, borderC: '#3A1A1F',
    },
    link1: {
      id: 'link1', type: 'link',
      text: 'my journal',
      url: 'mira.cucu/notes',
      variant: 'pill',
      bg: '#FBF6E9', textColor: '#3A1A1F', borderW: 1.5, borderC: '#3A1A1F',
      x: 50, y: 415, w: 220, h: 44, opacity: 1, radius: 22,
    },
    link2: {
      id: 'link2', type: 'link',
      text: 'tiny shop',
      url: 'mira.cucu/shop',
      variant: 'pill',
      bg: '#3A1A1F', textColor: '#FBF6E9', borderW: 1.5, borderC: '#3A1A1F',
      x: 50, y: 472, w: 220, h: 44, opacity: 1, radius: 22,
    },
    gallery1: {
      id: 'gallery1', type: 'gallery',
      tones: ['peach', 'sage', 'sky', 'butter'],
      layout: 'grid', gap: 6, fit: 'fill',
      x: 40, y: 535, w: 240, h: 110, opacity: 1, radius: 12, borderW: 0, borderC: '#1A140E',
    },
  },
  order: ['header', 'avatar', 'div1', 'bio', 'icon1', 'icon2', 'icon3', 'link1', 'link2', 'gallery1'],
});

Object.assign(window, {
  PALETTES, FONT_OPTIONS, BODY_FONT, MONO_FONT,
  NODE_TYPES, NODE_LABELS, NODE_GLYPHS, clamp, idFor, makeDoc,
});
