/*
  Wortschatz website: the download buttons (with signed links from the server), the
  Return key as the page's one primary action, toasts, copy buttons and the light on
  interactive glass. Everything works without JavaScript too: the forms then post
  directly and the server answers with the file.
*/
(() => {
  'use strict';

  const html = document.documentElement;
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  const SVG = 'http://www.w3.org/2000/svg';

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

  /** Makes the form of `name` the primary (accent) button everywhere on the page. */
  function makePrimary(name) {
    for (const form of document.querySelectorAll('form.dl-form[data-platform]')) {
      const primary = form.dataset.platform === name;
      const button = form.querySelector('button');
      button?.classList.toggle('btn-primary', primary);
      button?.classList.toggle('btn-glass', !primary);
      const hint = form.querySelector('[data-return-hint]');
      if (hint) hint.hidden = !primary || isPhone;
    }
  }

  const heroActions = document.querySelector('[data-hero-actions]');
  if (heroActions) {
    const windowsForm = heroActions.querySelector('form[data-platform="windows"]');
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
    close.setAttribute('aria-label', 'Meldung schliessen');
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

  const sizeFormat = new Intl.NumberFormat('de-CH', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  const formatSize = (bytes) =>
    bytes < 1_000_000 ? `${Math.max(1, Math.round(bytes / 1000))} KB` : `${sizeFormat.format(bytes / 1_000_000)} MB`;

  function showStarted(button) {
    const label = button?.querySelector('.btn-label');
    if (!label) return;
    const original = label.dataset.original || label.textContent;
    label.dataset.original = original;
    label.textContent = 'Download läuft';
    window.setTimeout(() => {
      label.textContent = original;
    }, 4000);
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
          headers: { Accept: 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' },
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
          title: data?.title || 'Download nicht möglich',
          text: data?.message || 'Der Download konnte nicht gestartet werden. Versuch es gleich nochmals.',
        });
        return;
      }
      window.location.assign(data.url);
      showStarted(button);
      const name = form.dataset.platform === 'windows' ? 'windows' : 'mac';
      toast({
        title: 'Download gestartet',
        text: `${data.file}, ${formatSize(data.size)}`,
        action: { label: 'So geht es weiter', href: `#hilfe-${name}` },
      });
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
    const button = heroActions.querySelector('form .btn-primary');
    const form = button?.closest('form');
    if (!form) return;
    event.preventDefault();
    button.classList.add('is-pressed');
    window.setTimeout(() => button.classList.remove('is-pressed'), 160);
    startDownload(form);
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
      const reset = () => {
        copy.classList.remove('is-done');
        if (label) label.textContent = 'Kopieren';
      };
      try {
        await navigator.clipboard.writeText(copy.dataset.copy);
        copy.classList.add('is-done');
        if (label) label.textContent = 'Kopiert';
      } catch {
        const code = copy.parentElement?.querySelector('[data-checksum]');
        if (code) {
          const range = document.createRange();
          range.selectNodeContents(code);
          const selection = window.getSelection();
          selection?.removeAllRanges();
          selection?.addRange(range);
          if (label) label.textContent = 'Markiert';
        }
      }
      window.setTimeout(reset, 2200);
      return;
    }

    const help = target?.closest('a[href^="#hilfe-"]');
    if (help) {
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
    details.scrollIntoView({ behavior: still.matches ? 'auto' : 'smooth', block: 'center' });
    details.querySelector('summary')?.focus({ preventScroll: true });
  }

  if (location.hash.startsWith('#hilfe-')) openHelp(location.hash.slice(1));

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
