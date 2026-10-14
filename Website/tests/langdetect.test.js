import { test, expect, run } from './harness.js';
import { SUPPORTED, scoreLanguages, detectLanguage, detectColumn } from '../src/core/langdetect.js';

const read = (name) => readFile(`fixtures/${name}`);

function accuracy(lines, lang) {
  const misses = lines.filter((l) => detectLanguage(l).lang !== lang);
  return { rate: (lines.length - misses.length) / lines.length, misses };
}

test('SUPPORTED lists the five languages', () => {
  expect(SUPPORTED).toEqual(['fr', 'de', 'en', 'es', 'it']);
});

test('scoreLanguages returns non-negative scores for every language', () => {
  for (const text of ['le chat', 'die Katze', 'the house', 'el perro', 'il cane', 'xyz', 'Frau']) {
    const s = scoreLanguages(text);
    expect(Object.keys(s).sort()).toEqual(['de', 'en', 'es', 'fr', 'it']);
    for (const lang of SUPPORTED) {
      expect(typeof s[lang]).toBe('number');
      expect(s[lang] >= 0).toBe(true);
    }
  }
});

test('scoreLanguages is all zero without letters and never throws', () => {
  for (const input of ['', '   ', '123 - 456', '!!!', null, undefined, 42, {}, [], '\t\n']) {
    const s = scoreLanguages(input);
    for (const lang of SUPPORTED) expect(s[lang] >= 0).toBe(true);
  }
  expect(scoreLanguages('')).toEqual({ fr: 0, de: 0, en: 0, es: 0, it: 0 });
  expect(scoreLanguages('12 / 40')).toEqual({ fr: 0, de: 0, en: 0, es: 0, it: 0 });
});

test('articles push their language up', () => {
  expect(scoreLanguages('le jardin').fr).toBeGreaterThan(scoreLanguages('jardin').fr);
  expect(scoreLanguages('der Garten').de).toBeGreaterThan(scoreLanguages('Garten').de);
  expect(scoreLanguages('the garden').en).toBeGreaterThan(scoreLanguages('garden').en);
  expect(scoreLanguages('gli amici').it).toBeGreaterThan(scoreLanguages('amici').it);
  expect(scoreLanguages('los amigos').es).toBeGreaterThan(scoreLanguages('amigos').es);
});

test('detectLanguage: clear cases in every language', () => {
  const cases = {
    fr: ['le chat', "l'homme", 'les cheveux', 'garçon', 'sérieux, sérieuse', 'la bêtise', "s'appeler", 'beaucoup'],
    de: ['die Katze', 'das Mädchen', 'sich gleichen', 'die Schönheit', 'freundlich', 'die Strasse', 'heissen', 'etw. suchen'],
    en: ['the house', 'to appear', 'beautiful', 'something', 'to look for sth', 'the neighbourhood', 'quickly'],
    es: ['el perro', 'el niño', '¿Qué tal?', 'la canción', 'los amigos', 'la ciudad', 'hablar'],
    it: ['il cane', 'gli amici', 'la città', 'la stazione', 'perché', 'lo studente', 'mangiare'],
  };
  for (const [lang, lines] of Object.entries(cases)) {
    for (const line of lines) {
      const d = detectLanguage(line);
      if (d.lang !== lang) throw new Error(`${line}: expected ${lang}, got ${d.lang}`);
      expect(d.confidence > 0 && d.confidence <= 1).toBe(true);
    }
  }
});

test('detectLanguage: short single words of the user list', () => {
  const fr = ['calme', 'tranquille', 'sage', 'aimable', 'comique', 'sympathique', 'moche', 'bête', 'lâche', 'appeler'];
  const de = ['lieb', 'ruhig', 'still', 'Frau', 'komisch', 'sympathisch', 'mutig', 'dumm', 'feige', 'nennen', 'hübsch'];
  for (const w of fr) expect(`${w}:${detectLanguage(w).lang}`).toBe(`${w}:fr`);
  for (const w of de) expect(`${w}:${detectLanguage(w).lang}`).toBe(`${w}:de`);
});

test('detectLanguage: unknown for empty or letterless input', () => {
  expect(detectLanguage('')).toEqual({ lang: 'unknown', confidence: 0 });
  expect(detectLanguage('  12 - 13 !! ')).toEqual({ lang: 'unknown', confidence: 0 });
  expect(detectLanguage(null)).toEqual({ lang: 'unknown', confidence: 0 });
  expect(detectLanguage(undefined).lang).toBe('unknown');
});

test('user example: at least 95% of individual lines classified correctly', () => {
  const lines = read('user-example.txt').split('\n').filter((l) => l.trim());
  expect(lines).toHaveLength(104);
  let correct = 0;
  lines.forEach((line, i) => {
    if (detectLanguage(line).lang === (i % 2 === 0 ? 'fr' : 'de')) correct++;
  });
  expect(correct / lines.length).toBeGreaterThanOrEqual(0.95);
});

test('user example: both columns detected with high confidence', () => {
  const lines = read('user-example.txt').split('\n').filter((l) => l.trim());
  const fr = lines.filter((_, i) => i % 2 === 0);
  const de = lines.filter((_, i) => i % 2 === 1);
  const a = detectColumn(fr);
  const b = detectColumn(de);
  expect(a.lang).toBe('fr');
  expect(b.lang).toBe('de');
  expect(a.confidence).toBeGreaterThan(0.8);
  expect(b.confidence).toBeGreaterThan(0.8);
});

test('generalises to words that are not in the lexicon', () => {
  const heldOut = {
    fr: ['la grenouille', "l'épicerie", 'étroit', 'le bouleau', 'la pieuvre', "s'évanouir", 'le tournevis',
      'la quincaillerie', 'ensoleillé', 'le parapluie', 'la cheminée', 'le marteau', 'épouvantable', 'la serrure',
      'le grenier', 'la citrouille', 'le hérisson', 'déménager', 'le brouillard', 'la bougie', 'nettoyer',
      'pourtant', 'la boucherie', 'malheureusement', 'coudre', 'le genou', 'la poubelle', 'la tasse'],
    de: ['die Wäscheklammer', 'verschwommen', 'der Regenschirm', 'das Eichhörnchen', 'die Glühbirne', 'umziehen',
      'der Nebel', 'die Kerze', 'das Schloss', 'der Dachboden', 'der Kürbis', 'der Igel', 'schrecklich', 'sonnig',
      'der Kamin', 'der Schraubenzieher', 'der Frosch', 'ohnmächtig werden', 'putzen', 'trotzdem', 'die Metzgerei',
      'leider', 'nähen', 'das Knie', 'der Mülleimer', 'plaudern', 'Zahnbürste', 'Wolke'],
    en: ['the umbrella', 'to faint', 'the hedgehog', 'the screwdriver', 'the attic', 'the pumpkin', 'the candle',
      'foggy', 'sunny', 'the fireplace', 'awful', 'narrow', 'the squirrel', 'the lightbulb', 'to move house',
      'the frog', 'the grocery store', 'blurry', 'to clean', 'however', 'unfortunately', 'to sew', 'toothbrush'],
  };
  for (const [lang, lines] of Object.entries(heldOut)) {
    const { rate, misses } = accuracy(lines, lang);
    if (rate < 0.85) throw new Error(`${lang} held-out accuracy ${rate}: ${misses.join(', ')}`);
  }
});

test('Spanish and Italian columns are told apart', () => {
  const es = ['la rana', 'el paraguas', 'estrecho', 'la vela', 'el martillo', 'la calabaza', 'mudarse', 'la niebla',
    'limpiar', 'sin embargo', 'la rodilla', 'el cepillo de dientes', 'charlar', 'la carnicería'];
  const it = ['la rana', "l'ombrello", 'stretto', 'la candela', 'il martello', 'la zucca', 'traslocare', 'la nebbia',
    'pulire', 'tuttavia', 'il ginocchio', 'lo spazzolino', 'chiacchierare', 'la macelleria'];
  expect(detectColumn(es).lang).toBe('es');
  expect(detectColumn(it).lang).toBe('it');
});

test('detectColumn: one outlier line does not change the column', () => {
  const col = ['le chat', 'le chien', 'la souris', 'the cat', 'le lapin', 'la vache', 'le cheval', 'brave', 'sage'];
  expect(detectColumn(col).lang).toBe('fr');
  const de = ['der Hund', 'still', 'die Katze', 'charmant', 'lieb', 'ruhig'];
  expect(detectColumn(de).lang).toBe('de');
});

test('detectColumn: right language for every fixture column', () => {
  // [fixture, delimiter, left language, right language]
  const table = [
    ['quizlet-export.txt', '\t', 'fr', 'de'],
    ['dash-hyphen.txt', ' - ', 'fr', 'de'],
    ['dash-en-em.txt', /\s[–—]\s/, 'fr', 'de'],
    ['equals.txt', ' = ', 'fr', 'de'],
    ['semicolon.txt', ';', 'fr', 'de'],
    ['german-first.txt', ' - ', 'de', 'fr'],
    ['english-german.txt', ' - ', 'en', 'de'],
    ['pdf-columns.txt', /\s{2,}/, 'fr', 'de'],
    ['numbered.txt', /\s–\s/, 'fr', 'de'],
    ['spanish.txt', /\s–\s/, 'es', 'de'],
    ['italian.txt', ' = ', 'it', 'de'],
    ['four-cells.tsv', '\t', 'fr', 'de'],
  ];
  for (const [file, delim, left, right] of table) {
    const rows = read(file).split('\n').filter((l) => l.trim()).map((l) => l.split(delim));
    const leftCol = rows.flatMap((r) => r.filter((_, i) => i % 2 === 0));
    const rightCol = rows.flatMap((r) => r.filter((_, i) => i % 2 === 1));
    expect(`${file}:${detectColumn(leftCol).lang}`).toBe(`${file}:${left}`);
    expect(`${file}:${detectColumn(rightCol).lang}`).toBe(`${file}:${right}`);
  }
  const ocr = read('two-column-ocr.txt').split('\n').filter((l) => l.trim());
  expect(detectColumn(ocr.slice(0, 8)).lang).toBe('fr');
  expect(detectColumn(ocr.slice(8)).lang).toBe('de');
  const alt = read('alternating.txt').split('\n').filter((l) => l.trim());
  expect(detectColumn(alt.filter((_, i) => i % 2 === 0)).lang).toBe('fr');
  expect(detectColumn(alt.filter((_, i) => i % 2 === 1)).lang).toBe('de');
});

test('detectColumn: empty and odd input', () => {
  expect(detectColumn([])).toEqual({ lang: 'unknown', confidence: 0 });
  expect(detectColumn(['', '  ', '42'])).toEqual({ lang: 'unknown', confidence: 0 });
  expect(detectColumn(null)).toEqual({ lang: 'unknown', confidence: 0 });
  expect(detectColumn('le chat').lang).toBe('fr');
  expect(detectColumn([null, 'die Katze', undefined, 7]).lang).toBe('de');
});

test('detectColumn confidence grows with agreeing lines', () => {
  const one = detectColumn(['le chat']);
  const many = detectColumn(['le chat', 'le chien', 'la maison', 'les enfants', "l'école", 'la rue']);
  expect(many.confidence).toBeGreaterThan(one.confidence);
  expect(many.confidence <= 1).toBe(true);
});

test('French -ein / -eindre words are French; German -ein words stay German', () => {
  for (const w of ['plein', 'pleine', 'serein, sereine', 'freiner', 'atteindre', 'peindre', 'éteindre', 'craindre', 'peine', 'la ceinture']) {
    expect(`${w}: ${detectLanguage(w).lang}`).toBe(`${w}: fr`);
  }
  for (const w of ['klein', 'Schwein', 'allein', 'mein', 'meine', 'seine', 'Bein', 'Wein', 'Stein', 'einfach', 'die Leine']) {
    expect(`${w}: ${detectLanguage(w).lang}`).toBe(`${w}: de`);
  }
});

test('German -eint / -einte verb forms stay German and confident', () => {
  for (const w of ['vereinte', 'verneinte', 'beweinte', 'meinte', 'weinte', 'vereint', 'gemeint', 'erscheint', 'vereinigt']) {
    const { lang, confidence } = detectLanguage(w);
    expect(`${w}: ${lang} ${confidence >= 0.55}`).toBe(`${w}: de true`);
  }
  // French words with the same letters keep their language too.
  for (const w of ['peinte', 'atteinte', 'éteinte', 'teinte', 'enceinte', 'pleines']) {
    expect(`${w}: ${detectLanguage(w).lang}`).toBe(`${w}: fr`);
  }
});

test('English school and media words are English', () => {
  for (const w of ['lesson', 'chapter', 'exercise', 'homework', 'grammar', 'newspaper', 'advertisement', 'channel']) {
    expect(`${w}: ${detectLanguage(w).lang}`).toBe(`${w}: en`);
  }
});

await run('langdetect.test.js');
