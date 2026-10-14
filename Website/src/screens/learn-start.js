// Starts a Learn session over chosen cards from another screen: the exam's
// «Falsche lernen» (with repetition questions, so a card the exam found wrong is
// asked even when it still counts as mastered) and the set page's «Nur schwierige».
// It navigates to #/set/<id>/learn?new=1&cards=…[&review=1], but first asks before
// it ends a stored Learn session that already has answers (like set.js startSubset).

import { navigate as routerNavigate } from '../router.js';
import { db } from '../store/db.js';
import { confirmDialog } from '../ui/components.js';
import { learnCardsPath, learnSessionDetail, runningLearnSession } from './learn-model.js';

export const REPLACE_TITLE = 'Laufende Lerneinheit beenden?';
export const REPLACE_CONFIRM = 'Neu beginnen';

// The question to ask before a new session over `scope` (e.g. 'ausgewählten
// Begriffe', 'schwierigen Begriffe') replaces the stored one; null when nothing
// would be lost (no session, a finished one, or one without answers).
export function replaceLearnPrompt(saved, progress, scope = 'ausgewählten Begriffe') {
  const running = runningLearnSession(saved, progress);
  if (!running) return null;
  return {
    title: REPLACE_TITLE,
    message: `Deine gespeicherte Lerneinheit (${learnSessionDetail(running)}) endet, wenn du jetzt nur die ${scope} lernst. Dein Lernfortschritt bleibt erhalten.`,
    confirmLabel: REPLACE_CONFIRM,
  };
}

/**
 * Opens Learn with a session over `cardIds` of set `setId`; `review` also asks the
 * cards that are mastered already (repetition questions). Resolves to false when
 * the learner keeps the running session, true once it navigated.
 * navigate(path): the router's navigate (default); confirm(options) -> Promise<boolean>:
 * the dialog (default: a non-danger confirmDialog), replaceable in tests.
 */
export async function startLearnWithCards({
  setId,
  cardIds,
  review = false,
  navigate = routerNavigate,
  scope = 'ausgewählten Begriffe',
  confirm = (options) => confirmDialog({ ...options, danger: false }),
} = {}) {
  const path = learnCardsPath(setId, cardIds, { review: review === true });
  let prompt = null;
  try {
    prompt = replaceLearnPrompt(db.getLearn(setId), db.getProgress(setId), scope);
  } catch {
    prompt = null; // unreadable storage: the Learn screen starts fresh anyway (new=1)
  }
  if (prompt) {
    if (!(await confirm(prompt))) return false;
    try {
      // The ended session must not be offered again (Back, the set page).
      db.clearLearn(setId);
    } catch {
      // The new session replaces it anyway (new=1).
    }
  }
  navigate(path);
  return true;
}
