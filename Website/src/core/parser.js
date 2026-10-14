// Smart vocabulary-list parser ("intelligente Texterkennung").
//
// Turns pasted, file-imported, PDF-extracted or OCR'd text into term/definition
// pairs. Handles delimited lists (tab, dash, equals, colon, semicolon, pipe,
// arrows, quoted CSV, Quizlet comma export, 2+ space PDF columns, 4-cell rows,
// 3-cell rows with an example or note column, page columns of "term – def"
// entries, mixed delimiters), line-based lists (blank-line blocks, alternating
// lines, wrapped continuation lines, two-column OCR order, number vocabulary)
// and noisy input (headings, page numbers, header rows, bullets).
// Ambiguous structure is resolved with per-line language detection: line-based
// lists are aligned by a small dynamic program that scores every possible
// grouping by how well each line's language fits its side.
// Never throws. Pure and DOM-free (runs under jsc).

import { normalizeBasic } from './text.js';
import { scoreLanguages, detectColumn, SUPPORTED } from './langdetect.js';

const LANG_CODES = ['fr', 'de', 'en', 'es', 'it', 'other'];
const BASE_PRIOR = { fr: 0.2, de: 0.25, en: 0.1, es: 0.05, it: 0 };

// Alignment costs are negative log probabilities (nats).
const CLIP = 0.04;
const PAIR_K = 0.9;
const MERGE_COST = 1.5;
const UNPAIRED_COST = 4;
const RUN_UNPAIRED_COST = 1.5;
const WEAK_HEADING_COST = 0.6;
// A capitalised line before a lowercase term may be a section heading:
// cheaper to skip, dearer to merge into the term (see align()).
const HEADING_SKIP_COST = 2.5;
const HEADING_MERGE_COST = 3;
const DELIM_SPLIT_COST = 0.3;
const LANG_SPLIT_COST = 1.2;
// Lines with 3+ parts: a part this far into the other language is misplaced;
// split points closer than SPLIT_MARGIN are a close call.
const SPLIT_MISFIT = 2;
const SPLIT_MARGIN = 0.5;
// [extra cost of merging lines across a blank line, of a term->definition junction across one]
const BOUNDARY = { none: [0, 0], weak: [1, 0], medium: [2.5, 1.5], strong: [5, 5] };

const PAGE_RE = /^(?:-\s*)?(?:(?:seite|page|pagina|página|pag\.?|s\.|p\.)\s*)?\d{1,4}(?:\s*(?:\/|von|of|sur|de|di)\s*\d{1,4})?(?:\s*-)?$/iu;
const URL_RE = /(?:https?:\/\/|www\.)\S|^©|^\(c\)\s/i;
const KEYWORD_RE = /^(?:seite|page|unit[eé]?|unit[aà]|lektion|le[cç]on|lesson|chapitre|chapter|kapitel|capitolo|cap[ií]tulo|unidad|lezione|lecci[oó]n|module?|th[eè]me|thema|tema|vocabulaire|vocabulary|vocabulario|vocabolario|wortschatz|vokabeln|vokabular|glossar|glossaire|dossier|[eé]tape|abschnitt|section)(?!\p{L})/iu;
const ALWAYS_HEADING_RE = /^(?:vocabulaire|vocabulary|vocabulario|vocabolario|wortschatz|vokabeln|vokabular|glossar|glossaire)(?!\p{L})/iu;
const ROMAN_RE = /(?:^|\s)[IVXLC]{1,6}(?=[.:)]|\s|$)/;
const MARKER_RE = /^(?:\(?\d{1,3}[.)]|\d{1,3} ?[-:]|\(?[a-z]\)|[•·▪▫◦‣○●■□➢►▶✓✔✗☐*+>-])[ \t]+/u;
const NUMBER_CELL_RE = /^\d{1,4}[.)]?\t/;
const NUMBERED_RE = /^\d{1,3} ?[-:][ \t]+/;
const BARE_NUMBER_RE = /^\d{1,4}$/;
const ARROW_RE = /\s*(?:<->|<=>|-->|->|=>|→|⇒|⟶|↔|⟹|➔|➜)\s*/;

const LANG_NAMES = new Map();
for (const [concept, names] of Object.entries({
  fr: 'französisch franzoesisch franz frz français francais french francés frances francese',
  de: 'deutsch allemand german alemán aleman tedesco',
  en: 'englisch anglais english inglés ingles inglese',
  es: 'spanisch espagnol spanish español espanol spagnolo',
  it: 'italienisch italien italian italiano',
})) {
  for (const name of names.split(' ')) LANG_NAMES.set(name, concept);
}
const LABELS = new Map(
  Object.entries({
    begriff: 'term', begriffe: 'term', term: 'term', terms: 'term', terme: 'term', definition: 'def',
    définition: 'def', definitionen: 'def', wort: 'word', wörter: 'word', vokabel: 'word', mot: 'word',
    mots: 'word', word: 'word', words: 'word', palabra: 'word', parola: 'word', übersetzung: 'trans',
    uebersetzung: 'trans', traduction: 'trans', translation: 'trans', traducción: 'trans', traduzione: 'trans',
    bedeutung: 'meaning', meaning: 'meaning', signification: 'meaning', frage: 'q', question: 'q',
    antwort: 'a', answer: 'a', réponse: 'a',
  }),
);
const CODES = new Set(['FR', 'DE', 'EN', 'ES', 'IT']);

// Words after which a continuation line is joined with a plain space:
// articles, conjunctions, prepositions and German object placeholders
// ("sich mit jdm / verstehen"). Separable particles (an, aus, um, vor, nach)
// end German clauses and are left out.
const OPEN_ENDINGS = new Set(
  `der die das den dem des ein eine einen einem einer le la les l' un une du de à au aux et ou und oder the a
   an to of and or el los las il lo gli i e y o sich se s' zu mit von für auf in en dans pour avec sur par chez
   sans sous vers entre que ne jdm jdn jds etw über unter bei gegen ohne durch zum zur im am beim vom with for
   from at on by into about`.split(/\s+/),
);
const DE_ARTICLE_RE = /(?:^|\s)(?:sich|der|die|das|den|dem|des|ein|eine|einen|einem|einer)\s/;
const FR_OBJECT_END_RE = /\s(?:le|la|les|un|une|du|des)\s\p{Ll}+$/u;
// Lines starting like a new entry are unlikely to continue the previous line.
const ENTRY_START_RE = /^(?:(?:le|la|les|un|une|des|du|der|die|das|den|dem|ein|eine|the|a|an|to|el|los|las|il|lo|gli|uno|una|se|sich)\s|(?:l|d)'|s'(?!ils?\s))/iu;

// Delimiter candidates for auto detection, in priority order. 'first' and
// 'regex' split on every occurrence; extra parts are resolved by language.
const CANDIDATES = [
  { id: '\t', kind: 'cells' },
  { id: ' - ', kind: 'first' },
  { id: ' → ', kind: 'regex', re: ARROW_RE },
  { id: ' = ', kind: 'first' },
  { id: '=', kind: 'first' },
  { id: ' : ', kind: 'first' },
  { id: ': ', kind: 'first' },
  { id: ';', kind: 'csv' },
  { id: '|', kind: 'csv' },
  { id: '  ', kind: 'gap' },
];
const GAP = CANDIDATES[CANDIDATES.length - 1];
const COMMA = { id: ',', kind: 'csv' };
// Quizlet's comma export: "beau, belle,schön" (no space after the separator, no quotes).
const TIGHT_COMMA = { id: ',', kind: 'regex', re: /,(?![\s,])/, joiner: ', ' };
// Delimiters inside the cells of two page columns ("le chat – die Katze<TAB>le chien – der Hund").
const INNER_CANDIDATES = CANDIDATES.filter((c) => c.kind === 'first' || c.kind === 'regex');

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export function parseVocab(text, opts = {}) {
  let o = null;
  try {
    o = normalizeOptions(opts);
    return parseInternal(text, o);
  } catch {
    const fallback = o || normalizeOptions(null);
    return {
      cards: [],
      format: 'empty',
      delimiter: null,
      termLang: fallback.termHintRaw || 'other',
      defLang: fallback.defHintRaw || 'de',
      swapped: false,
      skipped: [],
      warnings: ['Der Text konnte nicht verarbeitet werden.'],
    };
  }
}

// ---------------------------------------------------------------------------
// Options & language helpers
// ---------------------------------------------------------------------------

function normalizeOptions(opts) {
  const o = opts && typeof opts === 'object' ? opts : {};
  const lang = (v) => (typeof v === 'string' && LANG_CODES.includes(v) ? v : null);
  const termHintRaw = lang(o.termLang);
  const defHintRaw = o.defLang === undefined ? 'de' : lang(o.defLang);
  return {
    mode: o.mode === 'delimiter' || o.mode === 'lines' ? o.mode : 'auto',
    delimiter: typeof o.delimiter === 'string' && o.delimiter !== '' ? o.delimiter : null,
    cardSeparator: typeof o.cardSeparator === 'string' && o.cardSeparator !== '' ? o.cardSeparator : '\n',
    termHintRaw,
    defHintRaw,
    termHint: termHintRaw && termHintRaw !== 'other' ? termHintRaw : null,
    defHint: defHintRaw && defHintRaw !== 'other' ? defHintRaw : null,
    orient: o.orient !== false,
    swap: o.swap === true,
  };
}

function createContext(o) {
  const cache = new Map();
  const prior = { ...BASE_PRIOR };
  if (o.termHint) prior[o.termHint] += 0.4;
  if (o.defHint) prior[o.defHint] += 0.3;
  return {
    o,
    prior,
    skipped: [],
    warnings: createWarnings(),
    header: null,
    score(text) {
      let s = cache.get(text);
      if (!s) {
        s = scoreLanguages(text);
        cache.set(text, s);
      }
      return s;
    },
  };
}

function hasEvidence(s) {
  return SUPPORTED.some((l) => s[l] >= 0.3);
}

// Probability that `text` is in language A rather than B.
function pairProb(ctx, text, A, B) {
  if (!A || !B || A === B || !text) return 0.5;
  const s = ctx.score(text);
  return 1 / (1 + Math.exp(-PAIR_K * (s[A] - s[B])));
}

function clip(p) {
  return Math.min(1 - CLIP, Math.max(CLIP, p));
}

function nlog(p) {
  return -Math.log(clip(p));
}

// Soft language votes over many texts (with hint-aware prior), sorted by share.
function languageShares(ctx, texts) {
  const votes = { fr: 0, de: 0, en: 0, es: 0, it: 0 };
  let n = 0;
  for (const t of texts) {
    const s = ctx.score(t);
    if (!hasEvidence(s)) continue;
    let max = -Infinity;
    for (const l of SUPPORTED) max = Math.max(max, s[l] + ctx.prior[l]);
    let sum = 0;
    const e = {};
    for (const l of SUPPORTED) sum += e[l] = Math.exp(s[l] + ctx.prior[l] - max);
    for (const l of SUPPORTED) votes[l] += e[l] / sum;
    n++;
  }
  return SUPPORTED.map((lang) => ({ lang, share: n ? votes[lang] / n : 0 })).sort((a, b) => b.share - a.share);
}

function topTwoLanguages(ctx, texts) {
  const shares = languageShares(ctx, texts);
  if (!shares[0].share) return [null, null];
  return [shares[0].lang, shares[1].share >= 0.1 ? shares[1].lang : null];
}

// ---------------------------------------------------------------------------
// Preprocessing & line classification
// ---------------------------------------------------------------------------

// "le week-end–das Wochenende": an en/em dash glued between words, the only
// one on a line without another delimiter.
const GLUED_DASH_RE = /(\p{L}[.!?)]?)[–—](?=[\p{L}(«"„“])/u;
function gluedDash(raw) {
  return (raw.match(/[–—]/g) || []).length === 1 && !/\t|\s[-–—]\s/.test(raw) && GLUED_DASH_RE.test(raw);
}

// Glued dashes are the delimiter of a dash list ("le chat–die Katze" on most
// lines, or mixed with spaced dashes). They are then spaced so that
// normalisation does not turn them into word-internal hyphens; in other lists
// they join compounds ("la relation mère–fille") and become hyphens.
// `dashList`: true/false when the delimiter is known, null to decide here.
function spaceGluedDashes(raws, dashList = null) {
  let rewrite = dashList;
  if (rewrite === null) {
    const content = raws.filter((r) => r.trim());
    const glued = content.filter(gluedDash).length;
    const spaced = content.filter((r) => /\s[-–—]\s/.test(r)).length;
    rewrite = glued > 0 && glued + spaced >= 0.6 * content.length;
  }
  return rewrite ? raws.map((r) => (gluedDash(r) ? r.replace(GLUED_DASH_RE, '$1 - ') : r)) : raws;
}

function makeLine(raw, no) {
  const base = normalizeBasic(raw, { keepTabs: true });
  if (!base) return { no, span: [no], raw, text: '', gap: '', blank: true, kind: null, weak: false, indent: 0 };
  // Keep an explicit empty first/last cell ("\tdie Katze" = missing term).
  const keepEdges = (s) => {
    let out = s.replace(/\t{2,}/g, '\t');
    if (/^[^\S\t\n]*\t/.test(raw) && !out.startsWith('\t')) out = `\t${out}`;
    if (/\t[^\S\t\n]*$/.test(raw) && !out.endsWith('\t')) out = `${out}\t`;
    return out;
  };
  const text = keepEdges(base);
  const gap = keepEdges(normalizeBasic(raw.replace(/[ \u00A0\u2000-\u200A\u202F\u205F\u3000]{2,}/g, '\t'), { keepTabs: true }));
  const lead = raw.match(/^[ \t\u00A0]*/)[0];
  const indent = lead.length + 3 * (lead.split('\t').length - 1);
  return { no, span: [no], raw, text, gap, blank: false, kind: null, weak: false, indent };
}

function quoteCount(s) {
  return (s.match(/"/g) || []).length;
}

function preprocess(source, dashList = null) {
  let t = source;
  if (t.charCodeAt(0) === 0xfeff) t = t.slice(1);
  t = t.replace(/\r\n?/g, '\n').replace(/[\u2028\u2029\u0085\v\f]/g, '\n');
  const raws = spaceGluedDashes(t.split('\n'), dashList);
  const lines = [];
  for (let i = 0; i < raws.length; i++) {
    let raw = raws[i];
    const span = [i + 1];
    // A quoted CSV field that continues on the next line(s).
    if (quoteCount(raw) % 2 === 1 && /(?:^|[,;\t|])\s*"[^"]*$/.test(raw)) {
      let joined = raw;
      for (let j = i + 1; j < raws.length && j <= i + 4 && raws[j].trim(); j++) {
        joined += ` ${raws[j]}`;
        if (quoteCount(joined) % 2 === 0) {
          raw = joined;
          for (let k = i + 1; k <= j; k++) span.push(k + 1);
          i = j;
          break;
        }
      }
    }
    const line = makeLine(raw, span[0]);
    line.span = span;
    lines.push(line);
  }
  return lines;
}

function displayText(line) {
  return line.text.replace(/\t/g, ' ').trim();
}

function skip(ctx, line, reason) {
  line.kind = reason;
  ctx.skipped.push({ line: line.no, text: displayText(line), reason });
}

function stripMarker(s) {
  let out = s.replace(MARKER_RE, '');
  // A leading number cell ("12<TAB>le chat - die Katze") is numbering, unless it is the term itself.
  if (NUMBER_CELL_RE.test(out)) {
    const rest = out.replace(NUMBER_CELL_RE, '');
    if (/\t| - | = |: /.test(rest)) out = rest;
  }
  return out;
}

// Header row naming the languages or columns ("Französisch | Deutsch", "Begriff - Definition").
function headerRow(text) {
  const words = text.split(/[^\p{L}.]+/u).map((w) => w.replace(/\.+$/, '')).filter(Boolean);
  if (words.length < 2 || words.length > 6) return null;
  if (words.every((w) => CODES.has(w)) && new Set(words).size === words.length) {
    return { left: words[0].toLowerCase(), right: words[1].toLowerCase() };
  }
  const langs = [];
  const labels = [];
  for (const w of words) {
    const lw = w.toLowerCase();
    if (LANG_NAMES.has(lw)) langs.push(LANG_NAMES.get(lw));
    else if (LABELS.has(lw)) labels.push(LABELS.get(lw));
    else return null;
  }
  if (new Set(langs).size !== langs.length || new Set(labels).size !== labels.length) return null;
  if (langs.length >= 2) return { left: langs[0], right: langs[1] };
  return { left: null, right: null };
}

// Number vocabulary ("11 - onze", or "onze" / "11" on alternating lines):
// the numbers are the definitions, not list markers or page numbers.
function numberVocabulary(ctx, lines) {
  const flat = lines.filter((l) => !l.blank).map(displayText);
  const numbered = flat.filter((t) => NUMBERED_RE.test(t));
  let keepMarkers = false;
  if (numbered.length >= 2 && numbered.length >= 0.8 * flat.length) {
    // "1 - le chat - die Katze" is still a numbered list, and so are numbered
    // lines that alternate between two languages.
    keepMarkers = numberWords(ctx, numbered.map((t) => t.replace(NUMBERED_RE, '')));
  }
  // Bare number lines that alternate 1:1 with such word lines are number
  // vocabulary ("onze" / "11"). Before delimited lines ("1" / "le chat - die
  // Katze"), term and definition lines ("1" / "le chat" / "die Katze") or
  // bilingual lines they number the rows of a table copied cell by cell, and
  // elsewhere they are page numbers.
  const bare = flat.map((t) => BARE_NUMBER_RE.test(t));
  let alternations = 0;
  for (let k = 1; k < flat.length; k++) if (bare[k] !== bare[k - 1]) alternations++;
  const keepBare =
    bare.filter(Boolean).length >= 3 && alternations >= 0.8 * (flat.length - 1) && numberWords(ctx, flat.filter((_, k) => !bare[k]));
  return { keepMarkers, keepBare };
}

// The word side of number vocabulary: one language, no delimiter and no
// second language inside a line.
function numberWords(ctx, words) {
  if (words.filter((t) => /\t| - | = |=| : |: |;|\||->|→/.test(t)).length > 0.2 * words.length) return false;
  const shares = languageShares(ctx, words);
  if (shares[1].share >= 0.3) return false;
  const [L1, L2] = [shares[0].lang, shares[1].lang];
  return words.filter((t) => languageSplit(ctx, t, L1, L2)).length <= 0.2 * words.length;
}

function classify(ctx, lines) {
  const numbers = numberVocabulary(ctx, lines);
  for (const line of lines) {
    if (line.blank) continue;
    const flat = displayText(line);
    if (numbers.keepBare && BARE_NUMBER_RE.test(flat)) continue;
    if (PAGE_RE.test(flat)) {
      skip(ctx, line, 'pageNumber');
      continue;
    }
    if (!/\p{L}/u.test(flat) || URL_RE.test(flat)) {
      skip(ctx, line, 'noise');
      continue;
    }
    if (!numbers.keepMarkers || !NUMBERED_RE.test(flat)) {
      line.text = stripMarker(line.text);
      line.gap = stripMarker(line.gap);
    }
    const t = displayText(line);
    if (!/\p{L}/u.test(t)) {
      skip(ctx, line, 'noise');
      continue;
    }
    const header = headerRow(t);
    if (header) {
      if (!ctx.header && header.left) ctx.header = header;
      skip(ctx, line, 'heading');
      continue;
    }
    const kw = t.match(KEYWORD_RE);
    if (kw) {
      const rest = t.slice(kw[0].length).replace(/^[\s:.-]+/, '');
      // "Vocabulaire : les animaux" is a title; "vocabulary - Wortschatz" is a card.
      const title = /^\p{Lu}/u.test(t) && !(KEYWORD_RE.test(rest) && !/\s/.test(rest));
      if (/\d/.test(rest) || ROMAN_RE.test(rest) || (rest && title && ALWAYS_HEADING_RE.test(t))) {
        skip(ctx, line, 'heading');
        continue;
      }
      if (!rest) line.weak = true;
    }
    if (/^\p{Lu}$/u.test(t)) {
      skip(ctx, line, 'heading');
      continue;
    }
    // Single letters and ALL-CAPS lines are probably titles, but may still pair.
    if (/^\p{Ll}$/u.test(t) || (/^[^\p{Ll}]+$/u.test(t) && (t.match(/\p{Lu}/gu) || []).length >= 4)) line.weak = true;
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Splitting helpers
// ---------------------------------------------------------------------------

// Delimiter-separated fields with double-quote support ("a, b","c").
function csvSplit(text, delim) {
  const cells = [];
  let i = 0;
  for (;;) {
    let j = i;
    while (text[j] === ' ') j++;
    if (text[j] === '"') {
      let k = j + 1;
      let val = '';
      while (k < text.length) {
        if (text[k] === '"') {
          if (text[k + 1] === '"') {
            val += '"';
            k += 2;
            continue;
          }
          break;
        }
        val += text[k++];
      }
      if (k >= text.length) {
        // Unterminated quote: keep the rest verbatim.
        cells.push(text.slice(j).trim());
        break;
      }
      const next = text.indexOf(delim, k + 1);
      if (next === -1) {
        cells.push((val + text.slice(k + 1)).trim());
        break;
      }
      cells.push((val + text.slice(k + 1, next)).trim());
      i = next + delim.length;
    } else {
      const next = text.indexOf(delim, i);
      if (next === -1) {
        cells.push(text.slice(i).trim());
        break;
      }
      cells.push(text.slice(i, next).trim());
      i = next + delim.length;
    }
  }
  return { cells };
}

// Strip one pair of surrounding quotes: "x", “x”, „x“, «x», »x«, ‹x›, 'x'.
const QUOTE_PAIRS = ['""', '“”', '„“', '„”', '«»', '»«', '‹›', "''"];
function unquote(s) {
  const t = s.trim();
  if (t.length >= 2 && QUOTE_PAIRS.includes(t[0] + t[t.length - 1])) {
    const inner = t.slice(1, -1);
    if (!inner.includes(t[0]) && !inner.includes(t[t.length - 1])) return inner.trim();
  }
  return t;
}

function customCandidate(delim) {
  if (delim === '\t') return { id: '\t', kind: 'cells' };
  if (delim === ',' || delim === ';' || delim === '|') return { id: delim, kind: 'csv' };
  const spaced = delim.trim() === delim && /^[^\p{L}\p{N}]+$/u.test(delim) ? ` ${delim} ` : null;
  return { id: delim, kind: 'first', spaced };
}

// Split one line with a candidate: { parts, joiner }. One part = delimiter absent.
function splitWith(line, cand) {
  if (cand.kind === 'cells' || cand.kind === 'gap') {
    const src = cand.kind === 'gap' ? line.gap : line.text;
    if (!src.includes('\t')) return { parts: [src.trim()], joiner: ', ' };
    return { parts: csvSplit(src, '\t').cells.map(unquote), joiner: ', ' };
  }
  const text = line.text.replace(/\t/g, ' ').trim();
  if (cand.kind === 'csv') {
    const { cells } = csvSplit(text, cand.id);
    const joiner = cand.id === ';' || cand.id === ',' ? `${cand.id} ` : ', ';
    // Table borders: "| a | b |", or only one of them when OCR cropped the other edge.
    if (cand.id === '|' && cells.length > 2) {
      const lead = cells[0] === '';
      const trail = cells[cells.length - 1] === '';
      if (lead && trail) return { parts: cells.slice(1, -1), joiner };
      if (lead || trail) return { parts: lead ? cells.slice(1) : cells.slice(0, -1), joiner };
    }
    return { parts: cells, joiner };
  }
  if (cand.kind === 'regex') {
    const parts = text.split(cand.re).map((p) => unquote(p));
    return { parts, joiner: cand.joiner || cand.id };
  }
  const delim = cand.spaced && text.includes(cand.spaced) ? cand.spaced : cand.id;
  if (text.includes(delim)) return { parts: text.split(delim).map(unquote), joiner: delim };
  // "le chat -" / "= die Katze": delimiter present but one side empty.
  const bare = delim.trim();
  if (bare && bare !== delim) {
    if (text.endsWith(` ${bare}`)) return { parts: [unquote(text.slice(0, -bare.length - 1)), ''], joiner: delim };
    if (text.startsWith(`${bare} `)) return { parts: ['', unquote(text.slice(bare.length + 1))], joiner: delim };
  }
  return { parts: [text], joiner: delim };
}

// How many cards a split represents for detection purposes (0 = not a pairing).
function pairingCount(parts, cand) {
  if (parts.length < 2) return 0;
  const filled = parts.filter((p) => p !== '').length;
  if (cand === COMMA || cand === TIGHT_COMMA) return parts.length === 2 && filled === 2 ? 1 : 0;
  if ((cand.kind === 'cells' || cand.kind === 'gap') && parts.length >= 4 && parts.length % 2 === 0 && filled === parts.length) {
    return parts.length / 2;
  }
  if (filled === parts.length) return 1;
  return parts.length === 2 && filled === 1 ? 1 : 0;
}

// Reduce >2 parts to [term, definition] at the position with the strongest
// language contrast (first occurrence when languages are unknown). Every part
// votes with its raw score margin: clipped probabilities saturate for clear
// text, so they cannot tell the split points apart. `uncertain` marks a split
// that is a close call or leaves a clearly misplaced part on either side.
function resolveSplit(ctx, rawParts, A, B, joiner) {
  if (rawParts.length <= 2) return { parts: rawParts, uncertain: false };
  const parts = rawParts.filter((p) => p !== '');
  if (parts.length < 2) return { parts: [parts[0] || '', ''], uncertain: false };
  let best = 1;
  let uncertain = false;
  if (A && B && A !== B) {
    const d = parts.map((p) => {
      const s = ctx.score(p);
      return s[A] - s[B];
    });
    const prefixes = [];
    let prefix = 0;
    for (let k = 1; k < parts.length; k++) {
      prefix += d[k - 1];
      prefixes.push(prefix);
      if (prefix > prefixes[best - 1] + 1e-9) best = k;
    }
    const runnerUp = Math.max(-Infinity, ...prefixes.filter((_, i) => i !== best - 1));
    const misplaced = d.some((v, i) => (i < best ? v <= -SPLIT_MISFIT : v >= SPLIT_MISFIT));
    uncertain = misplaced || prefixes[best - 1] - runnerUp < SPLIT_MARGIN;
  }
  return { parts: [parts.slice(0, best).join(joiner), parts.slice(best).join(joiner)], uncertain };
}

function resolveParts(ctx, rawParts, A, B, joiner) {
  return resolveSplit(ctx, rawParts, A, B, joiner).parts;
}

// Word segments of a line: split at whitespace and at hyphens, commas and
// semicolons glued between letters ("chat-die", "plage,der"), keeping
// offsets so the original text can be cut.
function segments(text) {
  const segs = [];
  const re = /\S+/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    let start = m.index;
    const chunk = m[0];
    for (let i = 1; i < chunk.length - 1; i++) {
      if ('-,;'.includes(chunk[i]) && /\p{L}/u.test(chunk[i - 1]) && /\p{L}/u.test(chunk[i + 1])) {
        segs.push({ start, end: m.index + i });
        start = m.index + i + 1;
      }
    }
    segs.push({ start, end: m.index + chunk.length });
  }
  return segs;
}

// Cut a line before segment k, dropping the separator characters around the cut.
function cutAt(text, segs, k) {
  return {
    left: unquote(text.slice(0, segs[k - 1].end).replace(/[\s\-=:;,/|>→]+$/u, '')),
    right: unquote(text.slice(segs[k].start).replace(/^[\s\-=:;,/|<>→]+/u, '')),
  };
}

// Split a single bilingual line ("le chat die Katze") at the segment boundary
// with the strongest language contrast. Segment scores pick the split point
// cheaply; the two halves are then verified with full-context scoring.
function languageSplit(ctx, rawText, A, B) {
  if (!A || !B || A === B) return null;
  const text = rawText.replace(/\t/g, ' ');
  const segs = segments(text);
  if (segs.length < 2 || segs.length > 24) return null;
  const tokens = segs.map((sg) => text.slice(sg.start, sg.end));
  const d = tokens.map((tok) => {
    const s = ctx.score(tok);
    return s[A] - s[B];
  });
  const total = d.reduce((a, b) => a + b, 0);
  let prefix = 0;
  let best = null;
  for (let k = 1; k < tokens.length; k++) {
    prefix += d[k - 1];
    const suffix = total - prefix;
    const v1 = Math.min(prefix, -suffix);
    const v2 = Math.min(-prefix, suffix);
    if (!best || v1 > best.v) best = { k, v: v1, order: 1 };
    if (v2 > best.v) best = { k, v: v2, order: -1 };
  }
  if (!best || best.v < 1) return null;
  const { left, right } = cutAt(text, segs, best.k);
  if (!/\p{L}/u.test(left) || !/\p{L}/u.test(right)) return null;
  const pl = pairProb(ctx, left, A, B);
  const pr = pairProb(ctx, right, A, B);
  const score = best.order === 1 ? Math.min(pl, 1 - pr) : Math.min(1 - pl, pr);
  return score >= 0.8 ? { left, right, order: best.order, score } : null;
}

// A line of exactly two words that lean to different languages ("chien Hund":
// "chien" looks a little German). There is only one place to cut, so each word
// leaning at least one unit to its side is enough where languageSplit asks for
// a clear call on both. Only used once the list is known to hold both
// languages on every line.
function twoWordSplit(ctx, rawText, A, B) {
  const text = rawText.replace(/\t/g, ' ');
  const segs = segments(text);
  if (segs.length !== 2 || A === B) return null;
  const d = segs.map((sg) => {
    const s = ctx.score(text.slice(sg.start, sg.end));
    return s[A] - s[B];
  });
  if (Math.min(Math.abs(d[0]), Math.abs(d[1])) < 1 || (d[0] > 0) === (d[1] > 0)) return null;
  const { left, right } = cutAt(text, segs, 1);
  if (!/\p{L}/u.test(left) || !/\p{L}/u.test(right)) return null;
  const order = d[0] > 0 ? 1 : -1;
  const pl = pairProb(ctx, left, A, B);
  const pr = pairProb(ctx, right, A, B);
  const score = order === 1 ? Math.min(pl, 1 - pr) : Math.min(1 - pl, pr);
  return { left, right, order, score };
}

function lastWord(s) {
  const m = s.toLowerCase().match(/[\p{L}']+$/u);
  return m ? m[0] : '';
}

// Does `prev` look unfinished (trailing comma, hyphenation, open article)?
function looksUnfinished(prev) {
  return /[,;/(]$/.test(prev) || /\p{L}-$/u.test(prev) || OPEN_ENDINGS.has(lastWord(prev));
}

// Cost of treating `next` as the continuation of `prev` on the same side.
function mergeCost(prev, next) {
  if (looksUnfinished(prev) || /^[,;/)]/.test(next)) return 0.5;
  if (/^\p{Lu}/u.test(next)) return 4.5;
  // "Où est" + "la gare ?": an article starts an entry, unless it ends a sentence.
  if (ENTRY_START_RE.test(next) && !(/[.!?…]$/u.test(next) && /^\p{Lu}/u.test(prev) && !/[.!?…:]$/u.test(prev))) return 4.5;
  return MERGE_COST;
}

// A section heading labels a group of entries: a capitalised line ending in
// a colon or led by a letter or number ("Les couleurs:", "B) Couleurs et
// formes"), or a plural word or two ("Les couleurs", "Adjectifs"). Wrapped
// sentence starts ("Thank you", "Je voudrais un café") are none of these.
function looksLikeHeading(text, lang) {
  if (!/^[\p{Lu}\d]/u.test(text) || text.includes(',') || /[.!?…]$/u.test(text) || looksUnfinished(text)) return false;
  if (/:$/.test(text) || /^(?:[A-Z]|\d{1,2}|[IVX]{1,4})[.)]\s/.test(text)) return true;
  const words = text.split(' ');
  return words.length <= 3 && (lang === 'it' ? /[ie]$/u : /[sx]$/u).test(words[words.length - 1]);
}

// Lines that continue a sentence rather than start an entry: they end it
// ("aujourd'hui ?") or open with a conjunction or relative ("et quel âge as-tu ?").
function continuesSentence(text) {
  return /[.!?…]$/u.test(text) || /^(?:(?:et|ou|que|qui|dont|and|or|of|than)\s|qu')/iu.test(text);
}

function wordCount(text) {
  return (text.match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu) || []).length;
}

// Does a term of `termWords` words match a definition of `defWords` words in
// length at least as well as the term without its first line (`restWords`)?
// Translations have similar lengths: "The weather is nice" + "today" =
// "Das Wetter ist heute schön", but "Les couleurs" + "rouge" = "rot".
function restMatchesLength(termWords, restWords, defWords) {
  const misfit = (w) => Math.abs(Math.log(Math.max(1, w) / Math.max(1, defWords)));
  return misfit(restWords) <= misfit(termWords);
}

// Join a continuation line onto the previous part.
function joinParts(a, b) {
  if (!a) return b;
  if (!b) return a;
  if (/\p{L}-$/u.test(a)) return /^\p{Ll}/u.test(b) ? a.slice(0, -1) + b : a + b;
  if (/^[,;:)/]/.test(b)) return a + b;
  if (/[,;:/(]$/.test(a) || OPEN_ENDINGS.has(lastWord(a))) return `${a} ${b}`;
  // A wrapped sentence: "Comment allez-vous" + "aujourd'hui ?", "The weather is nice" + "today".
  const sentenceStart = /^\p{Lu}/u.test(a) && !a.includes(',') && a.split(' ').length >= 3;
  if (/^\p{Ll}/u.test(b) && !/[.!?…]$/u.test(a) && (/[.!?…]$/u.test(b) || sentenceStart)) return `${a} ${b}`;
  if (!a.includes(',') && /^\p{Ll}[\p{Ll}'-]*$/u.test(b)) {
    // A German verb ends its phrase: "sich die Zähne" + "putzen".
    if (/(?:en|ern|eln)$/u.test(b) && DE_ARTICLE_RE.test(` ${a}`) && /\p{Lu}\p{Ll}*$/u.test(a)) return `${a} ${b}`;
    // A French verb phrase cut inside its object: "faire la grasse" + "matinée".
    if (a.split(' ').length >= 3 && FR_OBJECT_END_RE.test(a)) return `${a} ${b}`;
  }
  return `${a}, ${b}`;
}

function makePair(term, def, lines, extra = {}) {
  return {
    term: term || '',
    def: def || '',
    lines: [...new Set(lines)].sort((a, b) => a - b),
    merged: false,
    langSplit: false,
    uncertain: false, // structure was a guess: shown as lowConfidence
    ...extra,
  };
}

// ---------------------------------------------------------------------------
// Delimited lists
// ---------------------------------------------------------------------------

// Content lines with a flag for lines that need not contain the delimiter:
// weak headings, wrapped continuation lines and section titles.
function contentWithOptional(lines) {
  const out = [];
  let prev = null;
  let afterGap = true;
  for (const line of lines) {
    if (line.blank) {
      prev = null;
      afterGap = true;
      continue;
    }
    if (line.kind) {
      if (line.kind === 'heading') {
        prev = null;
        afterGap = true;
      }
      continue;
    }
    const t = displayText(line);
    const continuation = line.indent >= 2 || (prev !== null && looksUnfinished(displayText(prev)));
    const title = afterGap && /^[\p{Lu}\d]/u.test(t) && !t.includes(',') && t.split(' ').length <= 6;
    out.push({ line, optional: line.weak || continuation || title });
    prev = line;
    afterGap = false;
  }
  return out;
}

function detectDelimiter(ctx, lines) {
  const content = contentWithOptional(lines);
  if (!content.length) return null;
  const ratioFor = (cand, strict) => {
    let n = 0;
    let denom = 0;
    for (const { line, optional } of content) {
      const { parts } = splitWith(line, cand);
      const ok = strict ? parts.length === 2 && parts[0] !== '' && parts[1] !== '' : pairingCount(parts, cand) > 0;
      if (ok) {
        n++;
        denom++;
      } else if (!optional) {
        denom++;
      }
    }
    return n >= 1 && n >= 0.3 * content.length ? n / Math.max(1, denom) : 0;
  };
  let best = null;
  for (const cand of CANDIDATES) {
    const ratio = ratioFor(cand, false);
    if (ratio >= 0.7 && (!best || ratio > best.ratio + 0.05)) best = { cand, ratio };
  }
  if (best) return pageColumnsGap(ctx, content, best.cand) ? GAP : best.cand;

  // Comma only as a last resort: exactly two fields on >= 80% of lines and
  // the two sides must look like different languages. Quizlet's export puts a
  // bare comma between the sides, so ", " inside a field is then kept.
  for (const comma of [COMMA, TIGHT_COMMA]) {
    if (ratioFor(comma, true) < 0.8) continue;
    const pairs = [];
    for (const { line } of content) {
      const { parts } = splitWith(line, comma);
      if (parts.length === 2 && parts[0] && parts[1]) pairs.push(parts);
    }
    if (sidesContrast(ctx, pairs)) return comma;
  }
  return null;
}

// "le chat – die Katze      le chien – der Hund": the wide gap separates two
// page columns, and the winning delimiter splits each of them into a pair.
// The right page column may end early (the last page of a list), so a few
// rows suffice when every wide row splits like that and the halves contrast.
function pageColumnsGap(ctx, content, winner) {
  if (!INNER_CANDIDATES.includes(winner)) return false;
  let wide = 0;
  let paired = 0;
  const halves = [];
  for (const { line } of content) {
    const cells = splitWith(line, GAP).parts;
    if (cells.length < 2) continue;
    wide++;
    // An empty cell is a page column that ended early.
    const split = cells.filter(Boolean).map((c) => splitWith({ text: c }, winner).parts);
    if (split.every((parts) => parts.length === 2 && parts[0] && parts[1])) {
      paired++;
      halves.push(...split);
    }
  }
  if (!wide || paired < 0.8 * wide) return false;
  return (wide >= 2 && wide >= 0.7 * content.length) || (paired === wide && sidesContrast(ctx, halves));
}

function sidesContrast(ctx, pairs) {
  if (!pairs.length) return false;
  const L = detectColumn(pairs.map((p) => p[0])).lang;
  const R = detectColumn(pairs.map((p) => p[1])).lang;
  if (L === 'unknown' || R === 'unknown' || L === R) return false;
  let agree = 0;
  for (const [a, b] of pairs) if (pairProb(ctx, a, L, R) > 0.5 && pairProb(ctx, b, R, L) > 0.5) agree++;
  return agree / pairs.length >= 0.6;
}

// Whole lists on one line: "le chat - die Katze; le chien - der Hund".
function detectInline(ctx, content) {
  for (const sep of [';', ',']) {
    const withSep = content.filter((l) => l.text.includes(sep)).length;
    if (withSep / content.length < 0.6) continue;
    const records = [];
    for (const line of content) {
      for (const piece of csvSplit(line.text.replace(/\t/g, ' '), sep).cells) {
        if (piece && /\p{L}/u.test(piece)) records.push(makeLine(piece, line.no));
      }
    }
    // Each source line must hold several pairs, otherwise `sep` is part of the entries.
    if (records.length < content.length * 2) continue;
    for (const cand of CANDIDATES.concat(sep === ';' ? [COMMA] : [])) {
      if (cand.kind === 'cells' || cand.kind === 'gap' || cand.id === sep) continue;
      const pairs = [];
      for (const r of records) {
        const { parts } = splitWith(r, cand);
        if (parts.length === 2 && parts[0] && parts[1]) pairs.push(parts);
      }
      if (pairs.length / records.length < 0.7) continue;
      if (cand === COMMA && !sidesContrast(ctx, pairs)) continue;
      return parseDelimitedLines(ctx, records, cand);
    }
    // Records without a common delimiter ("le chat-die Katze;le chien-der Hund").
    const bilingual = detectBilingual(ctx, records);
    if (bilingual) return bilingual;
  }
  return null;
}

// Two page columns of "term – definition" entries side by side: every cell
// holds a whole pair. Sets e.groups (one [term, def] per cell) and returns true.
function splitInnerPairs(ctx, entries) {
  const rows = entries.filter((e) => !e.skip && e.parts.filter(Boolean).length >= 2);
  if (!rows.length) return false;
  for (const inner of INNER_CANDIDATES) {
    const pairs = [];
    let cells = 0;
    for (const e of rows) {
      for (const cell of e.parts) {
        if (!cell) continue;
        cells++;
        const { parts } = splitWith({ text: cell }, inner);
        if (parts.length === 2 && parts[0] && parts[1]) pairs.push(parts);
      }
    }
    // The halves must contrast, unlike form tables ("aller - allé<TAB>gehen - gegangen").
    if (pairs.length < 0.8 * cells || !sidesContrast(ctx, pairs)) continue;
    for (const e of entries) {
      if (e.skip || !e.parts.some(Boolean)) continue;
      // An empty cell is a page column that ended early; it keeps its group index.
      const groups = e.parts.map((cell) => (cell ? splitWith({ text: cell }, inner).parts : ['', '']));
      if (groups.every((g, i) => !e.parts[i] || (g.length === 2 && (g[0] || g[1])))) {
        e.groups = groups;
        e.count = groups.filter(([t, d]) => t || d).length;
      }
    }
    return true;
  }
  return false;
}

const LABEL_STOP = new Set('der die das den dem des ein eine einen the a an le la les l un une el los las il lo gli'.split(' '));
const tokensOf = (s) => s.toLowerCase().match(/\p{L}+/gu) || [];

// Word class / gender columns repeat the same label ("Nomen, f.", "Verb")
// that never occurs in the translation column.
function isLabelColumn(col, other) {
  if (col.length < 3) return false;
  const seen = new Set(other.flatMap(tokensOf));
  const counts = new Map();
  for (const cell of col) for (const t of new Set(tokensOf(cell))) counts.set(t, (counts.get(t) || 0) + 1);
  for (const [t, n] of counts) if (n >= col.length / 2 && !seen.has(t) && !LABEL_STOP.has(t)) return true;
  return false;
}

const isSentence = (t) => /[.!?]$/.test(t) && t.split(/\s+/).length >= 3;

// Rows with three cells: term | translation | example or note, Klett-style
// term | example | translation, or masculine | feminine | translation. Drops
// the column that is not part of the pair; rows that keep three cells are
// merged by language later, and marked uncertain when the columns are unclear.
function reduceThreeCells(ctx, entries, cand) {
  const live = entries.filter((e) => !e.skip && e.parts.length >= 2);
  const rows = live.filter((e) => e.parts.length === 3 && e.parts.every(Boolean));
  if (rows.length < 2 || rows.length < 0.6 * live.length) return;
  const cols = [0, 1, 2].map((c) => rows.map((e) => e.parts[c]));
  const langs = cols.map((col) => {
    const { lang } = detectColumn(col);
    return lang === 'unknown' ? null : lang;
  });
  const [l0, l1, l2] = langs;
  // An example-sentence column is clearly wordier than the other two, or the
  // only one holding whole sentences ("Die Katze schläft.").
  const avg = cols.map((col) => col.reduce((n, t) => n + t.split(/\s+/).length, 0) / col.length);
  const wordy = [0, 1, 2].filter((i) => avg[i] >= 4 && avg.every((o, j) => j === i || avg[i] >= 2 * o));
  const share = cols.map((col) => col.filter(isSentence).length / col.length);
  const sentences = [0, 1, 2].filter((i) => share[i] >= 0.8 && share.every((s, j) => j === i || s <= 0.2));
  let drop = wordy.length === 1 ? wordy[0] : sentences.length === 1 ? sentences[0] : -1;
  let uncertain = false;
  if (drop < 0) {
    if (l0 && l1 && l0 !== l1 && (l2 !== l1 || isLabelColumn(cols[2], cols[1]))) drop = 2;
    else if (l1 && l2 && l1 !== l2 && l0 !== l1 && l0 !== l2) drop = 0;
  }
  // Never drop the only column in the translation language: a misdetected
  // middle column (feminine forms) or a third language (English | French |
  // German) is merged by language instead.
  const target = ctx.o.defHint || 'de';
  if (drop >= 0 && langs[drop] === target && !langs.some((l, i) => i !== drop && l === target)) drop = -1;
  // Unclear outer columns, or three languages that cannot share two sides.
  if (drop < 0) uncertain = !(l0 && l2 && l0 !== l2) || Boolean(l1 && l1 !== l0 && l1 !== l2);
  for (const e of rows) {
    if (drop >= 0) {
      e.parts = e.parts.filter((_, i) => i !== drop);
      e.count = pairingCount(e.parts, cand);
    } else {
      e.uncertain = uncertain;
    }
  }
}

function parseDelimitedLines(ctx, lines, cand) {
  const cellKind = cand.kind === 'cells' || cand.kind === 'gap';
  // Pass 1: split every line.
  const entries = lines.map((line) => {
    if (line.blank || line.kind) return { line, skip: true };
    const { parts, joiner } = splitWith(line, cand);
    return { line, parts, joiner, count: pairingCount(parts, cand) };
  });
  const pageColumns = cellKind && splitInnerPairs(ctx, entries);
  if (cellKind && !pageColumns) reduceThreeCells(ctx, entries, cand);

  // Column languages from clean two-part lines (else from the outer parts of longer lines).
  let two = entries.filter((e) => !e.skip && e.parts.length === 2 && e.parts[0] && e.parts[1]).map((e) => e.parts);
  if (!two.length) {
    two = entries
      .filter((e) => !e.skip && e.parts.length > 2 && e.parts[0] && e.parts[e.parts.length - 1])
      .map((e) => [e.parts[0], e.parts[e.parts.length - 1]]);
  }
  let A = detectColumn(two.map((p) => p[0])).lang;
  let B = detectColumn(two.map((p) => p[1])).lang;
  if (A === 'unknown' || A === B) A = null;
  if (B === 'unknown' || !A) B = null;

  // Pass 2: build pairs; lines without the delimiter are collected in runs.
  const pairs = [];
  // Two page columns are read left column first, even when the right one ends early.
  const multi = entries.filter((e) => !e.skip && e.count >= 2).length;
  const columnMajor =
    (pageColumns && multi >= 1) || (cellKind && multi >= 2 && multi / Math.max(1, entries.filter((e) => e.count >= 1).length) >= 0.6);
  let run = [];
  let prevPair = null; // pair directly above (no blank line or heading in between)
  const flushRun = (nextPair) => {
    if (run.length) handleRun(ctx, run, prevPair, nextPair, A, B, pairs);
    run = [];
  };
  for (const e of entries) {
    if (e.skip) {
      if (e.line.blank || e.line.kind === 'heading') {
        flushRun(null);
        prevPair = null;
      }
      continue;
    }
    if (!e.groups && (e.parts.length < 2 || (e.line.weak && e.count === 0))) {
      run.push(e.line);
      continue;
    }
    let groups = [];
    let uncertain = Boolean(e.uncertain);
    if (e.groups) {
      groups = e.groups;
    } else if (cellKind && e.count >= 2) {
      for (let g = 0; g < e.parts.length; g += 2) groups.push([e.parts[g], e.parts[g + 1]]);
    } else {
      const split = resolveSplit(ctx, e.parts, A, B, e.joiner);
      groups.push(split.parts);
      uncertain = uncertain || split.uncertain;
    }
    let first = null;
    groups.forEach(([term, def], g) => {
      if (!term && !def) return;
      const pair = makePair(term, def, e.line.span, { group: g, uncertain });
      pairs.push(pair);
      if (!first) first = pair;
    });
    flushRun(first);
    if (first) prevPair = pairs[pairs.length - 1];
  }
  flushRun(null);

  if (columnMajor) {
    pairs.forEach((p, i) => (p.order = i));
    pairs.sort((a, b) => (a.group || 0) - (b.group || 0) || a.order - b.order);
  }
  return { pairs, format: 'delimited', delimiter: cand.kind === 'gap' ? '  ' : cand.id };
}

// Lines inside a delimited list that do not contain the delimiter.
function handleRun(ctx, run, prevPair, nextPair, A, B, pairs) {
  let i = 0;
  let j = run.length;
  const bilingual = (line) => {
    const s = languageSplit(ctx, displayText(line), A, B);
    return Boolean(s && s.order === 1);
  };
  // Wrapped definition of the pair above.
  while (i < j && prevPair && prevPair.def && !bilingual(run[i]) && isContinuation(ctx, run[i], prevPair.def, B, A)) {
    prevPair.def = joinParts(prevPair.def, displayText(run[i]));
    prevPair.lines = [...new Set(prevPair.lines.concat(run[i].span))].sort((a, b) => a - b);
    prevPair.merged = true;
    ctx.warnings.line('merged', run[i].no);
    i++;
  }
  // Wrapped term that continues on the next delimited line.
  if (j > i && nextPair && nextPair.term && !bilingual(run[j - 1]) && isTermPrefix(ctx, displayText(run[j - 1]), A, B)) {
    nextPair.term = joinParts(displayText(run[j - 1]), nextPair.term);
    nextPair.lines = [...new Set(nextPair.lines.concat(run[j - 1].span))].sort((a, b) => a - b);
    nextPair.merged = true;
    ctx.warnings.line('merged', run[j - 1].no);
    j--;
  }
  const rest = run.slice(i, j);
  if (!rest.length) return;
  const items = rest.map((line) => ({ line, text: displayText(line), block: 0, weak: line.weak }));
  const steps = alignBest(ctx, items, A, B, { boundary: 'none', allowSplit: true, unpairedCost: RUN_UNPAIRED_COST });
  const created = [];
  for (const st of steps) {
    if (st.type === 'skip') unpairedLine(ctx, items[st.index], true, A, B, st.heading);
    else created.push(stepToPair(ctx, items, st));
  }
  const insertAt = nextPair ? pairs.indexOf(nextPair) : -1;
  if (insertAt >= 0) pairs.splice(insertAt, 0, ...created);
  else pairs.push(...created);
}

function isContinuation(ctx, line, prevDef, defLang, termLang) {
  const text = displayText(line);
  if (!/\p{L}/u.test(text) || line.weak) return false;
  const known = Boolean(defLang && termLang);
  const p = pairProb(ctx, text, defLang, termLang);
  if (known && p < 0.6) return false;
  // Indented into the definition column (PDF / fixed-width layouts).
  if (line.indent >= 2) return true;
  if (looksUnfinished(prevDef) || /^[,;/)(]/.test(text)) return true;
  return known && /^\p{Ll}/u.test(text) && !ENTRY_START_RE.test(text) && p >= 0.85;
}

function isTermPrefix(ctx, text, termLang, defLang) {
  if (!termLang || !defLang || !/^\p{Ll}/u.test(text)) return false;
  if (pairProb(ctx, text, termLang, defLang) < 0.6) return false;
  return looksUnfinished(text);
}

function unpairedLine(ctx, item, inDelimitedList, A, B, isHeading = false) {
  const t = item.text;
  const words = t.split(' ').length;
  let heading = isHeading || item.weak || KEYWORD_RE.test(t) || /:$/.test(t);
  if (!heading && /^[\p{Lu}\d]/u.test(t)) heading = inDelimitedList || (words >= 2 && !t.includes(','));
  if (!heading && inDelimitedList && A && B) {
    const p = pairProb(ctx, t, A, B);
    heading = p > 0.25 && p < 0.75; // belongs to neither column: treat as a title
  }
  ctx.skipped.push({ line: item.line.no, text: t, reason: heading ? 'heading' : 'unpaired' });
  if (!heading) ctx.warnings.line('unpaired', item.line.no);
}

// ---------------------------------------------------------------------------
// Line-based lists: alignment by dynamic programming
// ---------------------------------------------------------------------------

// A line split at the first explicit delimiter whose halves contrast (any
// delimiter when the languages are unknown). pl/pr = P(left/right half is A).
function delimiterSplit(ctx, line, A, B) {
  const known = Boolean(A && B && A !== B);
  for (const cand of CANDIDATES) {
    if (cand.kind === 'gap') continue;
    const split = splitWith(line, cand);
    if (split.parts.length < 2 || split.parts.some((p) => p === '')) continue;
    const [left, right] = resolveParts(ctx, split.parts, A, B, split.joiner);
    if (!left || !right) continue;
    if (!known) return { left, right, pl: 0.5, pr: 0.5, delimId: cand.id };
    const pl = pairProb(ctx, left, A, B);
    const pr = pairProb(ctx, right, A, B);
    if ((pl - 0.5) * (pr - 0.5) < 0 && Math.abs(pl - pr) >= 0.3) return { left, right, pl, pr, delimId: cand.id };
  }
  return null;
}

// A line that holds both languages: delimiter split with language contrast,
// or a pure language split. pl/pr = P(left/right half is language A).
function bilingualParts(ctx, item, A, B, known) {
  const split = delimiterSplit(ctx, item.line, known ? A : null, known ? B : null);
  if (split) return { ...split, delim: true };
  if (!known || item.line.text.includes('\t')) return null;
  const ls = languageSplit(ctx, item.text, A, B);
  if (!ls) return null;
  return { left: ls.left, right: ls.right, pl: pairProb(ctx, ls.left, A, B), pr: pairProb(ctx, ls.right, A, B), delim: false };
}

function align(ctx, items, A, B, opts) {
  const n = items.length;
  const [xm, xj] = BOUNDARY[opts.boundary];
  const known = Boolean(A && B && A !== B);
  const cT = new Array(n);
  const cD = new Array(n);
  const splits = new Array(n).fill(null);
  for (let i = 0; i < n; i++) {
    const bil = opts.allowSplit ? bilingualParts(ctx, items[i], A, B, known) : null;
    if (bil) {
      // A line holding both languages is costed as its two halves.
      const extra = known ? 0 : 1;
      cT[i] = nlog(bil.pl) + nlog(bil.pr) + extra;
      cD[i] = nlog(1 - bil.pl) + nlog(1 - bil.pr) + extra;
      if (!known || (bil.pl >= 0.5 && bil.pr <= 0.5)) {
        const cost = nlog(bil.pl) + nlog(1 - bil.pr) + (bil.delim ? DELIM_SPLIT_COST : LANG_SPLIT_COST);
        splits[i] = { left: bil.left, right: bil.right, cost, lang: !bil.delim, delimId: bil.delimId || ' ' };
      }
    } else {
      const p = known ? pairProb(ctx, items[i].text, A, B) : 0.5;
      cT[i] = nlog(p);
      cD[i] = nlog(1 - p);
    }
  }
  // mc[i]: cost of continuing line i-1 with line i on the same side.
  // heading[i]: line i may be a section heading in front of the term that
  // starts on line i+1 ("Les couleurs" before "rouge"). Skipping it is cheaper,
  // and merging it into that term costs extra unless the merged term matches
  // the definition's length better (a wrapped sentence). German terms are
  // exempt because German nouns are capitalised, and so are the lines of one
  // block in a blocks list.
  const mc = new Array(n).fill(0);
  const headings = known && A !== 'de';
  const heading = new Array(n).fill(false);
  for (let i = 1; i < n; i++) {
    const [prev, next] = [items[i - 1].text, items[i].text];
    const sameBlock = items[i].block === items[i - 1].block;
    const inBlock = sameBlock && opts.boundary === 'strong';
    mc[i] = mergeCost(prev, next);
    if (inBlock) mc[i] = Math.min(mc[i], 1);
    if (!sameBlock) mc[i] += xm;
    heading[i - 1] = headings && !inBlock && looksLikeHeading(prev, A) && /^\p{Ll}/u.test(next) && !continuesSentence(next);
  }
  const words = items.map((it) => wordCount(it.text));
  // Cognate pairs ("intelligent" = "intelligent") carry no language signal:
  // as a 1:1 card each side costs at most an even guess.
  const cognate = items.map((it, i) => i + 1 < n && !it.weak && !items[i + 1].weak && isCognate(it.text, items[i + 1].text));
  const best = new Float64Array(n + 1);
  const choice = new Array(n + 1);
  for (let i = n - 1; i >= 0; i--) {
    const skipCost = items[i].weak ? WEAK_HEADING_COST : heading[i] ? Math.min(HEADING_SKIP_COST, opts.unpairedCost) : opts.unpairedCost;
    let bc = skipCost + best[i + 1];
    let ch = { type: 'skip' };
    if (splits[i] && splits[i].cost + best[i + 1] < bc) {
      bc = splits[i].cost + best[i + 1];
      ch = { type: 'split' };
    }
    let termCost = 0;
    let termWords = 0;
    for (let a = 1; a <= 3 && i + a < n; a++) {
      const ti = i + a - 1;
      termCost += cT[ti] + (a > 1 ? mc[ti] : 0);
      termWords += words[ti];
      const junction = items[i + a].block !== items[i + a - 1].block ? xj : 0;
      let defCost = 0;
      let defWords = 0;
      for (let b = 1; b <= 3 && i + a + b <= n; b++) {
        const di = i + a + b - 1;
        defCost += cD[di] + (b > 1 ? mc[di] : 0);
        defWords += words[di];
        let total = termCost + junction + defCost + best[i + a + b];
        if (a > 1 && heading[i] && restMatchesLength(termWords, termWords - words[i], defWords)) total += HEADING_MERGE_COST;
        if (a === 1 && b === 1 && cognate[i]) {
          total = Math.min(total, Math.min(cT[i], Math.LN2) + junction + Math.min(cD[i + 1], Math.LN2) + best[i + 2]);
        }
        if (total < bc - 1e-9) {
          bc = total;
          ch = { type: 'card', a, b };
        }
      }
    }
    best[i] = bc;
    choice[i] = ch;
  }
  const steps = [];
  for (let i = 0; i < n; ) {
    const ch = choice[i];
    if (ch.type === 'card') {
      steps.push({ type: 'card', term: range(i, i + ch.a), def: range(i + ch.a, i + ch.a + ch.b) });
      i += ch.a + ch.b;
    } else {
      steps.push(ch.type === 'split' ? { type: 'split', index: i, split: splits[i] } : { type: 'skip', index: i, heading: heading[i] });
      i++;
    }
  }
  return { cost: best[0], steps };
}

// Try both language orders (which language comes first in the source).
function alignBest(ctx, items, A, B, opts) {
  if (!items.length) return [];
  const first = align(ctx, items, A, B, opts);
  if (!A || !B || A === B) return first.steps;
  const second = align(ctx, items, B, A, opts);
  return (second.cost < first.cost - 1e-9 ? second : first).steps;
}

function range(a, b) {
  const out = [];
  for (let i = a; i < b; i++) out.push(i);
  return out;
}

function stepToPair(ctx, items, st) {
  if (st.type === 'split') {
    return makePair(st.split.left, st.split.right, items[st.index].line.span, { langSplit: st.split.lang });
  }
  const term = st.term.map((i) => items[i].text).reduce(joinParts, '');
  const def = st.def.map((i) => items[i].text).reduce(joinParts, '');
  const lines = st.term.concat(st.def).flatMap((i) => items[i].line.span);
  const mergedLines = st.term.slice(1).concat(st.def.slice(1)).map((i) => items[i].line.no);
  for (const no of mergedLines) ctx.warnings.line('merged', no);
  return makePair(term, def, lines, { merged: mergedLines.length > 0 });
}

// Two-column OCR order: all term lines first, then all definition lines
// (possibly repeated per page). Returns pairs or null.
function detectColumns(ctx, items, L1, L2) {
  if (!L1 || !L2 || items.length < 4) return null;
  const labels = items.map((it) => {
    const p = pairProb(ctx, it.text, L1, L2);
    return p > 0.65 ? 1 : p < 0.35 ? 2 : 0;
  });
  // Alternating lists change language on almost every line; columns rarely do.
  const labelled = labels.filter(Boolean);
  let changes = 0;
  for (let k = 1; k < labelled.length; k++) if (labelled[k] !== labelled[k - 1]) changes++;
  if (labelled.length < 4 || changes / (labelled.length - 1) >= 0.35) return null;

  // One page: the first half is one language, the second half the other. A
  // few cognates or weakly scored lines ("charmant") must not hide that.
  if (items.length % 2 === 0) {
    const h = items.length / 2;
    const top = labels.slice(0, h).filter(Boolean);
    const bottom = labels.slice(h).filter(Boolean);
    const share = (list, lab) => list.filter((l) => l === lab).length / list.length;
    for (const [a, b] of [[1, 2], [2, 1]]) {
      if (top.length >= 2 && bottom.length >= 2 && share(top, a) >= 0.8 && share(bottom, b) >= 0.8) {
        return range(0, h).map((k) => {
          const [x, y] = [items[k], items[k + h]];
          return makePair(x.text, y.text, x.line.span.concat(y.line.span));
        });
      }
    }
  }

  let runs = [];
  labels.forEach((lab, i) => {
    const last = runs[runs.length - 1];
    if (last && (lab === 0 || last.label === lab || last.label === 0)) {
      if (last.label === 0) last.label = lab;
      last.idx.push(i);
    } else {
      runs.push({ label: lab, idx: [i] });
    }
  });
  // Absorb a single misdetected line inside a long run, or at either end.
  for (let changed = true; changed; ) {
    changed = false;
    for (let r = 1; r < runs.length - 1; r++) {
      const [a, m, b] = [runs[r - 1], runs[r], runs[r + 1]];
      if (m.idx.length === 1 && a.label === b.label && a.idx.length >= 2 && b.idx.length >= 2) {
        a.idx.push(...m.idx, ...b.idx);
        runs.splice(r, 2);
        changed = true;
        break;
      }
    }
    if (changed || runs.length < 3) continue;
    if (runs[0].idx.length === 1 && runs[1].idx.length >= 3) {
      runs[1].idx.unshift(...runs[0].idx);
      runs.shift();
      changed = true;
    } else if (runs[runs.length - 1].idx.length === 1 && runs[runs.length - 2].idx.length >= 3) {
      runs[runs.length - 2].idx.push(...runs[runs.length - 1].idx);
      runs.pop();
      changed = true;
    }
  }
  if (runs.length < 2 || runs.length % 2 !== 0 || items.length / runs.length < 3) return null;
  for (let r = 0; r < runs.length; r++) if (!runs[r].label || (r && runs[r].label === runs[r - 1].label)) return null;

  // Validate every column pair before emitting anything.
  const columns = [];
  for (let r = 0; r < runs.length; r += 2) {
    let left = runs[r].idx;
    let right = runs[r + 1].idx;
    if (runs.length === 2 && items.length % 2 === 0 && Math.abs(left.length - right.length) <= 2) {
      left = range(0, items.length / 2);
      right = range(items.length / 2, items.length);
    }
    const m = Math.min(left.length, right.length);
    if (Math.abs(left.length - right.length) > Math.max(1, Math.round(m * 0.25))) return null;
    columns.push({ left, right, m });
  }
  const pairs = [];
  for (const { left, right, m } of columns) {
    if (left.length !== right.length) {
      ctx.warnings.add(`Die beiden Spalten sind unterschiedlich lang (${left.length} und ${right.length} Zeilen).`);
    }
    for (let k = 0; k < m; k++) {
      const a = items[left[k]];
      const b = items[right[k]];
      pairs.push(makePair(a.text, b.text, a.line.span.concat(b.line.span)));
    }
    for (const i of left.slice(m).concat(right.slice(m))) unpairedLine(ctx, items[i], false, L1, L2);
  }
  return pairs;
}

function parseLineBased(ctx, lines, allowSplit) {
  const items = [];
  let block = 0;
  let open = false;
  for (const line of lines) {
    if (line.blank) {
      if (open) block++;
      open = false;
      continue;
    }
    if (line.kind) continue;
    items.push({ line, text: displayText(line), block, weak: line.weak });
    open = true;
  }
  const sizes = new Map();
  for (const it of items) sizes.set(it.block, (sizes.get(it.block) || 0) + 1);
  const counts = [...sizes.values()];
  const nb = counts.length;
  const share1 = counts.filter((c) => c === 1).length / nb;
  const share2 = counts.filter((c) => c === 2).length / nb;
  let boundary = 'medium';
  if (nb <= 1) boundary = 'none';
  else if (share1 >= 0.6) boundary = 'weak';
  else if (share2 >= 0.5) boundary = 'strong';

  const [L1, L2] = topTwoLanguages(ctx, items.map((it) => it.text));
  if (boundary !== 'strong') {
    const pairs = detectColumns(ctx, items, L1, L2);
    if (pairs) return { pairs, format: 'columns', delimiter: null };
  }
  const steps = alignBest(ctx, items, L1, L2, { boundary, allowSplit, unpairedCost: UNPAIRED_COST });
  const pairs = [];
  const used = [];
  for (const st of steps) {
    if (st.type === 'skip') unpairedLine(ctx, items[st.index], false, L1, L2, st.heading);
    else pairs.push(stepToPair(ctx, items, st));
    if (st.type === 'split') used.push(st.split.delimId);
  }
  // Mostly one-line pairs with mixed delimiters ("le lit - das Bett", "le mur = die Wand").
  if (pairs.length && used.length >= 0.6 * pairs.length) return { pairs, format: 'delimited', delimiter: mostFrequent(used) };
  return { pairs, format: boundary === 'strong' ? 'blocks' : 'alternating', delimiter: null };
}

function mostFrequent(list) {
  const counts = new Map();
  for (const x of list) counts.set(x, (counts.get(x) || 0) + 1);
  let best = null;
  for (const [x, n] of counts) if (best === null || n > counts.get(best)) best = x;
  return best;
}

// Bilingual lines without one common delimiter: no delimiter at all ("le chat
// die Katze", collapsed PDF columns) or a mix of several (tabs and " - ").
function detectBilingual(ctx, content) {
  let [L1, L2] = topTwoLanguages(ctx, content.map(displayText));
  // Each line of a short list votes for one language ("le chat die Katze" is
  // German overall); its words show both.
  const byWords = () => topTwoLanguages(ctx, content.slice(0, 200).flatMap((l) => displayText(l).split(' ')));
  const lineVote = !!L2;
  if (L1 && !L2) [L1, L2] = byWords();
  if (!L1 || !L2) return null;
  const split = (text, A, B) => languageSplit(ctx, text, A, B) || twoWordSplit(ctx, text, A, B);
  // The two languages in line order when most lines split into them, else null.
  const ordered = (first, second) => {
    let ok = 0;
    let order = 0;
    for (const line of content) {
      const d = delimiterSplit(ctx, line, first, second);
      const s = d ? { order: d.pl > d.pr ? 1 : -1 } : split(displayText(line), first, second);
      if (s) {
        ok++;
        order += s.order;
      }
    }
    if (ok / content.length < 0.7 || Math.abs(order) / ok < 0.6) return null;
    return order > 0 ? [first, second] : [second, first];
  };
  let langs = ordered(L1, L2);
  // A heading or a wrong language hint can make a third language the runner-up
  // of the line votes ("Les couleurs:" above an English/German list); the words
  // still show both languages.
  if (!langs && lineVote) {
    const [W1, W2] = byWords();
    if (W1 && W2 && new Set([L1, L2, W1, W2]).size > 2) langs = ordered(W1, W2);
  }
  if (!langs) return null;
  const [A, B] = langs;
  const pairs = [];
  const used = [];
  const shapes = [];
  const pending = [];
  for (const line of content) {
    // An explicit delimiter in the line wins over the language boundary (a
    // reversed line is turned around in finish()).
    const d = delimiterSplit(ctx, line, A, B);
    if (d) {
      pairs.push(makePair(d.left, d.right, line.span));
      used.push(d.delimId);
      continue;
    }
    const s = split(displayText(line), A, B);
    if (s && s.order === 1) {
      const pair = makePair(s.left, s.right, line.span, { langSplit: true });
      pairs.push(pair);
      shapes.push([segments(s.left).length, segments(s.right).length]);
      used.push(' ');
    } else {
      // Placeholder keeps the source order until the run is resolved.
      pairs.push(null);
      pending.push({ line, at: pairs.length - 1 });
    }
  }
  resolvePending(ctx, pairs, pending, shapes, A, B);
  const explicit = used.filter((id) => id !== ' ');
  const delimiter = explicit.length >= 0.5 * used.length ? mostFrequent(explicit) : ' ';
  return { pairs: pairs.filter(Boolean), format: 'delimited', delimiter };
}

// Lines of a "both languages per line" list that no language split was sure
// about. When they have the same word count as most split lines ("essayer
// versuchen" among "attendre warten"), they are cut at the usual boundary;
// a cut against the language evidence is marked uncertain. Other lines go
// through the run alignment like in delimited lists.
function resolvePending(ctx, pairs, pending, shapes, A, B) {
  let run = [];
  const flush = () => {
    if (!run.length) return;
    const created = [];
    handleRun(ctx, run.map((p) => p.line), null, null, A, B, created);
    pairs[run[0].at] = created; // spliced in below, keeping the order
    run = [];
  };
  let prevAt = -2;
  for (const p of pending) {
    if (p.at !== prevAt + 1) flush();
    prevAt = p.at;
    const text = displayText(p.line);
    const segs = segments(text);
    const k = usualBoundary(shapes, segs.length);
    const { left, right } = k ? cutAt(text, segs, k) : {};
    if (k && /\p{L}/u.test(left) && /\p{L}/u.test(right)) {
      flush();
      const lean = (t) => {
        const s = ctx.score(t);
        return s[A] - s[B];
      };
      pairs[p.at] = makePair(left, right, p.line.span, { langSplit: true, uncertain: lean(left) <= lean(right) });
      continue;
    }
    run.push(p);
  }
  flush();
  // Expand the arrays produced by run alignment in place.
  for (let i = pairs.length - 1; i >= 0; i--) if (Array.isArray(pairs[i])) pairs.splice(i, 1, ...pairs[i]);
}

// Left word count used by most successful splits of lines with `total` words.
function usualBoundary(shapes, total) {
  const same = shapes.filter(([l, r]) => l + r === total);
  if (same.length < 3) return 0;
  const left = mostFrequent(same.map(([l]) => l));
  return same.filter(([l]) => l === left).length >= 0.6 * same.length ? left : 0;
}

// ---------------------------------------------------------------------------
// Explicit delimiter mode
// ---------------------------------------------------------------------------

function normalizeDelimiter(d) {
  const out = String(d)
    .replace(/[–—‒‐‑−]/g, '-')
    .replace(/[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g, ' ')
    .replace(/[’‘`´ʼ′]/g, "'");
  return out === '' ? '\t' : out;
}

function recordsFrom(source, sep) {
  let t = source;
  if (t.charCodeAt(0) === 0xfeff) t = t.slice(1);
  t = t.replace(/\r\n?/g, '\n');
  const records = [];
  let start = 0;
  const push = (end) => {
    const chunk = t.slice(start, end);
    const lead = chunk.length - chunk.replace(/^\s+/, '').length;
    records.push({ chunk, no: t.slice(0, start + lead).split('\n').length });
  };
  if (/^\n+$/.test(sep)) {
    // Blank-line separated records: any run of blank lines separates.
    const re = /\n[ \t]*\n\s*/g;
    let m;
    while ((m = re.exec(t)) !== null) {
      push(m.index);
      start = m.index + m[0].length;
    }
  } else {
    for (let idx = t.indexOf(sep); idx !== -1; idx = t.indexOf(sep, start)) {
      push(idx);
      start = idx + sep.length;
    }
  }
  push(t.length);
  return records;
}

function parseWithDelimiter(ctx, source) {
  const o = ctx.o;
  const delim = normalizeDelimiter(o.delimiter ?? '\t');
  const sep = o.cardSeparator;
  if (delim.includes('\n')) {
    // Term and definition on separate lines inside each record.
    const pairs = [];
    const inner = delim.trim() || '\n';
    for (const { chunk, no } of recordsFrom(source, sep === '\n' ? '\n\n' : sep)) {
      const trimmed = chunk.trim();
      if (!trimmed) continue;
      const idx = trimmed.indexOf(inner);
      const term = normalizeBasic(idx === -1 ? trimmed : trimmed.slice(0, idx));
      const def = idx === -1 ? '' : normalizeBasic(trimmed.slice(idx + inner.length));
      const lastLine = no + (trimmed.match(/\n/g) || []).length;
      if (term || def) pairs.push(makePair(term, def, range(no, lastLine + 1)));
    }
    return { pairs, format: 'delimited', delimiter: delim };
  }
  // The user picked the delimiter: glued en/em dashes are spaced only for a dash.
  const dashList = delim.trim() === '-';
  let lines;
  if (sep === '\n' || sep === '\r\n' || sep === '\r') {
    lines = classify(ctx, preprocess(source, dashList));
  } else {
    const records = recordsFrom(source, sep).map(({ chunk, no }) => {
      const line = makeLine(spaceGluedDashes([chunk.replace(/\n/g, ' ')], dashList)[0], no);
      const extra = (chunk.trim().match(/\n/g) || []).length;
      line.span = range(no, no + extra + 1);
      return line;
    });
    lines = classify(ctx, records);
  }
  const result = parseDelimitedLines(ctx, lines, customCandidate(delim));
  return { ...result, delimiter: delim };
}

// ---------------------------------------------------------------------------
// Orchestration & post-processing
// ---------------------------------------------------------------------------

function parseInternal(input, o) {
  const source = typeof input === 'string' ? input : input == null ? '' : String(input);
  const ctx = createContext(o);
  if (o.mode === 'delimiter') return finish(ctx, parseWithDelimiter(ctx, source));
  const lines = classify(ctx, preprocess(source));
  const content = lines.filter((l) => !l.blank && !l.kind);
  if (!content.length) return finish(ctx, { pairs: [], format: 'empty', delimiter: null });
  if (o.mode === 'auto') {
    const inline = detectInline(ctx, content);
    if (inline) return finish(ctx, inline);
    const cand = detectDelimiter(ctx, lines);
    if (cand) return finish(ctx, parseDelimitedLines(ctx, lines, cand));
    const bilingual = detectBilingual(ctx, content);
    if (bilingual) return finish(ctx, bilingual);
  }
  return finish(ctx, parseLineBased(ctx, lines, o.mode === 'auto'));
}

function knownLang(l) {
  return Boolean(l) && l !== 'unknown';
}

// Pick distinct languages when both columns detect the same one.
function distinctLanguages(ctx, leftTexts, rightTexts, L, R) {
  if (!knownLang(L) || L !== R) return [L, R];
  const ls = languageShares(ctx, leftTexts);
  const rs = languageShares(ctx, rightTexts);
  let best = null;
  for (const a of ls) {
    for (const b of rs) {
      if (a.lang === b.lang || a.share < 0.15 || b.share < 0.15) continue;
      const s = a.share + b.share;
      if (!best || s > best.s) best = { s, L: a.lang, R: b.lang };
    }
  }
  return best ? [best.L, best.R] : [L, R];
}

// The language the user picked for the terms wins over a close call
// ("lesson", "chapter" also look French). The term side is the one that is
// not the definition language; a decisive detection is kept.
function applyTermHint(ctx, leftTexts, rightTexts, langs) {
  const [L, lConf, R, rConf] = langs;
  const hint = ctx.o.termHint;
  const target = ctx.o.defHint || 'de';
  if (!hint || hint === target || L === hint || R === hint) return langs;
  const close = (texts) => {
    const shares = languageShares(ctx, texts);
    const own = shares.find((s) => s.lang === hint);
    return shares.slice(0, 2).includes(own) && own.share >= 0.5 * shares[0].share;
  };
  if (knownLang(L) && L !== target && close(leftTexts)) return [hint, Math.max(lConf, 0.55), R, rConf];
  if (L === target && knownLang(R) && close(rightTexts)) return [L, lConf, hint, Math.max(rConf, 0.55)];
  return langs;
}

// Loanwords / cognates ("charmant, charmante" = "charmant") carry no language signal.
function isCognate(a, b) {
  const tok = (s) => s.toLowerCase().match(/\p{L}{3,}/gu) || [];
  const ta = tok(a);
  const tb = tok(b);
  if (!ta.length || !tb.length) return false;
  const [small, big] = ta.length <= tb.length ? [ta, new Set(tb)] : [tb, new Set(ta)];
  return small.every((t) => big.has(t));
}

function finish(ctx, result) {
  const o = ctx.o;
  let pairs = result.pairs.filter((p) => p.term || p.def);
  const leftTexts = pairs.map((p) => p.term).filter(Boolean);
  const rightTexts = pairs.map((p) => p.def).filter(Boolean);
  const lc = detectColumn(leftTexts);
  const rc = detectColumn(rightTexts);
  let [L, R] = distinctLanguages(ctx, leftTexts, rightTexts, lc.lang, rc.lang);
  let lConf = lc.confidence;
  let rConf = rc.confidence;
  [L, lConf, R, rConf] = applyTermHint(ctx, leftTexts, rightTexts, [L, lConf, R, rConf]);

  // A header row ("Französisch | Deutsch") decides when detection is unsure.
  if (ctx.header && ctx.header.left && ctx.header.right) {
    if (!knownLang(L) || lConf < 0.55) [L, lConf] = [ctx.header.left, 0.6];
    if (!knownLang(R) || rConf < 0.55) [R, rConf] = [ctx.header.right, 0.6];
  }

  // Orientation: the definition side is the translation language (German by default).
  const target = o.defHint || 'de';
  let autoSwap = false;
  if (o.orient && knownLang(L) && knownLang(R) && L !== R) {
    if (L === target && R !== target) autoSwap = true;
    else if (R !== target && o.termHint && R === o.termHint && L !== o.termHint) autoSwap = true;
  } else if (o.orient && knownLang(L) !== knownLang(R)) {
    // Only one side has words ("12 - douze"): it is the learned side unless it is German.
    autoSwap = knownLang(R) ? R !== target : L === target;
  }
  const swapped = autoSwap !== o.swap;
  if (swapped) {
    pairs = pairs.map((p) => ({ ...p, term: p.def, def: p.term }));
    [L, R] = [R, L];
    [lConf, rConf] = [rConf, lConf];
  }

  const distinct = knownLang(L) && knownLang(R) && L !== R;
  const cards = [];
  const seen = new Map();
  for (const p of pairs) {
    let term = p.term;
    let def = p.def;
    let pT = term ? pairProb(ctx, term, L, R) : null;
    let pD = def ? pairProb(ctx, def, R, L) : null;
    const cognate = Boolean(term && def && isCognate(term, def));
    // A single card written the other way round.
    if (distinct && !cognate && pT !== null && pD !== null && pT < 0.1 && pD < 0.1) {
      [term, def] = [def, term];
      [pT, pD] = [1 - pD, 1 - pT];
      ctx.warnings.line('reversed', p.lines[0]);
    }
    const flags = [];
    let confidence = 0.75;
    let mismatch = false;
    if (distinct && !cognate) {
      if (pT !== null && pD !== null) confidence = (pT * pD) / (pT * pD + (1 - pT) * (1 - pD));
      else confidence = pT ?? pD ?? 0.5;
      mismatch = (pT !== null && pT < 0.1) || (pD !== null && pD < 0.1);
    }
    if (p.merged) confidence *= 0.85;
    if (p.langSplit) confidence *= 0.85;
    if (p.uncertain) confidence *= 0.45; // always below the lowConfidence threshold
    if (p.merged) flags.push('merged');
    if (confidence < 0.5) {
      flags.push('lowConfidence');
      ctx.warnings.line('lowConfidence', p.lines[0]);
    }
    if (mismatch) {
      flags.push('langMismatch');
      ctx.warnings.line('langMismatch', p.lines[0]);
    }
    if (!term) {
      flags.push('missingTerm');
      ctx.warnings.line('missingTerm', p.lines[0]);
    }
    if (!def) {
      flags.push('missingDefinition');
      ctx.warnings.line('missingDefinition', p.lines[0]);
    }
    const key = term.toLowerCase().replace(/[\s.!?]+$/, '').replace(/\s+/g, ' ');
    if (key) {
      if (seen.has(key)) {
        flags.push('duplicate');
        seen.get(key).lines.push(p.lines[0]);
      } else {
        seen.set(key, { term, lines: [p.lines[0]] });
      }
    }
    cards.push({ term, definition: def, confidence: Math.round(confidence * 100) / 100, flags, lines: p.lines });
  }

  for (const { term, lines } of seen.values()) if (lines.length > 1) ctx.warnings.duplicate(term, lines);
  const skipCount = ctx.skipped.filter((s) => s.reason !== 'unpaired').length;
  if (skipCount) {
    ctx.warnings.add(
      skipCount === 1 ? '1 Zeile ohne Vokabeln wurde übersprungen.' : `${skipCount} Zeilen ohne Vokabeln wurden übersprungen.`,
    );
  }
  if (cards.length >= 3 && !distinct) ctx.warnings.add('Die Sprachen der beiden Seiten konnten nicht sicher erkannt werden.');

  const pickLang = (lang, conf, hint) => (knownLang(lang) && (conf >= 0.55 || !hint) ? lang : hint || 'other');
  const format = cards.length || result.format !== 'empty' ? result.format : 'empty';
  return {
    cards,
    format,
    delimiter: format === 'delimited' ? result.delimiter : null,
    termLang: pickLang(L, lConf, o.termHintRaw),
    defLang: pickLang(R, rConf, o.defHintRaw),
    swapped,
    skipped: ctx.skipped.sort((a, b) => a.line - b.line),
    warnings: ctx.warnings.build(),
  };
}

// ---------------------------------------------------------------------------
// German warnings
// ---------------------------------------------------------------------------

const LINE_WARNINGS = {
  unpaired: ['Zeile {n} konnte keinem Paar zugeordnet werden.', 'Zeilen {n} konnten keinem Paar zugeordnet werden.'],
  merged: [
    'Zeile {n} wurde als Fortsetzung der vorherigen Zeile übernommen.',
    'Zeilen {n} wurden als Fortsetzung der vorherigen Zeile übernommen.',
  ],
  reversed: [
    'Zeile {n}: Begriff und Definition waren vertauscht und wurden umgedreht.',
    'Zeilen {n}: Begriff und Definition waren vertauscht und wurden umgedreht.',
  ],
  lowConfidence: ['Zeile {n} wurde unsicher erkannt – bitte prüfen.', 'Zeilen {n} wurden unsicher erkannt – bitte prüfen.'],
  langMismatch: ['Zeile {n} passt sprachlich nicht zu ihrer Spalte.', 'Zeilen {n} passen sprachlich nicht zu ihrer Spalte.'],
  missingTerm: ['Zeile {n}: Der Begriff fehlt.', 'Zeilen {n}: Der Begriff fehlt.'],
  missingDefinition: ['Zeile {n}: Die Definition fehlt.', 'Zeilen {n}: Die Definition fehlt.'],
};

function listNumbers(nos) {
  const shown = nos.slice(0, 6);
  const more = nos.length - shown.length;
  if (more > 0) return `${shown.join(', ')} und ${more} weitere`;
  if (shown.length === 1) return String(shown[0]);
  return `${shown.slice(0, -1).join(', ')} und ${shown[shown.length - 1]}`;
}

function createWarnings() {
  const byKind = new Map();
  const extra = [];
  const dups = [];
  return {
    line(kind, no) {
      if (!byKind.has(kind)) byKind.set(kind, []);
      const list = byKind.get(kind);
      if (!list.includes(no)) list.push(no);
    },
    add(message) {
      if (!extra.includes(message)) extra.push(message);
    },
    duplicate(term, nos) {
      dups.push({ term, nos });
    },
    build() {
      const out = [];
      for (const kind of Object.keys(LINE_WARNINGS)) {
        const nos = (byKind.get(kind) || []).sort((a, b) => a - b);
        if (!nos.length) continue;
        const [one, many] = LINE_WARNINGS[kind];
        out.push((nos.length === 1 ? one : many).replace('{n}', listNumbers(nos)));
      }
      if (dups.length > 3) out.push(`${dups.length} Begriffe kommen mehrfach vor.`);
      else for (const d of dups) out.push(`«${d.term}» kommt mehrfach vor (Zeilen ${listNumbers(d.nos)}).`);
      return out.concat(extra);
    },
  };
}
