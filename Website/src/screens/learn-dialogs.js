// Learn mode dialogs and card actions: the options sheet (with "Neu starten?" when
// a change only applies to a new session), restarting, editing and starring the
// card on screen, and "Nochmal lernen" (reset the scope's progress, start over).
// Works on the screen context `c` of learn.js and the answer flow of learn-answer.js.

import { db } from '../store/db.js';
import { typeAhead } from '../core/typeahead.js';
import { confirmDialog, toast } from '../ui/components.js';
import { learnReviewEnabled } from '../ui/study-options.js';
import { ask, openCardEditor, openOptionsDialog } from './write-dialogs.js';
import { hasText, gradeQuestion } from './write-model.js';
import { settingsChanges, restartMessage, restartSessionMessage, choiceTexts } from './learn-model.js';

export function createLearnDialogs(c, answers) {
  // Closing a dialog returns focus to the button that opened it (e.g. the sidebar's
  // "Optionen"), where the next Enter would open it again: hand it back to the step,
  // and restart a countdown the dialog interrupted.
  function resumeAfterOverlay({ wasTimer = false, retypeChanged = false } = {}) {
    if (c.disposed) return;
    if (c.stage !== 'question') {
      c.focusStage();
      return;
    }
    if (c.current && c.last) {
      if (c.phase === 'correct' && wasTimer) {
        if (c.last.kind === 'mc') answers.showMcResult();
        else answers.showWrittenCorrect();
      } else if (c.phase === 'incorrect' && retypeChanged && c.last.kind === 'written') {
        answers.showWrittenIncorrect();
      }
    }
    c.focusCurrent();
  }

  // ------------------------------------------------------------- options
  // What a new session would be built with: the set's options plus whether it asks
  // repetition questions (the "Wiederholungsfragen" preference, or review=1).
  const sessionSource = () => ({ answerWith: c.options.answerWith, learn: c.options.learn, review: c.reviewWanted() });

  function openOptions() {
    if (!c.state || c.stage === 'message') return;
    const wasTimer = !!c.advanceTimer;
    c.clearAdvance();
    const before = { source: sessionSource(), retype: c.retypeOn(), review: learnReviewEnabled() };
    openOptionsDialog({
      options: c.options,
      termLang: c.set.termLang,
      defLang: c.set.defLang,
      mode: 'learn',
      onChange: (patch) => {
        const next = c.write(() => db.updateStudyOptions(c.setId, patch));
        if (next) c.options = next;
      },
      onClose: ({ reason, restartAsked }) => {
        if (reason !== 'route' && !c.disposed) afterOptions({ before, wasTimer, restartAsked });
      },
    });
  }

  async function afterOptions({ before, wasTimer, restartAsked }) {
    // Switching "Wiederholungsfragen" is a choice of its own: it replaces a forced
    // review=1 (the exam's "Falsche lernen") for the next sessions.
    if (learnReviewEnabled() !== before.review) c.setReviewForced(false);
    if (restartAsked) {
      confirmRestart({ wasTimer });
      return;
    }
    // Direction, question types, round size and the repetition questions shape the
    // session: they need a restart. Tolerance, audio and the copy step apply at once.
    const now = sessionSource();
    const changes = c.state ? settingsChanges(c.state, now) : [];
    if (c.state && c.state.finishedAt == null && settingsChanges(before.source, now).length && changes.length) {
      const ok = await ask({ title: 'Neu starten?', message: restartMessage(changes), confirmLabel: 'Neu starten', cancelLabel: 'Später' });
      if (c.disposed) return;
      if (ok) {
        c.startFresh(c.state.subset);
        return;
      }
    }
    resumeAfterOverlay({ wasTimer, retypeChanged: c.retypeOn() !== before.retype });
  }

  async function confirmRestart({ wasTimer = false } = {}) {
    if (!c.state || c.stage === 'message') return;
    const timerWasRunning = wasTimer || !!c.advanceTimer;
    c.clearAdvance();
    const ok = await ask({
      title: 'Neu starten?',
      message: restartSessionMessage(c.state.subset),
      confirmLabel: 'Neu starten',
    });
    if (c.disposed) return;
    if (ok) c.startFresh(c.state ? c.state.subset : 'all');
    else resumeAfterOverlay({ wasTimer: timerWasRunning });
  }

  // "Nochmal lernen": forget the progress of the scope's cards, then start over.
  async function confirmRelearn(subset, ids) {
    const n = ids.length;
    const ok = await confirmDialog({
      title: 'Fortschritt zurücksetzen?',
      message: `Der Lernfortschritt ${n === 1 ? 'dieses Begriffs' : `dieser ${n} Begriffe`} wird zurückgesetzt. Danach lernst du ${n === 1 ? 'ihn' : 'sie'} von vorne – zuerst mit Multiple Choice.`,
      confirmLabel: 'Zurücksetzen',
    });
    if (c.disposed) return;
    if (!ok) {
      c.focusStage();
      return;
    }
    if (subset === 'all') c.write(() => db.resetProgress(c.setId));
    else c.write(() => db.resetCardProgress(c.setId, ids));
    c.startFresh(subset);
  }

  // --------------------------------------------------------- card edits
  function toggleStar() {
    if (c.stage !== 'question' || !c.current) return false;
    const value = c.write(() => db.toggleStar(c.setId, c.current.q.cardId));
    const fresh = db.getSet(c.setId);
    if (fresh) {
      c.set = fresh;
      c.indexCards();
    }
    if (c.current.q.type === 'written') c.card.focusPrimary();
    return !!value;
  }

  // Shows the current texts of the question on screen (after an edit here or elsewhere).
  function refreshCurrent({ regrade = false } = {}) {
    if (c.stage !== 'question' || !c.current) return;
    const info = c.questionInfo(c.current.q);
    if (!info) return;
    c.current.info = info;
    if (c.last) c.last.info = info;
    if (c.current.q.type === 'mc') {
      c.current.choices = choiceTexts(c.current.q.choices, c.cards, c.current.q.ask);
      c.mc.refresh(info, c.current.choices);
      // The letters typed match the new texts (the highlight follows them).
      if (c.phase === 'question' && c.typing.typed) {
        c.typing = { ...c.typing, highlighted: typeAhead(c.typing.typed, c.current.choices.map((x) => x.text), info.answerLang).selected };
      }
      c.drawTyping();
      return;
    }
    c.card.refresh(info);
    if (regrade && c.phase === 'incorrect' && c.last && c.last.kind === 'written') {
      // If the corrected card now accepts what was typed, offer to count it.
      const r = !c.last.dontKnow && hasText(c.last.given) ? gradeQuestion(c.set, info, c.last.given, c.options.tolerance).result : null;
      c.last.editedCorrect = !!(r && r.correct);
      answers.showWrittenIncorrect();
    }
  }

  function openEdit() {
    if (c.stage !== 'question' || !c.current) return;
    const info = c.questionInfo(c.current.q);
    const card = info && c.cards.get(info.cardId);
    if (!card) return;
    const wasTimer = !!c.advanceTimer;
    c.clearAdvance();
    openCardEditor({
      termLang: c.set.termLang,
      defLang: c.set.defLang,
      card,
      focusSide: info.ask,
      onSave: (changes) => {
        if (!c.write(() => db.updateCard(c.setId, card.id, changes))) return false;
        const fresh = db.getSet(c.setId);
        if (!fresh) {
          c.showGone();
          return true;
        }
        c.set = fresh;
        c.indexCards();
        refreshCurrent({ regrade: true });
        toast('Karte gespeichert', { tone: 'success', duration: 2200 });
        return true;
      },
      onClose: (reason) => {
        if (reason !== 'route' && !c.disposed) resumeAfterOverlay({ wasTimer });
      },
    });
  }

  return { openOptions, confirmRestart, confirmRelearn, toggleStar, openEdit, refreshCurrent };
}
