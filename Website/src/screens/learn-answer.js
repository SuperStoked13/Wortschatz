// Learn mode answers: picking a multiple choice option, typing a written answer,
// "Weiss ich nicht?", the feedback after each (praise with auto-advance — or
// «N richtig in Folge!» at a streak milestone —, or the "Nicht ganz" screen with
// "Ich hatte recht", the optional copy step and, after a missed repetition
// question, "Wieder am Lernen") and the step to the next question. Works on the
// screen context `c` of learn.js.
//
// commitMc / commitWritten / overrideLast are the only places where an answer is
// decided (the show* functions are replayed after a reload, a dialog or an edit),
// so the answer streak and the answer sounds hang on them and never on a replay.

import { NOTE_LABELS, HINT_LABELS } from '../lib/labels.js';
import { speak } from '../lib/speech.js';
import { db } from '../store/db.js';
import * as L from '../core/learn.js';
import { toast } from '../ui/components.js';
import { hasText, gradeQuestion, copyAccepted } from './write-model.js';
import { pickPraise, DEMOTED_TEXT } from './learn-model.js';
import { markDemoted } from './learn-views.js';
import { streakTitle } from './answer-streak.js';

export const ADVANCE_MS = 900;
const ADVANCE_MS_WITH_NOTES = 1800; // time to read "Genau: …" after a tolerated answer
export const MISS_TITLE = 'Nicht ganz – das lernst du noch!';
// Short enough for one line on a 360 px phone, so the tiles below never move.
const DONT_KNOW_TITLE = 'Kein Problem – merk sie dir!';

export function createAnswering(c) {
  // The question on screen must be the state's current one before an answer counts.
  function isAnswerable(type) {
    if (c.stage !== 'question' || c.phase !== 'question' || !c.current || c.current.q.type !== type) return false;
    const head = L.current(c.state);
    if (head && head.qid === c.current.q.qid) return true;
    c.showQuestion({ animate: false });
    return false;
  }

  function record(q, correct) {
    const at = Date.now();
    c.write(() => db.recordAnswer(c.setId, q.cardId, correct, at));
    c.state = L.answer(c.state, correct, at);
  }

  // Audio option: read the target-language side once the answer is known.
  function speakAnswer(cardId) {
    if (!c.options.audio) return;
    const card = c.cards.get(cardId);
    if (card) speak(card.term, c.set.termLang);
  }

  function startAdvance(ms) {
    c.advanceTimer = setTimeout(() => continueNext(false), ms);
  }

  // A recorded answer: the streak counts it and its sound plays (a milestone gets the
  // fanfare, «Weiss ich nicht» stays quiet). Returns the praise a milestone replaces.
  function countAnswer(correct, dontKnow) {
    const streak = c.countAnswer(correct);
    c.sound({ answer: correct ? 'correct' : dontKnow ? 'dontKnow' : 'wrong', milestone: streak.milestone });
    return streak.milestone ? streakTitle(streak.current) : undefined;
  }

  // A miss on the question on screen was a repetition question: the mastered card
  // is learned again. (The engine already counts it; this is only what is shown.)
  const demotedNow = () => !!c.current && L.isReviewQuestion(c.current.q.qid);

  // ---------------------------------------------------- multiple choice
  function choose(index) {
    if (!c.current || !c.current.choices || !c.current.choices[index]) return;
    if (isAnswerable('mc')) commitMc(index);
  }

  function mcDontKnow() {
    if (isAnswerable('mc')) commitMc(null);
  }

  function commitMc(chosenIndex) {
    c.clearAdvance();
    const { q, info, choices } = c.current;
    const correctIndex = choices.findIndex((choice) => choice.cardId === q.cardId);
    const correct = chosenIndex != null && chosenIndex === correctIndex;
    record(q, correct);
    const milestone = countAnswer(correct, chosenIndex == null);
    c.pending = correct
      ? null
      : { qid: q.qid, cardId: q.cardId, type: 'mc', ask: q.ask, choices: q.choices, chosen: chosenIndex == null ? null : choices[chosenIndex].cardId };
    c.persist();
    c.last = { kind: 'mc', info, correctIndex, chosenIndex, praise: milestone };
    c.updateSide();
    speakAnswer(q.cardId);
    showMcResult();
  }

  // Also re-shows the feedback after a dialog or a reload (c.last is set).
  function showMcResult() {
    const { correctIndex, chosenIndex, info } = c.last;
    const correct = chosenIndex != null && chosenIndex === correctIndex;
    c.phase = correct ? 'correct' : 'incorrect';
    if (correct) {
      if (!c.last.praise) c.last.praise = c.lastPraise = pickPraise(c.lastPraise);
      c.mc.showResult({ correctIndex, chosenIndex, message: c.last.praise, autoAdvanceMs: ADVANCE_MS });
      c.announce(c.last.praise);
      c.lock();
      startAdvance(ADVANCE_MS);
      return;
    }
    const dontKnow = chosenIndex == null;
    const demoted = demotedNow();
    c.mc.showResult({ correctIndex, chosenIndex, message: dontKnow ? DONT_KNOW_TITLE : MISS_TITLE, demoted });
    c.announce(
      `${dontKnow ? 'Kein Problem.' : 'Nicht ganz.'} Richtige Antwort: `,
      { text: info.expected, lang: info.answerLang },
      demoted ? `. ${DEMOTED_TEXT}.` : '.',
    );
    c.lock();
  }

  // ------------------------------------------------------------ written
  function submitAnswer(value) {
    if (!isAnswerable('written')) return;
    const info = c.questionInfo(c.current.q) || c.current.info;
    if (!hasText(value)) {
      c.card.rejectEmpty();
      c.announce('Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht?».');
      return;
    }
    const { result, matchedCard } = gradeQuestion(c.set, info, value, c.options.tolerance);
    commitWritten(info, value.trim(), result, false, !!matchedCard);
  }

  function writtenDontKnow() {
    if (!isAnswerable('written')) return;
    commitWritten(c.questionInfo(c.current.q) || c.current.info, '', null, true);
  }

  // synonym: the answer belongs to another card with the same prompt.
  function commitWritten(info, given, result, isDontKnow, synonym = false) {
    c.clearAdvance();
    const q = c.current.q;
    const correct = !!(result && result.correct);
    record(q, correct);
    const milestone = countAnswer(correct, isDontKnow);
    c.pending = correct ? null : { qid: q.qid, cardId: q.cardId, type: 'written', ask: q.ask, given, dontKnow: isDontKnow };
    c.persist();
    c.last = { kind: 'written', info, given, result, dontKnow: isDontKnow, copy: false, editedCorrect: false, synonym, praise: milestone };
    c.updateSide();
    speakAnswer(q.cardId);
    if (correct) showWrittenCorrect();
    else showWrittenIncorrect();
  }

  function showWrittenCorrect() {
    c.phase = 'correct';
    const { result, synonym } = c.last;
    // "Genau!" right above a "Genau: …" correction would read oddly; a synonym
    // shows the word the card asked for.
    if (!c.last.praise) c.last.praise = synonym ? 'Auch richtig!' : result.exact ? (c.lastPraise = pickPraise(c.lastPraise)) : 'Richtig!';
    const praise = c.last.praise;
    const exactLabel = synonym ? 'Gesucht war:' : 'Genau:';
    const notes = (result.notes || [])
      .filter((n) => NOTE_LABELS[n])
      .map((n) => ({ label: NOTE_LABELS[n], tone: n === 'synonym' ? 'accent' : 'warning' }));
    const ms = result.exact ? ADVANCE_MS : ADVANCE_MS_WITH_NOTES;
    c.card.showCorrect({ praise, result, autoAdvanceMs: ms, notes, exactLabel });
    if (result.exact) c.announce(praise);
    else c.announce(`${praise} ${exactLabel} `, { text: result.expectedDisplay, lang: c.last.info.answerLang });
    c.lock();
    startAdvance(ms);
  }

  function showWrittenIncorrect() {
    c.phase = 'incorrect';
    const { info, given, result, dontKnow: isDontKnow, editedCorrect } = c.last;
    c.last.copy = c.retypeOn();
    const hintLabel = result && result.hint ? HINT_LABELS[result.hint] || null : null;
    c.card.showIncorrect({
      given,
      dontKnow: isDontKnow,
      hintLabel,
      copy: c.last.copy,
      canOverride: !isDontKnow && hasText(given),
      editedCorrect,
    });
    const demoted = demotedNow();
    if (demoted) markDemoted(c.card.el);
    const lead = isDontKnow ? 'Kein Problem.' : 'Nicht ganz.';
    const tail = c.last.copy ? ' Tippe die richtige Antwort ab.' : '';
    c.announce(
      `${lead} Richtige Antwort: `,
      { text: info.expected, lang: info.answerLang },
      `.${hintLabel ? ` ${hintLabel}.` : ''}${demoted ? ` ${DEMOTED_TEXT}.` : ''}${tail}`,
    );
    c.lock();
  }

  function submitCopy(value) {
    if (c.stage !== 'question' || c.phase !== 'incorrect' || !c.last || c.last.kind !== 'written') return;
    if (!c.last.copy) {
      continueNext(true);
      return;
    }
    const info = c.questionInfo(c.current.q) || c.last.info;
    if (copyAccepted(value, info, c.options.tolerance)) {
      continueNext(true);
    } else {
      c.card.rejectCopy();
      c.announce('Noch nicht ganz – tippe die richtige Antwort genau ab.');
    }
  }

  // "Ich hatte recht": the miss counts as correct (progress and session), and so the
  // streak it ended goes on.
  function overrideLast() {
    if (c.stage !== 'question' || c.phase !== 'incorrect' || !c.last || c.last.kind !== 'written' || c.last.dontKnow) return;
    c.clearAdvance();
    c.write(() => db.overrideLastAnswer(c.setId, c.last.info.cardId));
    c.state = L.override(c.state, Date.now());
    // The stored progress decides (it differs only if the card was answered elsewhere since).
    c.syncProgress();
    c.pending = null;
    c.persist();
    c.updateSide();
    const streak = c.countOverride();
    toast('Als richtig gezählt', { tone: 'success', duration: 2000 });
    continueNext(false);
    // A round or the session that ends with it sounds its own fanfare instead.
    if (c.stage === 'question') c.sound({ answer: 'correct', milestone: streak.milestone });
  }

  // fromUser: clicks/keys respect the short lock so one press never skips two steps
  // (after a correct answer it moves on when the lock ends instead, see learn.js).
  function continueNext(fromUser) {
    if (c.stage !== 'question' || c.phase === 'question') return;
    if (fromUser && c.locked()) {
      c.skipPraiseWhenUnlocked();
      return;
    }
    c.clearAdvance();
    if (c.pending) {
      // The miss is dealt with: a reload now continues after it.
      c.pending = null;
      c.persist();
    }
    // A step after an answer: the checkpoint or the finish that follows sounds.
    if (L.isRoundOver(c.state)) c.advance({ afterAnswer: true });
    else c.showQuestion();
  }

  return {
    choose,
    mcDontKnow,
    showMcResult,
    submitAnswer,
    writtenDontKnow,
    showWrittenCorrect,
    showWrittenIncorrect,
    submitCopy,
    overrideLast,
    continueNext,
  };
}
