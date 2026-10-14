// Inline SVG stroke icons on a 24 grid (1.75 stroke, currentColor).
// Shapes: 'M…' string = stroked path; { p, fill } path; { c: [cx, cy, r], fill } circle;
// { r: [x, y, w, h, rx] } rect.

const SVG_NS = 'http://www.w3.org/2000/svg';

const round = (n) => Math.round(n * 100) / 100;

function polar(cx, cy, radius, deg) {
  const t = (deg * Math.PI) / 180;
  return [round(cx + radius * Math.cos(t)), round(cy + radius * Math.sin(t))];
}

function polygon(points) {
  return 'M' + points.map(([x, y]) => `${x} ${y}`).join('L') + 'Z';
}

function starPath() {
  const pts = [];
  for (let i = 0; i < 10; i++) pts.push(polar(12, 12.6, i % 2 ? 4.3 : 9.6, -90 + i * 36));
  return polygon(pts);
}

function gearPath() {
  const pts = [];
  for (let i = 0; i < 8; i++) {
    const a = i * 45 - 90;
    pts.push(polar(12, 12, 7.3, a - 15), polar(12, 12, 9.7, a - 8), polar(12, 12, 9.7, a + 8), polar(12, 12, 7.3, a + 15));
  }
  return polygon(pts);
}

const STAR = starPath();
const dot = (cx, cy, r = 1.35) => ({ c: [cx, cy, r], fill: true });

const ICONS = {
  plus: ['M12 5v14', 'M5 12h14'],
  minus: ['M5 12h14'],
  search: [{ c: [11, 11, 7] }, 'M20.5 20.5l-4.55-4.55'],
  settings: [gearPath(), { c: [12, 12, 3] }],
  sliders: ['M4 7h9', 'M17 7h3', 'M4 17h3', 'M11 17h9', { c: [15, 7, 2] }, { c: [9, 17, 2] }],
  star: [STAR],
  starFilled: [{ p: STAR, fill: true }],
  edit: ['M4 20v-3.5L15.2 5.3a2.3 2.3 0 0 1 3.25 3.25L7.5 20H4z', 'M13.4 7.1l3.5 3.5'],
  trash: [
    'M4 7h16',
    'M9 7V4.75C9 4.34 9.34 4 9.75 4h4.5c.41 0 .75.34.75.75V7',
    'M6 7l.9 12.1A2 2 0 0 0 8.9 21h6.2a2 2 0 0 0 2-1.9L18 7',
    'M10 11v6',
    'M14 11v6',
  ],
  copy: [{ r: [9, 9, 11.5, 11.5, 2.2] }, 'M5.5 15H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v.5'],
  download: ['M12 4v11', 'M7 10.5l5 5 5-5', 'M5 20h14'],
  upload: ['M12 15.5V4', 'M7 9l5-5 5 5', 'M5 20h14'],
  play: [{ p: 'M7.5 5.6v12.8c0 .86.93 1.4 1.68.97l11.1-6.4a1.12 1.12 0 0 0 0-1.94L9.18 4.63C8.43 4.2 7.5 4.74 7.5 5.6z' }],
  pause: ['M8.5 5v14', 'M15.5 5v14'],
  check: ['M5 12.5l4.5 4.5L19 7.5'],
  checkCircle: [{ c: [12, 12, 9] }, 'M8.3 12.3l2.5 2.5 4.9-5.1'],
  x: ['M6.5 6.5l11 11', 'M17.5 6.5l-11 11'],
  xCircle: [{ c: [12, 12, 9] }, 'M9.3 9.3l5.4 5.4', 'M14.7 9.3l-5.4 5.4'],
  arrowLeft: ['M19 12H5', 'M11 6l-6 6 6 6'],
  arrowRight: ['M5 12h14', 'M13 6l6 6-6 6'],
  arrowUp: ['M12 19V5', 'M6 11l6-6 6 6'],
  chevronRight: ['M9.5 6l6 6-6 6'],
  chevronLeft: ['M14.5 6l-6 6 6 6'],
  chevronDown: ['M6 9.5l6 6 6-6'],
  chevronUp: ['M6 14.5l6-6 6 6'],
  enter: ['M9 10.5l-4.5 4.5 4.5 4.5', 'M19.5 4.5V11a4 4 0 0 1-4 4h-11'],
  volume: [
    'M4 9.6v4.8c0 .55.45 1 1 1h2.9l4.3 3.7c.4.34 1.05.06 1.05-.47V5.37c0-.53-.65-.81-1.05-.47L7.9 8.6H5c-.55 0-1 .45-1 1z',
    'M16.3 9.2a4 4 0 0 1 0 5.6',
    'M18.9 6.6a7.6 7.6 0 0 1 0 10.8',
  ],
  more: [dot(5.5, 12, 1.5), dot(12, 12, 1.5), dot(18.5, 12, 1.5)],
  moreVertical: [dot(12, 5.5, 1.5), dot(12, 12, 1.5), dot(12, 18.5, 1.5)],
  rotate: ['M3.5 12A8.5 8.5 0 1 0 6 6l-2.5 2.5', 'M3.5 4v4.5H8'],
  undo: ['M9 14L4 9l5-5', 'M4 9h10.5a5.5 5.5 0 0 1 0 11H11'],
  repeat: ['M17 2.5l3.5 3.5L17 9.5', 'M3.5 11.5V10a4 4 0 0 1 4-4h13', 'M7 21.5L3.5 18 7 14.5', 'M20.5 12.5V14a4 4 0 0 1-4 4h-13'],
  sun: [
    { c: [12, 12, 4] },
    'M12 2.75v1.75',
    'M12 19.5v1.75',
    'M2.75 12H4.5',
    'M19.5 12h1.75',
    'M5.46 5.46l1.24 1.24',
    'M17.3 17.3l1.24 1.24',
    'M5.46 18.54l1.24-1.24',
    'M17.3 6.7l1.24-1.24',
  ],
  moon: ['M20 14.6A8.5 8.5 0 1 1 9.4 4a6.6 6.6 0 0 0 10.6 10.6z'],
  monitor: [{ r: [3, 4, 18, 12.5, 2.2] }, 'M8.5 20.5h7', 'M12 16.5v4'],
  image: [{ r: [3, 4, 18, 16, 2.5] }, { c: [9, 9.5, 1.75] }, 'M21 15.5l-4.6-4.6a1.6 1.6 0 0 0-2.25 0L5 20'],
  camera: [
    'M14.6 4.5H9.4L7.6 7H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-2.6z',
    { c: [12, 13.25, 3.5] },
  ],
  fileText: ['M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z', 'M14 3v5h5', 'M9 13h6', 'M9 17h6', 'M9 9h1.5'],
  clipboard: [
    { r: [8.5, 2.75, 7, 3.75, 1.2] },
    'M15.5 4.5h1.75a2 2 0 0 1 2 2V19.5a2 2 0 0 1-2 2H6.75a2 2 0 0 1-2-2V6.5a2 2 0 0 1 2-2H8.5',
  ],
  sparkles: [
    'M11 3.5l1.55 4.2a2 2 0 0 0 1.2 1.2L18 10.5l-4.25 1.6a2 2 0 0 0-1.2 1.2L11 17.5l-1.55-4.2a2 2 0 0 0-1.2-1.2L4 10.5l4.25-1.6a2 2 0 0 0 1.2-1.2z',
    'M18.5 15v4.5',
    'M16.25 17.25h4.5',
    'M18.5 3v3',
    'M17 4.5h3',
  ],
  shuffle: [
    'M3 7h3.4a4 4 0 0 1 3.3 1.75l4.6 6.5A4 4 0 0 0 17.6 17H21',
    'M3 17h3.4a4 4 0 0 0 3.3-1.75l.6-.85',
    'M13.7 9.6l.6-.85A4 4 0 0 1 17.6 7H21',
    'M18 4l3 3-3 3',
    'M18 14l3 3-3 3',
  ],
  keyboard: [
    { r: [2.5, 6, 19, 12, 2.2] },
    'M6.5 10h.01',
    'M10 10h.01',
    'M14 10h.01',
    'M17.5 10h.01',
    'M8 14h8',
  ],
  flame: [
    'M12 21.5c3.6 0 6.5-2.75 6.5-6.4 0-2.7-1.5-4.75-2.9-6.2-.35 1.55-1.2 2.6-2.35 3 .3-3.35-1.25-6.4-3.85-8.4.15 2.65-1.25 4.7-2.85 6.25C5.5 11.65 5.5 13.4 5.5 15.1c0 3.65 2.9 6.4 6.5 6.4z',
  ],
  // The Lernserie (Mac: flame.fill): the same outline, filled.
  flameFilled: [
    {
      p: 'M12 21.5c3.6 0 6.5-2.75 6.5-6.4 0-2.7-1.5-4.75-2.9-6.2-.35 1.55-1.2 2.6-2.35 3 .3-3.35-1.25-6.4-3.85-8.4.15 2.65-1.25 4.7-2.85 6.25C5.5 11.65 5.5 13.4 5.5 15.1c0 3.65 2.9 6.4 6.5 6.4z',
      fill: true,
    },
  ],
  book: ['M5 19.5V5.5A2.5 2.5 0 0 1 7.5 3H19v13.5H7.5a2.5 2.5 0 0 0 0 5H19', 'M9 7.5h6'],
  bookOpen: ['M12 7.5V20', 'M3 5.5h5a4 4 0 0 1 4 4V20a3 3 0 0 0-3-3H3z', 'M21 5.5h-5a4 4 0 0 0-4 4V20a3 3 0 0 1 3-3h6z'],
  swap: ['M7.5 4L4 7.5 7.5 11', 'M4 7.5h14', 'M16.5 13l3.5 3.5-3.5 3.5', 'M20 16.5H6'],
  alert: [
    'M10.27 4.2L2.73 17.25A2 2 0 0 0 4.46 20.25h15.08a2 2 0 0 0 1.73-3L13.73 4.2a2 2 0 0 0-3.46 0z',
    'M12 9.5v4',
    'M12 17h.01',
  ],
  alertCircle: [{ c: [12, 12, 9] }, 'M12 7.75v5', 'M12 16.25h.01'],
  info: [{ c: [12, 12, 9] }, 'M12 11v5.5', 'M12 7.75h.01'],
  help: [{ c: [12, 12, 9] }, 'M9.6 9.4a2.5 2.5 0 0 1 4.85.85c0 1.65-2.45 2.3-2.45 2.3', 'M12 16.5h.01'],
  lightbulb: ['M9.5 18h5', 'M10.5 21h3', 'M12 3a6 6 0 0 0-3.6 10.8c.6.45 1.1 1.25 1.1 2.2h5c0-.95.5-1.75 1.1-2.2A6 6 0 0 0 12 3z'],
  eye: ['M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7S2.5 12 2.5 12z', { c: [12, 12, 3] }],
  eyeOff: [
    'M3 3l18 18',
    'M10.6 5.1A9.8 9.8 0 0 1 12 5c6 0 9.5 7 9.5 7a16.6 16.6 0 0 1-2.4 3.3',
    'M6.6 6.6C3.9 8.4 2.5 12 2.5 12s3.5 7 9.5 7a9.4 9.4 0 0 0 5.4-1.6',
    'M9.9 9.9a3 3 0 0 0 4.2 4.2',
  ],
  filter: ['M4 4.5h16a.5.5 0 0 1 .39.81L14 13v6.19a.5.5 0 0 1-.28.45l-3 1.5a.5.5 0 0 1-.72-.45V13L3.61 5.31A.5.5 0 0 1 4 4.5z'],
  grip: [dot(9, 6), dot(15, 6), dot(9, 12), dot(15, 12), dot(9, 18), dot(15, 18)],
  layers: ['M12 2.75l9 5-9 5-9-5z', 'M3 12.25l9 5 9-5', 'M3 16.5l9 5 9-5'],
  // Karteikarten: a card with a second one behind it.
  cards: [{ r: [3, 8, 14, 12.5, 2] }, 'M7 8V5.5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2V15a2 2 0 0 1-2 2h-2'],
  // Prüfung: a mortarboard.
  graduationCap: ['M12 4.5L2.5 9l9.5 4.5L21.5 9z', 'M6.5 11.2v4.3c0 1.4 2.5 3 5.5 3s5.5-1.6 5.5-3v-4.3', 'M21.5 9v5'],
  target: [{ c: [12, 12, 9] }, { c: [12, 12, 5.5] }, dot(12, 12, 1.75)],
  trophy: [
    'M7.5 4h9v5.5a4.5 4.5 0 0 1-9 0z',
    'M7.5 6H5.25a2.25 2.25 0 0 0 0 4.5H7.9',
    'M16.5 6h2.25a2.25 2.25 0 0 1 0 4.5H16.1',
    'M12 14v4',
    'M8 21h8',
    'M9.5 21v-1.5A1.5 1.5 0 0 1 11 18h2a1.5 1.5 0 0 1 1.5 1.5V21',
  ],
  clock: [{ c: [12, 12, 9] }, 'M12 7v5l3.5 2'],
  calendar: [{ r: [3.5, 5, 17, 15.5, 2.2] }, 'M8 3v4', 'M16 3v4', 'M3.5 10h17'],
  home: ['M4 10.5L12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5H15v-6H9v6H5.5A1.5 1.5 0 0 1 4 19z'],
  menu: ['M4 7h16', 'M4 12h16', 'M4 17h16'],
  list: ['M9 6h11', 'M9 12h11', 'M9 18h11', 'M4.5 6h.01', 'M4.5 12h.01', 'M4.5 18h.01'],
  grid: [{ r: [3.5, 3.5, 7, 7, 1.6] }, { r: [13.5, 3.5, 7, 7, 1.6] }, { r: [3.5, 13.5, 7, 7, 1.6] }, { r: [13.5, 13.5, 7, 7, 1.6] }],
  chart: ['M4 20h16', 'M7 16.5V12', 'M12 16.5V7.5', 'M17 16.5V10'],
  zap: ['M13 2.5L4.5 13.5H12l-1 8 8.5-11H12z'],
  external: ['M14 4h6v6', 'M20 4l-9 9', 'M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10'],
  globe: [{ c: [12, 12, 9] }, 'M3 12h18', 'M12 3a13.5 13.5 0 0 1 0 18', 'M12 3a13.5 13.5 0 0 0 0 18'],
};

// Friendly aliases
ICONS.close = ICONS.x;
ICONS.pencil = ICONS.edit;
ICONS.gear = ICONS.settings;
ICONS.speaker = ICONS.volume;
ICONS.warning = ICONS.alert;

export const ICON_NAMES = Object.keys(ICONS);

export function hasIcon(name) {
  return Object.prototype.hasOwnProperty.call(ICONS, name);
}

function shape(spec) {
  let el;
  if (typeof spec === 'string') {
    el = document.createElementNS(SVG_NS, 'path');
    el.setAttribute('d', spec);
  } else if (spec.p) {
    el = document.createElementNS(SVG_NS, 'path');
    el.setAttribute('d', spec.p);
  } else if (spec.c) {
    el = document.createElementNS(SVG_NS, 'circle');
    const [cx, cy, r] = spec.c;
    el.setAttribute('cx', cx);
    el.setAttribute('cy', cy);
    el.setAttribute('r', r);
  } else if (spec.r) {
    el = document.createElementNS(SVG_NS, 'rect');
    const [x, y, w, hgt, rx] = spec.r;
    el.setAttribute('x', x);
    el.setAttribute('y', y);
    el.setAttribute('width', w);
    el.setAttribute('height', hgt);
    if (rx) el.setAttribute('rx', rx);
  }
  if (el && spec.fill) {
    el.setAttribute('fill', 'currentColor');
    if (!spec.p) el.setAttribute('stroke', 'none');
  }
  return el;
}

// icon('star', { size: 18, className: 'my-icon' }) -> <svg class="ui-icon my-icon">
export function icon(name, { size = 20, className, strokeWidth = 1.75, title } = {}) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', strokeWidth);
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('focusable', 'false');
  svg.setAttribute('class', className ? `ui-icon ${className}` : 'ui-icon');
  svg.dataset.icon = name;
  if (title) {
    svg.setAttribute('role', 'img');
    const t = document.createElementNS(SVG_NS, 'title');
    t.textContent = title;
    svg.appendChild(t);
  } else {
    svg.setAttribute('aria-hidden', 'true');
  }
  for (const spec of ICONS[name] || []) {
    const el = shape(spec);
    if (el) svg.appendChild(el);
  }
  return svg;
}
