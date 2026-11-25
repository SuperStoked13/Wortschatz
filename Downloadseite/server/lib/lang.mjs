// German and English: which language a request gets, and the server's own texts in both.
//
// The pages exist in both languages (German at /, English at /en, see PAGES in app.mjs); the visitor's
// browser picks one with public/assets/js/lang.js. The server only chooses for what it answers by
// itself (error pages, the login, messages for the page script), with the same rule as lang.js:
// German when the browser puts German before English, otherwise English. No header at all
// (scripts, curl) stays German, the site's first language.

export const LANGUAGES = Object.freeze(['de', 'en']);

/** "/en", "/en/privacy" → 'en'; everything else → 'de'. */
export function languageOfPath(path) {
  return path === '/en' || String(path).startsWith('/en/') ? 'en' : 'de';
}

/**
 * The language for an Accept-Language header ("de-CH,de;q=0.9,en;q=0.8"): the first of German or
 * English in the order of preference, English when the browser names neither, German without header.
 */
export function preferredLanguage(header) {
  const ranges = String(header ?? '')
    .split(',')
    .map((part, index) => {
      const [tag, ...params] = part.trim().toLowerCase().split(';');
      const q = params.map((p) => /^\s*q\s*=\s*([01](?:\.\d{0,3})?)\s*$/.exec(p)?.[1]).find(Boolean);
      return { tag: tag.trim(), q: q === undefined ? 1 : Number(q), index };
    })
    .filter((range) => range.tag && range.q > 0)
    .sort((a, b) => b.q - a.q || a.index - b.index);
  if (!ranges.length) return 'de';
  for (const { tag } of ranges) {
    const primary = tag.split('-')[0];
    if (primary === 'de' || primary === 'en') return primary;
  }
  return 'en';
}

const DATE_FORMATS = Object.freeze({
  de: new Intl.DateTimeFormat('de-CH', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }),
  en: new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }),
});

/** "2026-10-20" → "20. Oktober 2026" or "20 October 2026"; '' for anything else. */
export function formatDate(iso, lang = 'de') {
  const date = new Date(`${iso}T00:00:00Z`);
  return iso && !Number.isNaN(date.getTime()) ? (DATE_FORMATS[lang] ?? DATE_FORMATS.de).format(date) : '';
}

// The release manifests (written by tools/release-*.sh) describe the system in German.
const LABELS_EN = [
  [/\boder neuer\b/g, 'or later'],
  [/\boder\b/g, 'or'],
  [/\bund\b/g, 'and'],
  [/\b(\d+) Bit\b/g, '$1-bit'],
];

/** "macOS 26 oder neuer" → "macOS 26 or later", "64 Bit (x64)" → "64-bit (x64)". */
export function englishLabel(text) {
  return LABELS_EN.reduce((value, [pattern, replacement]) => value.replace(pattern, replacement), String(text ?? ''));
}

/** "120 Sekunden", "2 Minuten" / "2 minutes". */
function duration(seconds, lang) {
  if (seconds % 60 === 0) {
    const minutes = seconds / 60;
    if (lang === 'en') return `${minutes} ${minutes === 1 ? 'minute' : 'minutes'}`;
    return `${minutes} ${minutes === 1 ? 'Minute' : 'Minuten'}`;
  }
  return lang === 'en' ? `${seconds} seconds` : `${seconds} Sekunden`;
}

const ERRORS = Object.freeze({
  de: Object.freeze({
    400: ['Ungültige Anfrage', 'Diese Adresse kann der Server nicht verarbeiten.'],
    401: ['Anmeldung nötig', 'Diese Seite ist passwortgeschützt. Melde dich auf der Startseite mit dem Passwort an.'],
    403: ['Kein Zugriff', 'Diese Anfrage ist nicht erlaubt.'],
    404: ['Seite nicht gefunden', 'Diese Seite gibt es nicht. Prüf die Adresse oder geh zur Startseite.'],
    405: ['Nicht erlaubt', 'Diese Art von Anfrage wird hier nicht unterstützt.'],
    410: ['Nicht mehr gültig', 'Dieser Link gilt nicht mehr. Lade Wortschatz über die Website.'],
    413: ['Anfrage zu gross', 'Die Anfrage ist zu gross.'],
    414: ['Adresse zu lang', 'Die Adresse ist zu lang.'],
    415: ['Format nicht unterstützt', 'Dieses Format nimmt der Server nicht an.'],
    421: ['Falsche Adresse', 'Diese Website ist unter einer anderen Adresse erreichbar.'],
    429: ['Zu viele Anfragen', 'Von deiner Internetadresse kamen sehr viele Anfragen. Warte einen Moment und versuch es dann nochmals.'],
    500: ['Serverfehler', 'Etwas ist schiefgelaufen. Versuch es in einem Moment nochmals.'],
    503: ['Gerade ausgelastet', 'Der Server ist im Moment ausgelastet. Versuch es gleich nochmals.'],
  }),
  en: Object.freeze({
    400: ['Bad request', 'The server can’t handle this address.'],
    401: ['Sign-in needed', 'This site is password protected. Sign in with the password on the home page.'],
    403: ['No access', 'This request isn’t allowed.'],
    404: ['Page not found', 'This page doesn’t exist. Check the address or go to the home page.'],
    405: ['Not allowed', 'This kind of request isn’t supported here.'],
    410: ['No longer valid', 'This link has expired. Download Wortschatz from the website.'],
    413: ['Request too large', 'The request is too large.'],
    414: ['Address too long', 'The address is too long.'],
    415: ['Format not supported', 'The server doesn’t accept this format.'],
    421: ['Wrong address', 'This website lives at a different address.'],
    429: ['Too many requests', 'A lot of requests came from your internet address. Wait a moment, then try again.'],
    500: ['Server error', 'Something went wrong. Try again in a moment.'],
    503: ['Busy right now', 'The server is busy at the moment. Try again shortly.'],
  }),
});

/** The title and message of an HTTP status. */
export function errorText(status, lang = 'de') {
  const table = ERRORS[lang] ?? ERRORS.de;
  return table[status] ?? table[500];
}

const MESSAGES = Object.freeze({
  de: Object.freeze({
    busy: ['Gerade viel los', () => 'Im Moment laufen viele Downloads gleichzeitig. Versuch es in ein paar Sekunden nochmals.'],
    refused: ['Download nicht möglich', () => 'Lade Wortschatz bitte direkt über die Website.'],
    notYet: ['Noch nicht verfügbar', ({ platform }) => `Die Version für ${platform} wird gerade vorbereitet.`],
    invalidLink: ['Link ungültig', () => 'Dieser Download-Link ist ungültig. Lade Wortschatz über die Website.'],
    expired: ['Link abgelaufen', ({ seconds }) => `Ein Download-Link gilt ${duration(seconds, 'de')}. Lade Wortschatz einfach nochmals über die Website.`],
    otherDevice: ['Link für ein anderes Gerät', () => 'Dieser Download-Link gilt nur für das Gerät, das ihn angefordert hat. Lade Wortschatz über die Website.'],
    newVersion: ['Neue Version', () => 'Inzwischen gibt es eine neue Version. Lade sie über die Website.'],
    used: ['Link schon verwendet', () => 'Dieser Download-Link wurde schon verwendet. Lade Wortschatz nochmals über die Website.'],
    replacing: ['Neue Version unterwegs', () => 'Die Datei wird gerade ersetzt. Versuch es in einer halben Minute nochmals.'],
    moved: ['Seite neu laden', () => 'Wortschatz kommt jetzt direkt von GitHub. Lade die Seite neu und klicke nochmals auf «Laden».'],
  }),
  en: Object.freeze({
    busy: ['A lot going on', () => 'Many downloads are running at the moment. Try again in a few seconds.'],
    refused: ['Download not possible', () => 'Please download Wortschatz directly from the website.'],
    notYet: ['Not available yet', ({ platform }) => `The ${platform} version is being prepared.`],
    invalidLink: ['Invalid link', () => 'This download link isn’t valid. Download Wortschatz from the website.'],
    expired: ['Link expired', ({ seconds }) => `A download link is valid for ${duration(seconds, 'en')}. Just download Wortschatz again from the website.`],
    otherDevice: ['Link for another device', () => 'This download link only works on the device that asked for it. Download Wortschatz from the website.'],
    newVersion: ['New version', () => 'There’s a newer version now. Download it from the website.'],
    used: ['Link already used', () => 'This download link has already been used. Download Wortschatz again from the website.'],
    replacing: ['New version on its way', () => 'The file is being replaced right now. Try again in half a minute.'],
    moved: ['Reload the page', () => 'Wortschatz now comes straight from GitHub. Reload the page and click the download button again.'],
  }),
});

/** { title, message } of one of the server's messages, in German or English. */
export function message(key, lang = 'de', values = {}) {
  const [title, text] = (MESSAGES[lang] ?? MESSAGES.de)[key];
  return { title, message: text(values) };
}
