// The Windows app (windows/host) shows this web app in WebView2 and announces itself
// before any page script runs: window.wortschatzHost = { platform: 'windows', setTheme, setUnsaved }.
// In a normal browser (Start.command) there is no host. Safe to import anywhere. Also the
// app-window behaviour the host cannot do itself (context menu, links in new windows).

function host() {
  return typeof window !== 'undefined' && window.wortschatzHost ? window.wortschatzHost : null;
}

// True inside the Windows app: copy says "auf diesem Computer" instead of "in diesem Browser".
export function isDesktopApp() {
  const h = host();
  return !!h && h.platform === 'windows';
}

// The window's title bar follows the app's theme ('light' | 'dark').
export function reportTheme(theme) {
  const h = host();
  if (h && typeof h.setTheme === 'function') h.setTheme(theme);
}

// The editor holds changes that are not saved: closing the window asks first.
export function reportUnsaved(on) {
  const h = host();
  if (h && typeof h.setUnsaved === 'function') h.setUnsaved(!!on);
}

// Elements where the system context menu helps (Cut/Copy/Paste, spelling suggestions).
function wantsContextMenu(target) {
  const el = target && target.closest ? target : target && target.parentElement;
  if (el && el.closest && el.closest('input, textarea, [contenteditable=""], [contenteditable="true"]')) return true;
  const selection = typeof window.getSelection === 'function' ? window.getSelection() : null;
  return !!selection && !selection.isCollapsed;
}

// An app window has no browser menu (Zurück, Neu laden, Speichern unter …) on a right click;
// text fields and selected text keep theirs.
export function limitContextMenu() {
  if (!isDesktopApp() || typeof document === 'undefined') return;
  document.addEventListener('contextmenu', (e) => {
    if (!e.defaultPrevented && !wantsContextMenu(e.target)) e.preventDefault();
  });
}

// Whether a click would open a link in a new window: Ctrl-, Shift- or ⌘-click, or a middle
// click (auxclick with button 1). Pure.
export function opensNewWindow(e) {
  if (!e) return false;
  if (e.type === 'auxclick') return e.button === 1;
  return e.button === 0 && !!(e.ctrlKey || e.shiftKey || e.metaKey);
}

// WebView2 opens such a link in a bare popup window that runs a second copy of the app (the
// host cannot catch NewWindowRequested), so in the app those clicks do nothing.
export function blockNewWindows() {
  if (!isDesktopApp() || typeof document === 'undefined') return;
  const guard = (e) => {
    if (!opensNewWindow(e)) return;
    const el = e.target && e.target.closest ? e.target : e.target && e.target.parentElement;
    if (el && el.closest && el.closest('a[href]')) e.preventDefault();
  };
  document.addEventListener('click', guard, true);
  document.addEventListener('auxclick', guard, true);
}
