/*
  Wortschatz website: the download buttons (with signed links from the server, or plain
  links to the file on GitHub), the Return key as the page's one primary action, toasts,
  copy buttons and the light on interactive glass. Everything works without JavaScript
  too: the forms then post directly and the server answers with the file, and the links
  are links.
*/
(() => {
  'use strict';

  const html = document.documentElement;
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  const SVG = 'http://www.w3.org/2000/svg';
  const lang = html.lang.startsWith('en') ? 'en' : 'de';

  // ------------------------------------------------------------- language

  const TEXT = {
    de: {
      close: 'Meldung schliessen',
      running: 'Download läuft',
      failedTitle: 'Download nicht möglich',
      failedText: 'Der Download konnte nicht gestartet werden. Versuch es gleich nochmals.',
      started: 'Download gestartet',
      next: 'So geht es weiter',
      copy: 'Kopieren',
      copied: 'Kopiert',
      selected: 'Markiert',
    },
    en: {
      close: 'Close message',
      running: 'Downloading',
      failedTitle: 'Download not possible',
      failedText: 'The download couldn’t be started. Try again in a moment.',
      started: 'Download started',
      next: 'What to do next',
      copy: 'Copy',
      copied: 'Copied',
      selected: 'Selected',
    },
  }[lang];

  // The DE/EN switch: remembered for the next visit (lang.js), on this device only.
  document.addEventListener('click', (event) => {
    const target = event.target instanceof Element ? event.target.closest('[data-lang-switch]') : null;
    if (!target) return;
    try {
      window.localStorage.setItem('wortschatz-sprache', target.dataset.langSwitch);
    } catch {
      // No storage (private window, blocked): the link still leads to the other language.
    }
  });

  // ------------------------------------------------------------- platform

  function detectPlatform() {
    const ua = navigator.userAgent || '';
    const platform = navigator.userAgentData?.platform || navigator.platform || '';
    if (/iPhone|iPad|iPod/i.test(ua) || (/Mac/i.test(platform) && navigator.maxTouchPoints > 1)) return 'ios';
    if (/Android/i.test(ua)) return 'android';
    if (/Mac/i.test(platform) || /Macintosh/i.test(ua)) return 'mac';
    if (/Win/i.test(platform) || /Windows/i.test(ua)) return 'windows';
    return 'other';
  }

  const platform = detectPlatform();
  const isPhone = platform === 'ios' || platform === 'android';
  html.dataset.platform = platform;

  // A download is a form (the file from this server) or a link (the file on GitHub).
  const DOWNLOADS = 'form.dl-form[data-platform], a.dl-link[data-platform]';

  /** Makes the download of `name` the primary (accent) button everywhere on the page. */
  function makePrimary(name) {
    for (const download of document.querySelectorAll(DOWNLOADS)) {
      const primary = download.dataset.platform === name;
      const button = download.matches('a') ? download : download.querySelector('button');
      button?.classList.toggle('btn-primary', primary);
      button?.classList.toggle('btn-glass', !primary);
      const hint = download.querySelector('[data-return-hint]');
      if (hint) hint.hidden = !primary || isPhone;
    }
  }

  const heroActions = document.querySelector('[data-hero-actions]');
  if (heroActions) {
    const windowsForm = heroActions.querySelector('form[data-platform="windows"], a.dl-link[data-platform="windows"]');
    if (platform === 'windows' && windowsForm) {
      heroActions.prepend(windowsForm);
      makePrimary('windows');
    }
    if (isPhone) {
      const note = document.querySelector('[data-mobile-note]');
      if (note) note.hidden = false;
      heroActions.querySelectorAll('[data-return-hint]').forEach((hint) => {
        hint.hidden = true;
      });
    }
  }

  // ---------------------------------------------------------------- toasts

  const toastRoot = document.querySelector('[data-toasts]');

  function icon(id, className) {
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('class', className);
    svg.setAttribute('aria-hidden', 'true');
    const use = document.createElementNS(SVG, 'use');
    use.setAttribute('href', `#${id}`);
    svg.append(use);
    return svg;
  }

  function toast({ title, text = '', tone = 'success', action = null, duration = 7000 }) {
    if (!toastRoot) return;
    const node = document.createElement('div');
    node.className = `toast glass${tone === 'error' ? ' is-error' : ''}`;

    const body = document.createElement('div');
    const heading = document.createElement('p');
    heading.className = 'toast-title';
    heading.textContent = title;
    body.append(heading);
    if (text) {
      const line = document.createElement('p');
      line.className = 'toast-text';
      line.textContent = text;
      body.append(line);
    }
    if (action) {
      const link = document.createElement('a');
      link.className = 'toast-action';
      link.href = action.href;
      link.textContent = action.label;
      body.append(link);
    }

    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'toast-close';
    close.setAttribute('aria-label', TEXT.close);
    close.append(icon('i-close', 'i'));

    node.append(icon(tone === 'error' ? 'i-x-circle' : 'i-check-circle', 'toast-icon'), body, close);
    toastRoot.append(node);
    while (toastRoot.children.length > 3) toastRoot.firstElementChild.remove();

    let timer = 0;
    const dismiss = () => {
      window.clearTimeout(timer);
      if (still.matches) {
        node.remove();
        return;
      }
      node.classList.add('is-leaving');
      node.addEventListener('animationend', () => node.remove(), { once: true });
    };
    const arm = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(dismiss, duration);
    };
    close.addEventListener('click', dismiss);
    node.addEventListener('pointerenter', () => window.clearTimeout(timer));
    node.addEventListener('pointerleave', arm);
    node.addEventListener('focusin', () => window.clearTimeout(timer));
    arm();
  }

  // ------------------------------------------------------------- downloads

  const sizeFormat = new Intl.NumberFormat(lang === 'en' ? 'en-GB' : 'de-CH', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  const formatSize = (bytes) =>
    bytes < 1_000_000 ? `${Math.max(1, Math.round(bytes / 1000))} KB` : `${sizeFormat.format(bytes / 1_000_000)} MB`;

  function showStarted(button) {
    const label = button?.querySelector('.btn-label');
    if (!label) return;
    const original = label.dataset.original || label.textContent;
    label.dataset.original = original;
    label.textContent = TEXT.running;
    window.setTimeout(() => {
      label.textContent = original;
    }, 4000);
  }

  /** After a download has begun: the button says so, a toast names the file, and the first-start steps open. */
  function started(name, button, file, size) {
    showStarted(button);
    const help = document.querySelector(`details[data-help="${name === 'windows' ? 'windows' : 'mac'}"]`);
    const bytes = Number(size);
    toast({
      title: TEXT.started,
      text: file && bytes > 0 ? `${file}, ${formatSize(bytes)}` : file || '',
      action: help ? { label: TEXT.next, href: `#${help.id}` } : null,
    });
    // Straight to the first-start steps, which are needed before the app opens.
    if (help) openHelp(help.id);
  }

  async function startDownload(form) {
    if (form.dataset.busy) return;
    form.dataset.busy = '1';
    const button = form.querySelector('button[type="submit"]');
    button?.classList.add('is-busy');
    try {
      let response;
      try {
        response = await fetch(form.action, {
          method: 'POST',
          // The server's messages in the page's language.
          headers: { Accept: 'application/json', 'Accept-Language': lang, 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams(new FormData(form)).toString(),
          credentials: 'same-origin',
          cache: 'no-store',
          redirect: 'error',
        });
      } catch {
        // No connection to the server from script: let the browser post the form itself.
        form.submit();
        return;
      }
      let data = null;
      try {
        data = await response.json();
      } catch {
        data = null;
      }
      if (!response.ok || !data || typeof data.url !== 'string' || !data.url.startsWith('/dl/')) {
        toast({
          tone: 'error',
          title: data?.title || TEXT.failedTitle,
          text: data?.message || TEXT.failedText,
        });
        return;
      }
      window.location.assign(data.url);
      started(form.dataset.platform, button, data.file, data.size);
    } finally {
      delete form.dataset.busy;
      button?.classList.remove('is-busy');
    }
  }

  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement) || !form.matches('.dl-form')) return;
    if (!window.fetch || !window.URLSearchParams || !window.FormData) return;
    event.preventDefault();
    startDownload(form);
  });

  // A link to the file on GitHub: the browser follows it and saves the file (the page stays);
  // here only what follows a download. A click with a modifier opens a tab instead, so nothing.
  document.addEventListener('click', (event) => {
    const link = event.target instanceof Element ? event.target.closest('a.dl-link[data-platform]') : null;
    if (!link || event.defaultPrevented || event.button !== 0 || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    started(link.dataset.platform, link, link.dataset.file, link.dataset.size);
  });

  // --------------------------------------------- the page's Return action

  const bigKey = document.querySelector('[data-big-key]');
  let heroInView = Boolean(heroActions);
  if (heroActions && 'IntersectionObserver' in window) {
    new IntersectionObserver(
      ([entry]) => {
        heroInView = entry.isIntersecting;
      },
      { threshold: 0.5 },
    ).observe(heroActions);
  }

  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter' || event.isComposing) return;
    bigKey?.classList.add('is-down');
    if (event.repeat || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    const active = document.activeElement;
    if (active && active !== document.body && active !== html) return;
    if (!heroActions || !heroInView || isPhone) return;
    const button = heroActions.querySelector('form .btn-primary, a.dl-link.btn-primary');
    if (!button) return;
    event.preventDefault();
    button.classList.add('is-pressed');
    window.setTimeout(() => button.classList.remove('is-pressed'), 160);
    // A link: as if clicked (follows it, and the click handler above does the rest).
    if (button.matches('a')) button.click();
    else startDownload(button.closest('form'));
  });

  const release = () => bigKey?.classList.remove('is-down');
  document.addEventListener('keyup', (event) => {
    if (event.key === 'Enter') release();
  });
  window.addEventListener('blur', release);

  // ----------------------------------------------------------- copy, help

  document.addEventListener('click', async (event) => {
    const target = event.target instanceof Element ? event.target : null;
    const copy = target?.closest('[data-copy]');
    if (copy) {
      const label = copy.querySelector('[data-copy-label]');
      if (label && !label.dataset.original) label.dataset.original = label.textContent;
      const reset = () => {
        copy.classList.remove('is-done');
        if (label) label.textContent = label.dataset.original || TEXT.copy;
      };
      // A link to this page: at the address it was opened under (the Cloudflare address works where DuckDNS is blocked).
      const text = copy.hasAttribute('data-copy-page') ? window.location.origin + window.location.pathname : copy.dataset.copy;
      try {
        await navigator.clipboard.writeText(text);
        copy.classList.add('is-done');
        if (label) label.textContent = TEXT.copied;
      } catch {
        const code = copy.parentElement?.querySelector('[data-checksum]');
        if (code) {
          const range = document.createRange();
          range.selectNodeContents(code);
          const selection = window.getSelection();
          selection?.removeAllRanges();
          selection?.addRange(range);
          if (label) label.textContent = TEXT.selected;
        } else if (label) {
          label.textContent = text;
        }
      }
      window.setTimeout(reset, 2200);
      return;
    }

    const help = target?.closest('a[href^="#"]');
    if (help && document.getElementById(help.getAttribute('href').slice(1)) instanceof HTMLDetailsElement) {
      event.preventDefault();
      const id = help.getAttribute('href').slice(1);
      openHelp(id);
      history.replaceState(null, '', `#${id}`);
    }
  });

  function openHelp(id) {
    const details = document.getElementById(id);
    if (!(details instanceof HTMLDetailsElement)) return;
    details.open = true;
    // 'start' keeps the heading in view below the nav (scroll-padding-top), even when the steps are taller than the window.
    details.scrollIntoView({ behavior: still.matches ? 'auto' : 'smooth', block: 'start' });
    details.querySelector('summary')?.focus({ preventScroll: true });
  }

  try {
    if (location.hash.length > 1) openHelp(decodeURIComponent(location.hash.slice(1)));
  } catch {
    // a broken address: nothing to open
  }

  // ----------------------------------------------------- light on glass

  if (window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
    let lit = null;
    let frame = 0;
    let lastEvent = null;
    const update = () => {
      frame = 0;
      const event = lastEvent;
      const target = event?.target instanceof Element ? event.target.closest('.glass-live, .btn-glass') : null;
      if (target !== lit) {
        lit?.style.setProperty('--light', '0');
        lit = target;
        lit?.style.setProperty('--light', '1');
      }
      if (lit && event) {
        const box = lit.getBoundingClientRect();
        lit.style.setProperty('--lx', `${event.clientX - box.left}px`);
        lit.style.setProperty('--ly', `${event.clientY - box.top}px`);
      }
    };
    document.addEventListener(
      'pointermove',
      (event) => {
        lastEvent = event;
        if (!frame) frame = requestAnimationFrame(update);
      },
      { passive: true },
    );
    document.addEventListener('pointerleave', () => {
      lastEvent = null;
      update();
    });
  }
})();
