import { test, expect, run } from './harness.js';
import { SUPPORTED, scoreLanguages, detectLanguage, detectColumn } from '../src/core/langdetect.js';

const read = (name) => readFile(`fixtures/${name}`);

function accuracy(lines, lang) {
  const misses = lines.filter((l) => detectLanguage(l).lang !== lang);
  return { rate: (lines.length - misses.length) / lines.length, misses };
}

test('SUPPORTED lists the five Latin languages, then Arabic and Chinese', () => {
  expect(SUPPORTED).toEqual(['fr', 'de', 'en', 'es', 'it', 'ar', 'zh']);
});

test('scoreLanguages returns non-negative scores for every language', () => {
  for (const text of ['le chat', 'die Katze', 'the house', 'el perro', 'il cane', 'xyz', 'Frau']) {
    const s = scoreLanguages(text);
    expect(Object.keys(s).sort()).toEqual(['ar', 'de', 'en', 'es', 'fr', 'it', 'zh']);
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
  const zero = { fr: 0, de: 0, en: 0, es: 0, it: 0, ar: 0, zh: 0 };
  expect(scoreLanguages('')).toEqual(zero);
  expect(scoreLanguages('12 / 40')).toEqual(zero);
  // Arabic punctuation and digits, the tatweel and vowel marks alone are no letters.
  expect(scoreLanguages('١٢ ، ؟ ـ')).toEqual(zero);
  expect(scoreLanguages('，。！')).toEqual(zero);
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

// ---------------------------------------------------------------------------
// Arabic and Chinese (by their script)

const LATIN = ['fr', 'de', 'en', 'es', 'it'];
const latinScores = (s) => LATIN.map((l) => s[l]);

test('Arabic words are Arabic and give no Latin evidence', () => {
  for (const w of ['كتاب', 'مدرسة', 'الكتاب', 'مرحبا', 'مع السلامة', 'سيارة، عربية']) {
    const s = scoreLanguages(w);
    expect(`${w}: ${latinScores(s).join(',')}`).toBe(`${w}: 0,0,0,0,0`);
    expect(s.ar).toBeGreaterThan(3);
    expect(s.zh).toBe(0);
    const d = detectLanguage(w);
    expect(`${w}: ${d.lang}`).toBe(`${w}: ar`);
    expect(d.confidence).toBeGreaterThan(0.85);
  }
  // Every word counts.
  expect(scoreLanguages('مع السلامة').ar).toBeGreaterThan(scoreLanguages('السلامة').ar);
});

test('Arabic vowel marks, the tatweel and presentation forms do not change the evidence', () => {
  const plain = scoreLanguages('الكتاب');
  expect(scoreLanguages('الْكِتَابُ')).toEqual(plain); // harakat would otherwise split the word
  expect(scoreLanguages('الكـتـاب')).toEqual(plain);
  expect(scoreLanguages('مَدْرَسَةٌ جَمِيلَةٌ')).toEqual(scoreLanguages('مدرسة جميلة'));
  expect(scoreLanguages('ﻛﺘﺎﺏ')).toEqual(scoreLanguages('كتاب'));
});

test('Han runs are Chinese and give no Latin evidence', () => {
  for (const w of ['你好', '我是学生。', '谢谢', '中国', '书']) {
    const s = scoreLanguages(w);
    expect(`${w}: ${latinScores(s).join(',')}`).toBe(`${w}: 0,0,0,0,0`);
    expect(s.zh).toBeGreaterThan(3);
    expect(s.ar).toBe(0);
    expect(`${w}: ${detectLanguage(w).lang}`).toBe(`${w}: zh`);
  }
  // A run of characters is one piece of evidence; separate runs add up.
  expect(scoreLanguages('我是学生').zh).toBe(scoreLanguages('书').zh);
  expect(scoreLanguages('你好，朋友').zh).toBeGreaterThan(scoreLanguages('你好').zh);
});

test('pinyin tone marks are Chinese evidence', () => {
  for (const w of ['nǐ hǎo', 'shuǐ', 'lǎoshī', 'duìbuqǐ', 'Běijīng', 'lǜ', 'māma', 'zǎoshang hǎo', 'kāfēi']) {
    expect(`${w}: ${detectLanguage(w).lang}`).toBe(`${w}: zh`);
  }
  // A word with a tone mark is pinyin as a whole: no Latin evidence (shuǐ looks English).
  expect(latinScores(scoreLanguages('shuǐ')).join(',')).toBe('0,0,0,0,0');
  // The caron (3rd tone) counts more than the macron (1st tone); one word, one piece of evidence.
  expect(scoreLanguages('hǎo').zh).toBeGreaterThan(scoreLanguages('hē').zh);
  expect(scoreLanguages('lǎoshī').zh).toBe(scoreLanguages('hǎo').zh);
  expect(scoreLanguages('nǐ hǎo').zh).toBe(2 * scoreLanguages('hǎo').zh);
  expect(scoreLanguages('你好 (nǐ hǎo)').zh).toBeGreaterThan(scoreLanguages('你好').zh);
  expect(detectLanguage('你好 (nǐ hǎo)').lang).toBe('zh');
});

test('Latin-script text never gets Arabic or Chinese evidence', () => {
  for (const w of ['le chat', 'die Katze', 'the house', 'el niño', 'la città', 'Straße', 'œuvre', 'xièxie', 'ni3 hao3', 'Москва']) {
    const s = scoreLanguages(w);
    expect(`${w}: ${s.ar} ${s.zh}`).toBe(`${w}: 0 0`);
  }
  // Without evidence they take no share of the probability.
  const fr = ['le chat', 'le chien', 'la souris', 'la maison'];
  expect(detectColumn(fr).lang).toBe('fr');
  expect(detectLanguage('le chat').confidence).toBeGreaterThan(0.99);
});

test('mixed lines: script words skip the Latin signals, Latin words keep them', () => {
  const s = scoreLanguages('كتاب Buch');
  expect(s.ar).toBe(scoreLanguages('كتاب').ar);
  expect(s.de).toBeGreaterThan(3);
  // Han glued to Latin letters is cut at the script boundary.
  const g = scoreLanguages('你好Hallo');
  expect(g.zh).toBe(scoreLanguages('你好').zh);
  expect(g.de).toBeGreaterThan(1);
  expect(detectLanguage('الكتاب - das Buch').lang === 'unknown').toBe(false);
});

test('detectColumn: Arabic and Chinese columns', () => {
  const ar = detectColumn(['كتاب', 'قلم', 'بيت', 'مدرسة', 'المعلّم']);
  expect(ar.lang).toBe('ar');
  expect(ar.confidence).toBeGreaterThan(0.9);
  const zh = detectColumn(['你好', '谢谢', '再见', '学生', '朋友']);
  expect(zh.lang).toBe('zh');
  expect(zh.confidence).toBeGreaterThan(0.9);
  expect(detectColumn(['你好 (nǐ hǎo)', '谢谢 (xièxie)', '再见 (zàijiàn)']).lang).toBe('zh');
  // A German column with one Arabic line stays German.
  expect(detectColumn(['die Katze', 'der Hund', 'كتاب', 'das Haus', 'die Maus']).lang).toBe('de');
});

test('detectColumn: right language for the Arabic and Chinese fixtures', () => {
  const ar = read('arabic-german.txt').split('\n').filter((l) => l.includes(' - ')).slice(1).map((l) => l.split(' - '));
  expect(detectColumn(ar.map((r) => r[0])).lang).toBe('ar');
  expect(detectColumn(ar.map((r) => r[1])).lang).toBe('de');
  const zh = read('chinese-german.txt').split('\n').filter((l) => l.trim()).slice(1).map((l) => l.split('\t'));
  expect(detectColumn(zh.map((r) => r[0])).lang).toBe('zh');
  expect(detectColumn(zh.map((r) => r[2])).lang).toBe('de');
  const dash = read('chinese-dash.txt').split('\n').filter((l) => l.trim()).slice(1).map((l) => l.split(/\s*-\s/));
  expect(detectColumn(dash.map((r) => r[0])).lang).toBe('zh');
  expect(detectColumn(dash.map((r) => r[1])).lang).toBe('de');
});

await run('langdetect.test.js');
