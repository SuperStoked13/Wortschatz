/*
  Wortschatz website: shows each page in the visitor's language before anything is drawn (loaded in
  <head> without defer, before the stylesheet). Every page exists in German and English; the head
  names both (<link rel="alternate" hreflang>).

  Only on arrival from elsewhere (a typed address, a bookmark, a link on another site): the language
  is the one last picked with the DE/EN switch (remembered in localStorage, never sent to the
  server), otherwise the browser's: German when the browser lists German before English, otherwise
  English. Clicks from page to page within the site are never redirected: whoever follows a link
  (or the switch) stays where it goes, even without localStorage.
*/
(() => {
  'use strict';

  const KEY = 'wortschatz-sprache';
  // The same places on the page in the other language.
  const ANCHORS = {
    funktionen: 'features',
    tasten: 'keyboard',
    'hilfe-mac': 'help-mac',
    'hilfe-windows': 'help-windows',
    'hilfe-pruefen': 'help-verify',
    unterstuetzen: 'support',
  };

  const current = document.documentElement.lang.startsWith('en') ? 'en' : 'de';

  function stored() {
    try {
      const value = window.localStorage.getItem(KEY);
      return value === 'de' || value === 'en' ? value : null;
    } catch {
      return null;
    }
  }

  function cameFromThisSite() {
    try {
      return document.referrer !== '' && new URL(document.referrer).origin === window.location.origin;
    } catch {
      return false;
    }
  }

  function browserLanguage() {
    const list = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language];
    let any = false;
    for (const tag of list) {
      if (!tag) continue;
      any = true;
      const primary = String(tag).toLowerCase().split('-')[0];
      if (primary === 'de' || primary === 'en') return primary;
    }
    return any ? 'en' : null;
  }

  function anchor(hash, lang) {
    const id = decodeURIComponent(hash.slice(1));
    if (!id) return hash;
    for (const [de, en] of Object.entries(ANCHORS)) {
      if (lang === 'en' && id === de) return `#${en}`;
      if (lang === 'de' && id === en) return `#${de}`;
    }
    return hash;
  }

  if (cameFromThisSite()) return;
  const wanted = stored() ?? browserLanguage();
  if (!wanted || wanted === current) return;
  const alternate = document.querySelector(`link[rel="alternate"][hreflang="${wanted}"]`);
  if (!alternate) return;
  const target = new URL(alternate.getAttribute('href'), window.location.href);
  window.location.replace(target.pathname + window.location.search + anchor(window.location.hash, wanted));
})();
