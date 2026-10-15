import { test, expect, run } from './harness.js';
import {
  normalizeBasic,
  stripDiacritics,
  foldUmlauts,
  isLetter,
  foldScripts,
  stripArabicMarks,
  hasArabic,
  hasHan,
} from '../src/core/text.js';

test('normalizeBasic unifies apostrophes, dashes and spaces', () => {
  expect(normalizeBasic('  l’homme  ')).toBe("l'homme");
  expect(normalizeBasic('c’est–à–dire')).toBe("c'est-à-dire");
  expect(normalizeBasic('la rue \n  ')).toBe('la rue');
  expect(normalizeBasic(null)).toBe('');
});

test('normalizeBasic keeps tabs when asked', () => {
  expect(normalizeBasic(' le nom \t  der Name ', { keepTabs: true })).toBe('le nom\tder Name');
  expect(normalizeBasic('a\tb')).toBe('a b');
});

test('normalizeBasic produces NFC', () => {
  const decomposed = 'é';
  expect(normalizeBasic(decomposed)).toBe('é');
});

test('stripDiacritics', () => {
  expect(stripDiacritics('séparée')).toBe('separee');
  expect(stripDiacritics('garçon')).toBe('garcon');
  expect(stripDiacritics('Mädchen')).toBe('Madchen');
  expect(stripDiacritics('Straße')).toBe('Strasse');
  expect(stripDiacritics('cœur')).toBe('coeur');
});

test('foldUmlauts', () => {
  expect(foldUmlauts('Mädchen')).toBe('Maedchen');
  expect(foldUmlauts('hübsch')).toBe('huebsch');
  expect(foldUmlauts('Ärger')).toBe('Aerger');
  expect(foldUmlauts('séparée')).toBe('separee');
});

test('isLetter', () => {
  expect(isLetter('é')).toBe(true);
  expect(isLetter("'")).toBe(false);
});

// ---------------------------------------------------------------------------
// Arabic and Chinese

test('normalizeBasic drops bidi controls like zero-width characters', () => {
  expect(normalizeBasic('‏كتاب‏')).toBe('كتاب');
  expect(normalizeBasic('‎hello‎')).toBe('hello');
  expect(normalizeBasic('؜أ‫ب‬‪ج‭‮')).toBe('أبج');
  expect(normalizeBasic('⁦a⁧b⁨c⁩')).toBe('abc');
  expect(normalizeBasic('‏كتاب‏\tBuch', { keepTabs: true })).toBe('كتاب\tBuch');
});

test('foldScripts removes Arabic vowel marks, Quranic marks and tatweel, keeps hamza and madda', () => {
  expect(foldScripts('كِتَابٌ')).toBe('كتاب'); // kasra, fatha, dammatan
  expect(foldScripts('مُدَرِّسَةٌ')).toBe('مدرسة'); // shadda
  expect(foldScripts('قُلْ')).toBe('قل'); // sukun
  expect(foldScripts('هٰذا')).toBe('هذا'); // superscript alef
  expect(foldScripts('عَلَيْهِؐ')).toBe('عليه'); // Quranic sign U+0610
  expect(foldScripts('الرَّحْمَٰنِۖ')).toBe('الرحمن'); // small high ligature U+06D6
  expect(foldScripts('كتـــاب')).toBe('كتاب'); // tatweel
  expect(foldScripts('أب')).toBe('أب');
  expect(foldScripts('القرآن')).toBe('القرآن');
  expect(foldScripts('إسلام')).toBe('إسلام');
  // A hamza kept apart from its alef by a Quranic mark composes again.
  expect(foldScripts('اۖٔ')).toBe('أ');
  // Decomposed input comes out composed (NFC).
  expect(foldScripts('آ')).toBe('آ');
});

test('foldScripts turns Arabic presentation forms into plain letters (those characters only)', () => {
  expect(foldScripts('ﻛﺘﺎﺏ')).toBe('كتاب');
  expect(foldScripts('ﻻ')).toBe('لا');
  expect(foldScripts('ﻵ')).toBe('لآ');
  // No whole-string NFKC: ligatures, superscripts and fractions of other text stay.
  expect(foldScripts('ﬁn ² ½ ﻛ')).toBe('ﬁn ² ½ ك');
});

test('foldScripts maps Arabic and full-width punctuation to ASCII', () => {
  expect(foldScripts('كتاب، دفتر؛ قلم؟')).toBe('كتاب, دفتر; قلم?');
  expect(foldScripts('你好（nǐ hǎo），再见！')).toBe('你好(nǐ hǎo),再见!');
  expect(foldScripts('谢谢、多谢；再见：好吗？')).toBe('谢谢,多谢;再见:好吗?');
  expect(foldScripts('我是学生。')).toBe('我是学生.');
  expect(foldScripts('【注意】［x］')).toBe('[注意][x]');
  expect(foldScripts('ＡＢＣ１２３～')).toBe('ABC123~');
  // Quotes stay (grading drops them as punctuation).
  expect(foldScripts('「你好」《书》')).toBe('「你好」《书》');
});

test('foldScripts removes spaces between two Han characters only', () => {
  expect(foldScripts('你 好')).toBe('你好');
  expect(foldScripts('我 是  学 生')).toBe('我是学生');
  expect(foldScripts('你好 nǐ hǎo')).toBe('你好 nǐ hǎo');
  expect(foldScripts('nǐ hǎo 你好')).toBe('nǐ hǎo 你好');
  expect(foldScripts('𠀀 𠀁 㐀 丽')).toBe('𠀀𠀁㐀丽'); // Extension B, Extension A, compatibility ideographs
  expect(foldScripts('東京 Tokyo')).toBe('東京 Tokyo');
});

test('foldScripts leaves Latin text alone (NFC only) and never throws', () => {
  for (const s of ["l'homme", 'Straße', 'cœur', 'garçon, fille', 'a … b', '¿Qué?', '« oui »', 'ﬁ']) {
    expect(foldScripts(s)).toBe(s);
  }
  expect(foldScripts('é')).toBe('é');
  expect(foldScripts(null)).toBe('');
  expect(foldScripts(undefined)).toBe('');
  expect(foldScripts(42)).toBe('42');
});

test('stripArabicMarks drops vowel marks and tatweel, nothing else', () => {
  expect(stripArabicMarks('كِتَابٌ')).toBe('كتاب');
  expect(stripArabicMarks('كتـاب')).toBe('كتاب');
  expect(stripArabicMarks('أَب')).toBe('أب');
  expect(stripArabicMarks('café')).toBe('café');
  expect(stripArabicMarks(null)).toBe('');
});

test('hasArabic and hasHan use explicit script ranges', () => {
  expect(hasArabic('كتاب')).toBe(true);
  expect(hasArabic('ﻛ')).toBe(true);
  expect(hasArabic('ݐ')).toBe(true); // Arabic Supplement
  expect(hasArabic('café')).toBe(false);
  expect(hasArabic('﻿')).toBe(false);
  expect(hasArabic(null)).toBe(false);
  expect(hasHan('你好')).toBe(true);
  expect(hasHan('a漢b')).toBe(true);
  expect(hasHan('𠀀')).toBe(true);
  expect(hasHan('nǐ hǎo')).toBe(false);
  expect(hasHan('。、')).toBe(false);
  expect(hasHan('かな')).toBe(false);
});

await run('text.test.js');
