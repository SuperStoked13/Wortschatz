// Page-wide file drop for the editor: while files are dragged over the page a
// full-screen target appears, and dropping anywhere imports them.

import { h } from '../lib/dom.js';
import { icon } from '../ui/icons.js';

// dragover fires continuously while hovering; this long without one means the drag left.
const LEAVE_DELAY = 180;

const hasFiles = (e) => !!(e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files'));

/**
 * bindPageDrop({ onFiles(FileList), onActive(boolean) }) -> unbind()
 */
export function bindPageDrop({ onFiles, onActive } = {}) {
  let screen = null;
  let timer = null;
  let active = false;

  function setActive(next) {
    if (next === active) return;
    active = next;
    if (typeof onActive === 'function') onActive(active);
  }

  function show() {
    if (!screen) {
      screen = h(
        'div',
        { class: 'ed-dropscreen', 'aria-hidden': 'true' },
        h(
          'div',
          { class: 'ed-dropscreen__card' },
          h('span', { class: 'ed-dropscreen__icon' }, icon('upload', { size: 28 })),
          h('strong', { class: 'ed-dropscreen__title' }, 'Datei loslassen zum Importieren'),
          h('span', { class: 'ed-dropscreen__sub' }, 'Text, CSV, PDF oder Foto – mehrere Dateien gehen auch.'),
        ),
      );
    }
    if (!screen.isConnected) document.body.append(screen);
    setActive(true);
  }

  function hide() {
    clearTimeout(timer);
    if (screen) screen.remove();
    setActive(false);
  }

  const onDragOver = (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'copy';
    show();
    clearTimeout(timer);
    timer = setTimeout(hide, LEAVE_DELAY);
  };

  const onDrop = (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    hide();
    if (typeof onFiles === 'function') onFiles(e.dataTransfer.files);
  };

  document.addEventListener('dragover', onDragOver);
  document.addEventListener('drop', onDrop);

  return () => {
    hide();
    document.removeEventListener('dragover', onDragOver);
    document.removeEventListener('drop', onDrop);
  };
}
