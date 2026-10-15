// Positioned text items (from pdf.js or OCR word boxes) → plain text lines.
// Pure and DOM-free (runs under jsc).
//
// Coordinates are top-origin: `x` is the left edge, `y` the baseline (or the
// bottom of the word box), `w` the width and `h` the glyph/font height.
//
// Pipeline: items → rows (grouped by y) → cells (split at wide horizontal gaps)
// → page-level column model (gutters found by projecting cells onto the x axis)
// → reading order:
//   - single column            → rows top to bottom, '' at paragraph gaps
//   - 2-column table           → "term\tdefinition" per row, wrapped cells merged
//   - 4-column table           → left pairs first, then right pairs
//   - stacked pairs per column → each page column top to bottom (term line, definition line, gap, …)
//   - unaligned text columns   → each page column top to bottom
//
// Right-to-left text (Arabic, Hebrew): a cell whose letters are mostly RTL is
// read from right to left and belongs to the column of its right edge. Items
// with `dir: 'rtl'` (pdf.js) hold their text in logical order, starting at the
// right edge. Han characters (Chinese) are joined without spaces.

const SPACE_FACTOR = 0.25; // gap (× char width) above which two fragments are separate words
const PARAGRAPH_FACTOR = 1.8; // vertical gap (× line step) that starts a new paragraph
const INVISIBLE = /[\u00AD\u200B-\u200D\u2060\uFEFF]/g;
const ODD_SPACES = /[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/g;
// A word followed by single or double spaces stays one piece; tabs or 3+ spaces split.
const PIECE = /[^\s]+(?: {1,2}[^\s]+)*/g;
const MARKER = /^(?:\(?\d{1,4}[.)]?|\(?[a-zA-Z][.)]|[•▪◦·∙●○■□►▸‣⁃*–—-])$/;
const WRAP_END = /[,;:\-–(/]$/;
const STARTS_LOWER = /^[(\[]?[a-zà-ÿœæ]/;
// A cell ending in an article, preposition or object placeholder continues on the next line.
const OPEN_END = /(?:^|\s)(?:le|la|les|l'|un|une|des|du|de|d'|à|au|aux|en|et|ou|avec|pour|sur|dans|par|chez|der|die|das|den|dem|ein|eine|einen|einem|einer|und|oder|mit|von|für|auf|zu|zum|zur|im|am|in|über|bei|jdm|jdn|jds|etw|sich|the|a|to|of|and|or|with|for|from|into)$/iu;
const ENTRY_START = /^(?:(?:le|la|les|un|une|des|du|der|die|das|den|dem|ein|eine|the|a|an|to|el|los|las|il|lo|gli|uno|una)\s|l')/iu;
// Right-to-left scripts (Hebrew, Arabic, Syriac, Thaana, NKo, ... and their presentation forms).
const RTL_CHAR = /[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFE]/u;
// Han ranges as in core/langdetect.js.
const HAN_END = /[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u{20000}-\u{2FA1F}]$/u;
const HAN_START = /^[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u{20000}-\u{2FA1F}]/u;

// ---------------------------------------------------------------------------
// Small numeric helpers

function toNumber(v) {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? parseFloat(v) : NaN;
  return Number.isFinite(n) ? n : null;
}

function median(values) {
  if (!values.length) return 0;
  const s = values.slice().sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function lowerQuartile(values) {
  if (!values.length) return 0;
  const s = values.slice().sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) * 0.25)];
}

function clamp(v, lo, hi) {
  return Math.min(hi, Math.max(lo, v));
}

// ---------------------------------------------------------------------------
// Scripts

// More than half of the letters are right-to-left.
function isRtlText(s) {
  let letters = 0;
  let rtl = 0;
  for (const ch of s) {
    if (!/\p{L}/u.test(ch)) continue;
    letters++;
    if (RTL_CHAR.test(ch)) rtl++;
  }
  return rtl * 2 > letters;
}

// Joins two words with a space, except between two Han characters.
function joinWords(a, b) {
  return HAN_END.test(a) && HAN_START.test(b) ? a + b : `${a} ${b}`;
}

// ---------------------------------------------------------------------------
// Items

function readItems(items) {
  const raw = [];
  if (!Array.isArray(items)) return raw;
  for (const it of items) {
    if (!it || it.str == null) continue;
    const str = String(it.str).replace(INVISIBLE, '').replace(ODD_SPACES, ' ');
    if (!str.trim()) continue;
    const x = toNumber(it.x);
    const y = toNumber(it.y);
    if (x === null || y === null) continue;
    const w = toNumber(it.w);
    const h = toNumber(it.h);
    raw.push({ str, x, y, w: w > 0 ? w : 0, h: h > 0 ? h : 0, rtl: it.dir === 'rtl' });
  }
  return raw;
}

function measure(raw) {
  const heights = raw.filter((it) => it.h > 0).map((it) => it.h);
  const height = median(heights) || 10;
  const widths = raw.filter((it) => it.w > 0).map((it) => it.w / it.str.length);
  const charW = median(widths) || height * 0.5;
  return { height, charW };
}

// Fill missing sizes, then split every item into visible pieces: leading and
// trailing whitespace is trimmed (remembered as word boundaries) and runs of
// tabs / 3+ spaces inside one item become separate pieces (monospace columns).
// A right-to-left item starts at its right edge.
function toPieces(raw, metrics) {
  const pieces = [];
  for (const it of raw) {
    const h = it.h || metrics.height;
    const w = it.w || it.str.length * metrics.charW * (h / metrics.height);
    const cw = w / it.str.length;
    PIECE.lastIndex = 0;
    let m;
    while ((m = PIECE.exec(it.str))) {
      const start = m.index;
      const end = start + m[0].length;
      pieces.push({
        str: m[0],
        x: it.rtl ? it.x + (it.str.length - end) * cw : it.x + start * cw,
        y: it.y,
        w: m[0].length * cw,
        h,
        lead: start > 0,
        trail: end < it.str.length,
      });
    }
  }
  return pieces;
}

// ---------------------------------------------------------------------------
// Rows and cells

function groupRows(pieces, tolerance, metrics) {
  const sorted = pieces.slice().sort((a, b) => a.y - b.y || a.x - b.x);
  const rows = [];
  let cur = null;
  for (const it of sorted) {
    if (cur && it.y - cur.y <= tolerance) {
      cur.items.push(it);
      cur.sumY += it.y;
      cur.y = cur.sumY / cur.items.length;
    } else {
      cur = { items: [it], sumY: it.y, y: it.y };
      rows.push(cur);
    }
  }
  for (const row of rows) {
    row.items.sort((a, b) => a.x - b.x);
    row.items = dedupe(row.items, metrics.charW * 0.5);
    row.h = median(row.items.map((it) => it.h));
  }
  return rows;
}

// Some PDFs fake bold text by drawing the same string twice with a tiny offset.
function dedupe(items, maxShift) {
  const out = [];
  for (const it of items) {
    const twin = out.find((o) => o.str === it.str && Math.abs(o.x - it.x) < maxShift);
    if (!twin) out.push(it);
  }
  return out;
}

function buildCells(row, metrics, gapFactor) {
  const cw = metrics.charW * clamp(row.h / metrics.height, 0.6, 3);
  const tabGap = gapFactor * cw;
  const spaceGap = SPACE_FACTOR * cw;
  const cells = [];
  let cell = null;
  for (const it of row.items) {
    if (cell && it.x - cell.x1 <= tabGap) {
      cell.items.push(it);
      cell.x1 = Math.max(cell.x1, it.x + it.w);
      continue;
    }
    cell = { items: [it], x0: it.x, x1: it.x + it.w };
    cells.push(cell);
  }
  return cells
    .map((c) => {
      const rtl = isRtlText(c.items.map((it) => it.str).join(''));
      return { text: cellText(c.items, rtl, spaceGap).replace(/\s+/g, ' ').trim(), x0: c.x0, x1: c.x1, rtl };
    })
    .filter((c) => c.text);
}

// The pieces of one cell in reading order (right to left for RTL text). A gap
// wider than a space or a word boundary inside an item becomes a space,
// except between two Han characters.
function cellText(items, rtl, spaceGap) {
  const order = rtl ? items.slice().reverse() : items;
  let text = order[0].str;
  let edge = rtl ? order[0].x : order[0].x + order[0].w; // where the text read so far ends
  let trail = order[0].trail;
  for (let i = 1; i < order.length; i++) {
    const it = order[i];
    const gap = rtl ? edge - (it.x + it.w) : it.x - edge;
    const space = (trail || it.lead || gap > spaceGap) && !(HAN_END.test(text) && HAN_START.test(it.str));
    text += (space ? ' ' : '') + it.str;
    edge = rtl ? Math.min(edge, it.x) : Math.max(edge, it.x + it.w);
    trail = it.trail;
  }
  return text;
}

// Typical baseline-to-baseline distance of consecutive lines. The lower
// quartile is used so that frequent paragraph gaps (e.g. "term, definition,
// blank line" lists) do not inflate it.
function lineStepOf(ys, height) {
  const pitches = [];
  for (let i = 1; i < ys.length; i++) {
    const d = ys[i] - ys[i - 1];
    if (d > 0.75 * height) pitches.push(d);
  }
  if (pitches.length >= 3) return lowerQuartile(pitches);
  // Two pitches: the smaller one is the line step (equal ones mean uniform spacing).
  if (pitches.length === 2) return Math.min(...pitches);
  // A single pitch cannot be compared: assume a normal leading.
  return Math.min(pitches.length ? pitches[0] : Infinity, 1.25 * height);
}

// ---------------------------------------------------------------------------
// Column model

// Projects all cells onto the x axis and looks for gutters: x ranges that
// (almost) no cell covers and that have cells starting to their right.
// Returns the boundaries between columns, or null for a single column.
function findColumnBounds(rows, metrics) {
  const cells = [];
  for (const row of rows) for (const c of row.cells) cells.push(c);
  if (cells.length < 4) return null;
  let xMin = Infinity;
  let xMax = -Infinity;
  for (const c of cells) {
    xMin = Math.min(xMin, c.x0);
    xMax = Math.max(xMax, c.x1);
  }
  const span = xMax - xMin;
  if (!(span > 0)) return null;
  const binW = Math.max(metrics.charW * 0.5, span / 4000);
  const nb = Math.floor(span / binW) + 2;
  const cover = new Int32Array(nb);
  const starts = new Int32Array(nb);
  for (const c of cells) {
    const b0 = Math.floor((c.x0 - xMin) / binW);
    const b1 = Math.max(b0, Math.ceil((c.x1 - xMin) / binW) - 1);
    // Right-to-left text starts at the right edge (right-aligned columns have ragged left edges).
    starts[c.rtl ? b1 : b0]++;
    for (let b = b0; b <= b1 && b < nb; b++) cover[b]++;
  }
  const textRows = rows.filter((r) => r.cells.length).length;
  const allowed = Math.max(1, Math.floor(textRows * 0.12));
  const minWidth = Math.max(1, Math.round(metrics.charW / binW));

  // Starts to the right of each bin (suffix sums) to reject trailing runs.
  const startsAfter = new Int32Array(nb + 1);
  for (let b = nb - 1; b >= 0; b--) startsAfter[b] = startsAfter[b + 1] + starts[b];

  const bounds = [];
  let b = 0;
  while (b < nb) {
    if (cover[b] > allowed || starts[b] > 0) {
      b++;
      continue;
    }
    let e = b;
    while (e + 1 < nb && cover[e + 1] <= allowed && starts[e + 1] === 0) e++;
    const hasLeft = b > 0;
    const hasRight = startsAfter[e + 1] > 0;
    if (hasLeft && hasRight && e - b + 1 >= minWidth) {
      bounds.push(xMin + ((b + e + 1) / 2) * binW);
    }
    b = e + 1;
  }
  if (!bounds.length) return null;
  return pruneBounds(bounds, cells);
}

function columnIndex(bounds, x) {
  let i = 0;
  while (i < bounds.length && x >= bounds[i]) i++;
  return i;
}

// A cell belongs to the column of the edge its text starts at.
function anchorX(cell) {
  return cell.rtl ? cell.x1 : cell.x0;
}

// Drops columns that only a handful of cells start in (stray page numbers,
// one indented line, …) by merging them into a neighbour.
function pruneBounds(bounds, cells) {
  let bs = bounds.slice();
  for (;;) {
    if (!bs.length) return null;
    const counts = new Array(bs.length + 1).fill(0);
    for (const c of cells) counts[columnIndex(bs, anchorX(c))]++;
    const max = Math.max(...counts);
    const minStarts = Math.max(2, Math.ceil(max * 0.2));
    let weakest = -1;
    for (let i = 0; i < counts.length; i++) {
      if (counts[i] < minStarts && (weakest < 0 || counts[i] < counts[weakest])) weakest = i;
    }
    if (weakest < 0) return bs;
    // Remove the boundary on the weak column's left (or right for the first column).
    const drop = weakest === 0 ? 0 : weakest - 1;
    bs = bs.filter((_, i) => i !== drop);
  }
}

function assignColumns(rows, bounds) {
  const k = bounds.length + 1;
  for (const row of rows) {
    const parts = Array.from({ length: k }, () => []);
    for (const c of row.cells) parts[columnIndex(bounds, anchorX(c))].push(c.text);
    // Several cells in one column are read like the pieces of a cell.
    row.cols = parts.map((p) => (p.length ? (isRtlText(p.join('')) ? p.slice().reverse() : p).reduce(joinWords) : ''));
  }
  return k;
}

function isMarkerColumn(rows, c) {
  const values = rows.map((r) => r.cols[c]).filter(Boolean);
  if (values.length < 2) return false;
  const markers = values.filter((v) => MARKER.test(v)).length;
  return markers >= values.length * 0.8;
}

function wordCount(s) {
  return s.split(/\s+/).filter(Boolean).length;
}

// In a term | example sentence | translation table, the sentence column is
// clearly wordier than the other two and is not useful for flash cards.
function sentenceColumn(rows, cols) {
  if (cols.length !== 3) return -1;
  const avg = cols.map((c) => {
    const values = rows.map((r) => r.cols[c]).filter(Boolean);
    return values.length ? values.reduce((n, v) => n + wordCount(v), 0) / values.length : 0;
  });
  const candidates = avg
    .map((a, i) => ({ a, i }))
    .filter(({ a, i }) => a >= 4 && avg.every((o, j) => j === i || a >= 2 * o));
  return candidates.length === 1 ? cols[candidates[0].i] : -1;
}

// ---------------------------------------------------------------------------
// Layout classification

function columnLines(rows, c) {
  return rows.filter((r) => r.cols[c]);
}

function blocksOf(lines, paragraph) {
  const blocks = [];
  let cur = null;
  let prevY = null;
  for (const row of lines) {
    if (!cur || row.y - prevY > paragraph) {
      cur = [];
      blocks.push(cur);
    }
    cur.push(row);
    prevY = row.y;
  }
  return blocks;
}

// "term / definition / gap" pairs laid out in several page columns.
function isStackedPairs(rows, cols, ctx) {
  let checked = 0;
  for (const c of cols) {
    const lines = columnLines(rows, c);
    if (lines.length < 4) continue;
    const blocks = blocksOf(lines, ctx.paragraph);
    const pairs = blocks.filter((b) => b.length === 2).length;
    if (blocks.length < 3 || pairs < blocks.length * 0.75) return false;
    checked++;
  }
  return checked >= 2;
}

// Text columns whose lines do not line up (different leading or offsets).
function isIndependentFlow(rows, cols, ctx) {
  const ranges = [];
  for (const c of cols) {
    const lines = columnLines(rows, c);
    if (lines.length < 3) continue;
    const step = lineStepOf(
      lines.map((r) => r.y),
      ctx.metrics.height,
    );
    if (step > 2 * ctx.metrics.height) return false;
    ranges.push([lines[0].y, lines[lines.length - 1].y]);
  }
  if (ranges.length < 2) return false;
  ranges.sort((a, b) => b[1] - b[0] - (a[1] - a[0]));
  const [r1, r2] = ranges;
  const overlap = Math.min(r1[1], r2[1]) - Math.max(r1[0], r2[0]);
  return overlap >= 0.5 * Math.max(1e-6, r2[1] - r2[0]);
}

// ---------------------------------------------------------------------------
// Emitters

function emitRows(rows, textOf, ctx) {
  const out = [];
  let prevY = null;
  for (const row of rows) {
    const text = textOf(row);
    if (!text) continue;
    if (prevY !== null && row.y - prevY > ctx.paragraph) out.push('');
    out.push(text);
    prevY = row.y;
  }
  return out;
}

function emitFlow(rows, cols, ctx) {
  const out = [];
  for (const c of cols) {
    const lines = emitRows(rows, (r) => r.cols[c], ctx);
    if (!lines.length) continue;
    if (out.length) out.push('');
    out.push(...lines);
  }
  return out;
}

function joinWrapped(a, b) {
  if (!a) return b;
  return /-$/.test(a) ? a + b : joinWords(a, b);
}

function endsOpen(s) {
  return WRAP_END.test(s) || OPEN_END.test(s);
}

// Typical distance between two consecutive rows that both fill columns a and
// b. Unlike the row pitch it is not inflated by wrapped lines in between.
function fullRowGap(rows, a, b) {
  const filled = rows.filter((r) => r.cols[a] || r.cols[b]);
  const gaps = [];
  for (let i = 1; i < filled.length; i++) {
    const [p, r] = [filled[i - 1], filled[i]];
    if (p.cols[a] && p.cols[b] && r.cols[a] && r.cols[b]) gaps.push(r.y - p.y);
  }
  return gaps.length >= 2 ? median(gaps) : Infinity;
}

// Both cells of a row wrapped onto one tighter line ("s'entendre bien avec |
// sich mit jdm gut" + "qn | verstehen"). Each side must read as a
// continuation, two articles ("la femme | die Frau") start a new entry, and
// the row needs an open ending or a clearly tighter gap, so that lowercase
// entries ("manger | essen") at a slightly uneven pitch stay separate rows.
function continuesBoth(prev, ta, tb, gap, rowGap) {
  if (!Number.isFinite(rowGap) || !(gap < 0.85 * rowGap)) return false;
  if (ENTRY_START.test(ta) && ENTRY_START.test(tb)) return false;
  const continues = (before, next) => STARTS_LOWER.test(next) || endsOpen(before);
  if (!continues(prev.a, ta) || !continues(prev.b, tb)) return false;
  return endsOpen(prev.a) || endsOpen(prev.b) || gap < 0.7 * rowGap;
}

function emitTable(rows, cols, ctx) {
  const out = [];
  for (let g = 0; g + 1 < cols.length; g += 2) {
    const a = cols[g];
    const b = cols[g + 1];
    const complete = rows.filter((r) => r.cols[a] && r.cols[b]).map((r) => r.y);
    const rowPitch = complete.length >= 2 ? median(complete.slice(1).map((y, i) => y - complete[i])) : Infinity;
    const rowGap = fullRowGap(rows, a, b);
    const entries = [];
    for (const row of rows) {
      const ta = row.cols[a];
      const tb = row.cols[b];
      if (!ta && !tb) continue;
      const prev = entries[entries.length - 1];
      const gap = prev ? row.y - prev.lastY : Infinity;
      const near = gap <= ctx.paragraph;
      if (prev && near && !ta && tb) {
        prev.b = joinWrapped(prev.b, tb);
        prev.lastY = row.y;
        continue;
      }
      if (prev && near && ta && !tb && prev.a && prev.b) {
        const tighter = gap < 0.85 * rowPitch;
        if (WRAP_END.test(prev.a) || (tighter && STARTS_LOWER.test(ta))) {
          prev.a = joinWrapped(prev.a, ta);
          prev.lastY = row.y;
          continue;
        }
      }
      if (prev && near && ta && tb && prev.a && prev.b && continuesBoth(prev, ta, tb, gap, rowGap)) {
        prev.a = joinWrapped(prev.a, ta);
        prev.b = joinWrapped(prev.b, tb);
        prev.lastY = row.y;
        continue;
      }
      entries.push({ a: ta, b: tb, lastY: row.y, gapBefore: Boolean(prev) && !near });
    }
    if (!entries.length) continue;
    if (out.length) out.push('');
    for (const e of entries) {
      if (e.gapBefore) out.push('');
      out.push(e.a && e.b ? `${e.a}\t${e.b}` : e.a || e.b);
    }
  }
  return out;
}

function tidy(lines) {
  const out = [];
  for (const line of lines) {
    const t = line.replace(/ +/g, ' ').replace(/ *\t */g, '\t').trim();
    if (!t) {
      if (out.length && out[out.length - 1] !== '') out.push('');
    } else {
      out.push(t);
    }
  }
  while (out.length && out[out.length - 1] === '') out.pop();
  return out;
}

// ---------------------------------------------------------------------------
// Public API

export function itemsToLines(items, opts = {}) {
  const o = opts || {};
  const yTolerance = toNumber(o.yTolerance) ?? 0.5;
  const gapFactor = toNumber(o.gapFactor) ?? 2.2;
  const raw = readItems(items);
  if (!raw.length) return [];
  const metrics = measure(raw);
  const pieces = toPieces(raw, metrics);
  const rows = groupRows(pieces, Math.max(0.05, yTolerance) * metrics.height, metrics);
  for (const row of rows) row.cells = buildCells(row, metrics, Math.max(0.5, gapFactor));
  const textRows = rows.filter((r) => r.cells.length);
  const step = lineStepOf(
    textRows.map((r) => r.y),
    metrics.height,
  );
  const ctx = { metrics, step, paragraph: PARAGRAPH_FACTOR * step };

  const bounds = findColumnBounds(textRows, metrics);
  if (!bounds) return tidy(emitRows(textRows, (r) => r.cells.map((c) => c.text).join('\t'), ctx));

  const k = assignColumns(textRows, bounds);
  let cols = [];
  for (let c = 0; c < k; c++) if (!isMarkerColumn(textRows, c)) cols.push(c);
  if (!cols.length) cols = Array.from({ length: k }, (_, i) => i);
  const sentence = sentenceColumn(textRows, cols);
  if (sentence >= 0) cols = cols.filter((c) => c !== sentence);
  const joined = (r) =>
    cols
      .map((c) => r.cols[c])
      .filter(Boolean)
      .join('\t');

  if (cols.length === 1) return tidy(emitRows(textRows, joined, ctx));

  const aligned = textRows.filter((r) => cols.filter((c) => r.cols[c]).length >= 2).length;
  const withText = textRows.filter((r) => cols.some((c) => r.cols[c])).length;
  let lines;
  if (isStackedPairs(textRows, cols, ctx)) {
    lines = emitFlow(textRows, cols, ctx);
  } else if (aligned >= 2 && aligned >= 0.3 * withText) {
    lines = cols.length % 2 === 0 ? emitTable(textRows, cols, ctx) : emitRows(textRows, joined, ctx);
  } else if (isIndependentFlow(textRows, cols, ctx)) {
    lines = emitFlow(textRows, cols, ctx);
  } else {
    lines = emitRows(textRows, joined, ctx);
  }
  return tidy(lines);
}

// Median slope (dy/dx, top-origin) of baseline segments [{ x0, y0, x1, y1 }],
// e.g. OCR text-line baselines. Short segments are ignored. 0 when unknown.
export function estimateSlope(segments, { minWidth = 40 } = {}) {
  const slopes = [];
  for (const s of Array.isArray(segments) ? segments : []) {
    if (!s) continue;
    const x0 = toNumber(s.x0);
    const y0 = toNumber(s.y0);
    const x1 = toNumber(s.x1);
    const y1 = toNumber(s.y1);
    if (x0 === null || y0 === null || x1 === null || y1 === null) continue;
    const dx = x1 - x0;
    if (dx < minWidth) continue;
    const slope = (y1 - y0) / dx;
    if (Math.abs(slope) <= 0.35) slopes.push(slope);
  }
  return slopes.length ? median(slopes) : 0;
}

// Rotates item positions so that text lines with the given slope become
// horizontal (straightens slightly rotated photos before row grouping).
export function deskewItems(items, slope) {
  const list = Array.isArray(items) ? items : [];
  const s = toNumber(slope);
  if (s === null || Math.abs(s) < 1e-4 || Math.abs(s) > 0.5) return list.slice();
  const theta = Math.atan(s);
  const cos = Math.cos(theta);
  const sin = Math.sin(theta);
  return list.map((it) => {
    const x = toNumber(it && it.x);
    const y = toNumber(it && it.y);
    if (x === null || y === null) return it;
    return { ...it, x: x * cos + y * sin, y: -x * sin + y * cos };
  });
}
