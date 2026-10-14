import { test, expect, run } from './harness.js';
import { normalizeBasic, stripDiacritics, foldUmlauts, isLetter } from '../src/core/text.js';

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

await run('text.test.js');
