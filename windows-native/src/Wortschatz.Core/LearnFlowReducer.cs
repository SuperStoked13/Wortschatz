using System.Globalization;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of LearnFlowReducer.swift: the reducer behind LearnFlow.Start / LearnFlow.Reduce, a port of the
// screen logic of the web app's Learn mode (src/screens/learn.js, learn-answer.js, learn-dialogs.js,
// learn-keys.js). The methods carry the names of their JS (and Swift) counterparts. The Machine works on
// a Clone of the state; records in it are replaced (`with`), never mutated.

public static partial class LearnFlow
{
    /// <summary>One reduction: the state, the effects so far and the environment (the screen context c of the web app).</summary>
    sealed class Machine
    {
        readonly State s;
        readonly List<Effect> effects = [];
        /// <summary>A save was requested: one SaveLearn with the final state ends the effect list (it comes before a Navigate).</summary>
        bool wantsSave;
        /// <summary>Guards the (theoretical) loop "start fresh → nothing usable → start fresh".</summary>
        int freshStarts;
        readonly Env env;

        public Machine(State state, Env env)
        {
            s = state.Clone();
            this.env = env;
        }

        double Now => env.Now;

        public (State, List<Effect>) Result()
        {
            if (wantsSave && s.Session is { } session)
            {
                // Saved before leaving the screen.
                var save = new Effect.SaveLearn(session, s.Pending);
                int i = effects.FindIndex(e => e is Effect.Navigate);
                if (i >= 0) effects.Insert(i, save);
                else effects.Add(save);
            }
            return (s, effects);
        }

        void Emit(Effect effect) => effects.Add(effect);

        void Persist() => wantsSave = true;

        void Announce(string text) => Emit(new Effect.Announce(text));

        /// <summary>No prompt or overlay is open.</summary>
        bool IsFree => s.Prompt is null && s.Overlay is null;

        bool Locked => Now < s.InputLockedUntil;

        void Lock()
        {
            if (double.IsFinite(Now)) s.InputLockedUntil = Now + INPUT_LOCK_MS;
        }

        void ClearAdvance()
        {
            s.AutoAdvanceToken = null;
            s.AutoAdvancePaused = false;
        }

        void StartAdvance(int ms)
        {
            s.LastToken++;
            s.AutoAdvanceToken = s.LastToken;
            Emit(new Effect.ScheduleAutoAdvance(ms, s.LastToken));
        }

        /// <summary>
        /// A press to move on from a correct answer within the input lock moves on the moment the lock ends (the praise can
        /// always be skipped). Only for correct answers; a miss must stay readable for the whole lock.
        /// </summary>
        void SkipPraiseWhenUnlocked()
        {
            if (!IsFree || s.Phase != Phase.FeedbackOf(FeedbackKind.Correct) || !Locked) return;
            double lockedAt = s.InputLockedUntil - INPUT_LOCK_MS;
            if (Now - lockedAt < SKIP_MIN_GAP_MS) return;
            StartAdvance(Math.Max(1, (int)Math.Ceiling(s.InputLockedUntil - Now)));
        }

        void PauseAdvance()
        {
            if (s.AutoAdvanceToken is null) return;
            s.AutoAdvanceToken = null;
            s.AutoAdvancePaused = true;
        }

        // MARK: Events

        public void Handle(Event e)
        {
            switch (e)
            {
                case Event.Key k:
                    // Repeats never transition; only a held Backspace keeps deleting typed letters.
                    if (!IsFree || (k.IsRepeat && !k.Input.IsDeletion)) return;
                    HandleKey(k.Input);
                    break;
                case Event.Choose c:
                    if (IsFree) Choose(c.Index);
                    break;
                case Event.Highlight h:
                    if (!IsFree || s.Phase != Phase.Mc || s.Question is not { } q) return;
                    s.Highlighted = h.Index is { } i && i >= 0 && i < q.Choices.Count ? i : null;
                    break;
                case Event.DraftChanged d:
                    if (AcceptsText)
                    {
                        s.Draft = d.Text;
                        ContinueTypedOutCopy();
                    }
                    break;
                case Event.Submit sub:
                    if (!IsFree) return;
                    if (AcceptsText) s.Draft = sub.Text;
                    PrimaryAction(fromKey: true);
                    break;
                case Event.DontKnow:
                    if (IsFree) DontKnow();
                    break;
                case Event.Proceed:
                    if (IsFree) PrimaryAction(fromKey: false);
                    break;
                case Event.Override:
                    if (IsFree) OverrideLast();
                    break;
                case Event.SpeakPrompt:
                    if (s.Question is { } sq) Emit(new Effect.Speak(sq.Prompt, sq.PromptLang));
                    break;
                case Event.ToggleStar: ToggleStar(); break;
                case Event.EditCard edit: EditCard(edit.Card); break;
                case Event.OptionsChanged o: OptionsChanged(o.Options); break;
                case Event.ReviewChanged r:
                    s.Review = r.Review;
                    ApplySwitches(review: true);
                    break;
                case Event.RecheckChanged r:
                    s.Recheck = r.Recheck;
                    ApplySwitches(recheck: true);
                    break;
                case Event.StartReview:
                    if (IsFree && s.Phase == Phase.AllMastered) StartFresh(s.Subset, review: true);
                    break;
                case Event.SetChanged set:
                    s.SetTitle = set.Set.Title;
                    s.TermLang = set.Set.TermLang;
                    s.DefLang = set.Set.DefLang;
                    s.Cards = [.. set.Set.Cards];
                    Reconcile();
                    break;
                case Event.CardsChanged cards:
                    s.Cards = [.. cards.Cards];
                    Reconcile();
                    break;
                case Event.ProgressChanged: Reconcile(); break;
                case Event.OverlayPresented presented:
                    if (s.Overlay is null) PauseAdvance();
                    s.Overlay = presented.Overlay;
                    if (presented.Overlay == Overlay.Options && s.OptionsBeforeOverlay is null) s.OptionsBeforeOverlay = s.Options;
                    break;
                case Event.OverlayDismissed: OverlayDismissed(); break;
                case Event.PromptAnswered answered: PromptAnswered(answered.Confirmed); break;
                case Event.Restart:
                    if (IsFree) Restart();
                    break;
                case Event.Relearn:
                    if (IsFree) RequestRelearn();
                    break;
                case Event.StudyAll:
                    if (IsFree && s.Phase == Phase.Empty) StartFresh(StudySubset.All);
                    break;
                case Event.AutoAdvanceFired fired:
                    if (!IsFree || fired.Token != s.AutoAdvanceToken) return;
                    s.AutoAdvanceToken = null;
                    ContinueNext(fromUser: false);
                    break;
                case Event.Tick:
                    if (!s.IsStudying || s.Session is not { } ticking) return;
                    s.Session = LearnEngine.Tick(ticking, Now);
                    Persist();
                    break;
                case Event.Resume:
                    if (s.Session is not { FinishedAt: null } running || !double.IsFinite(Now)) return;
                    var resumed = LearnEngine.CopyState(running);
                    resumed.UpdatedAt = Now;
                    s.Session = resumed;
                    break;
                case Event.Exit: Leave(); break;
            }
        }

        /// <summary>The answer field (written question) or the copy field is on screen.</summary>
        bool AcceptsText => s.Phase == Phase.Written || s.Phase == Phase.Copy;

        void HandleKey(KeyInput key)
        {
            switch (key.Kind)
            {
                case KeyKind.Return: PrimaryAction(fromKey: true); break;
                case KeyKind.OptionReturn:
                    if (!Locked) DontKnow();
                    break;
                case KeyKind.CommandReturn:
                    if (!Locked) OverrideLast();
                    break;
                case KeyKind.Escape:
                    // Letters typed on a multiple-choice question go first.
                    if (s.Phase == Phase.Mc && s.Typed.Length > 0)
                    {
                        ClearTyped();
                        return;
                    }
                    Leave();
                    break;
                case KeyKind.Digit:
                {
                    int n = key.Digit;
                    if (s.Phase != Phase.Mc)
                    {
                        AnyKey(n.ToString(CultureInfo.InvariantCulture));
                        return;
                    }
                    if (Locked || s.Question is not { } q) return;
                    if (n == 0) DontKnow();
                    else if (n >= 1 && n <= q.Choices.Count) Choose(n - 1);
                    break;
                }
                case KeyKind.Arrow:
                    if (s.Phase == Phase.Mc) s.Typed = "";
                    MoveHighlight(key.Direction);
                    break;
                case KeyKind.Character:
                    if (s.Phase == Phase.Mc) TypeOnChoices(key.Text ?? "");
                    else AnyKey(key.Text ?? "");
                    break;
                case KeyKind.DeleteBackward: DeleteTyped(); break;
                case KeyKind.DeleteWordBackward: DeleteTyped(word: true); break;
            }
        }

        // MARK: Typing on multiple choice (learn-typeahead)

        /// <summary>
        /// A letter typed on a multiple-choice question: the one option the letters start is highlighted, so Enter
        /// chooses it (TypeAheadOf); typed out, it is chosen at once (TypeAhead.IsTypedOut). No input lock: typing is no
        /// transition.
        /// </summary>
        void TypeOnChoices(string text)
        {
            if (s.Question is not { } q) return;
            if (s.Typed.Length == 0 && Graphemes.AllWhitespace(text)) return;
            if (Graphemes.Count(s.Typed) + Graphemes.Count(text) > TYPE_AHEAD_MAX) return;
            s.Typed += text;
            UpdateTypeAhead(q);
            // Typed out: chosen like Return would (Anthony 23.11.2026, Windows since 23.11.2026).
            if (s.Highlighted is { } index && TypeAheadOf(s.Typed, q.Choices.Select(c => c.Text).ToList(), q.AnswerLang).IsTypedOut)
                Choose(index);
        }

        /// <summary>Backspace removes the last letter, Ctrl+Backspace the last word ("la voi" → "la ").</summary>
        void DeleteTyped(bool word = false)
        {
            if (s.Phase != Phase.Mc || s.Question is not { } q || s.Typed.Length == 0) return;
            if (word)
            {
                while (s.Typed.Length > 0 && Graphemes.LastIsWhitespace(s.Typed)) s.Typed = Graphemes.DropLast(s.Typed);
                while (s.Typed.Length > 0 && !Graphemes.LastIsWhitespace(s.Typed)) s.Typed = Graphemes.DropLast(s.Typed);
            }
            else s.Typed = Graphemes.DropLast(s.Typed);
            if (Graphemes.AllWhitespace(s.Typed)) s.Typed = "";
            UpdateTypeAhead(q);
        }

        void ClearTyped()
        {
            s.Typed = "";
            s.Highlighted = null;
            Announce(L("Eingabe gelöscht"));
        }

        void UpdateTypeAhead(QuestionInfo q)
        {
            var match = TypeAheadOf(s.Typed, q.Choices.Select(c => c.Text).ToList(), q.AnswerLang);
            var previous = s.Highlighted;
            s.Highlighted = match.Selected;
            if (match.Selected is { } index && index != previous)
                Announce(L($"Antwort {index + 1}: {q.Choices[index].Text}. Eingabetaste wählt sie."));
        }

        /// <summary>
        /// After multiple-choice feedback any key continues (without picking anything in the next question); after a
        /// correct written answer any key continues and, unless it is a space, starts the next written answer.
        /// </summary>
        void AnyKey(string text)
        {
            if (!s.Phase.IsFeedback || s.Question is not { } q) return;
            if (q.Type == QuestionType.Mc)
            {
                if (Locked)
                {
                    SkipPraiseWhenUnlocked();
                    return;
                }
                ContinueNext(fromUser: false);
                return;
            }
            if (s.Phase.FeedbackKind != FeedbackKind.Correct) return;
            ContinueNext(fromUser: false);
            if (s.Phase == Phase.Written && text != " ") s.Draft = text;
        }

        /// <summary>Enter / the primary button.</summary>
        void PrimaryAction(bool fromKey)
        {
            if (fromKey && Locked)
            {
                SkipPraiseWhenUnlocked();
                return;
            }
            switch (s.Phase.Kind)
            {
                case PhaseKind.Question when s.Phase.QuestionType == QuestionType.Mc:
                    if (s.Highlighted is { } index) Choose(index);
                    else if (s.Typed.Length > 0 && s.Question is { } q)
                    {
                        // Typed letters that pick no option yet: Enter cannot guess.
                        s.Rejections++;
                        Announce(L($"Keine eindeutige Antwort – tippe weiter oder wähle mit 1 bis {q.Choices.Count}."));
                    }
                    break;
                case PhaseKind.Question: SubmitAnswer(s.Draft); break;
                case PhaseKind.Feedback: ContinueNext(fromUser: true); break;
                case PhaseKind.Copy: SubmitCopy(s.Draft); break;
                case PhaseKind.Checkpoint: GoNextRound(fromUser: true); break;
                case PhaseKind.Finished: Emit(new Effect.Navigate(Destination.Set)); break;
                case PhaseKind.AllMastered: RequestRelearn(); break;
                case PhaseKind.Empty:
                    if (s.Subset.Equals(StudySubset.All)) Emit(new Effect.Navigate(Destination.EditSet));
                    else StartFresh(StudySubset.All);
                    break;
            }
        }

        /// <summary>Arrow keys on a 2-column grid; the first press lands on option 1.</summary>
        void MoveHighlight(Direction direction)
        {
            if (s.Phase != Phase.Mc || s.Question is not { } q || q.Choices.Count == 0) return;
            int count = q.Choices.Count;
            int next = 0;
            if (s.Highlighted is { } h)
            {
                next = h;
                switch (direction)
                {
                    case Direction.Left: if (h % 2 == 1) next = h - 1; break;
                    case Direction.Right: if (h % 2 == 0 && h + 1 < count) next = h + 1; break;
                    case Direction.Up: if (h >= 2) next = h - 2; break;
                    case Direction.Down:
                        if (h + 2 < count) next = h + 2;
                        else if (h / 2 < (count - 1) / 2) next = count - 1;
                        break;
                }
            }
            if (next == s.Highlighted) return;
            s.Highlighted = next;
            Announce(L($"Antwort {next + 1}: {q.Choices[next].Text}"));
        }

        // MARK: Session lifecycle (learn.js)

        public void Boot(SavedLearn? saved, StudySubset? wanted, bool forceNew)
        {
            // A stored session with the answers given elsewhere since.
            var stored = saved?.State;
            bool synced = false;
            if (stored is not null && !LearnEngine.MatchesProgress(stored, env.Progress))
            {
                stored = LearnEngine.SyncProgress(stored, env.Progress, Now);
                synced = true;
            }
            // The rechecks follow «Nachkontrolle nach Fehlern» as it is now (switched since the session started). The
            // repetition questions stay: a session may have been started for them («Alle wiederholen», the exam's «Falsche lernen»).
            if (stored is not null)
            {
                var switched = LearnEngine.SetRecheck(stored, s.Recheck, Now);
                if (!ReferenceEquals(switched, stored))
                {
                    stored = switched;
                    synced = true;
                }
            }
            if (stored is null || !CanResumeLearn(stored, forceNew, wanted))
            {
                // A requested subset must not end a session with answers without asking.
                if (wanted is not null && !forceNew && stored is not null && CanResumeLearn(stored) && HasLearnAnswers(stored))
                {
                    if (ResumeSaved(stored, saved?.Feedback, null, synced, welcome: false))
                    {
                        PauseAdvance();
                        s.Prompt = new Prompt.ReplaceSession(wanted);
                    }
                    return;
                }
                // Finished by answers given elsewhere or the switched Nachkontrolle: stored as finished, so «Weiterlernen»
                // no longer offers it (when nothing new starts here).
                if (synced && stored is { FinishedAt: not null }) Emit(new Effect.SaveLearn(stored, null));
                StartFresh(wanted ?? StudySubset.All);
                return;
            }
            // Options that shape a session were changed elsewhere since it started (Einstellungen, the set's options): a
            // session without answers simply starts again with them (issue #7); one with answers asks.
            if (!HasLearnAnswers(stored) && SettingsChanges(SessionSettingsOf(stored), CurrentSettingsOf(s.Options, stored)).Count > 0)
            {
                StartFresh(wanted ?? stored.Subset, review: stored.Review is not null || s.Review);
                return;
            }
            if (ResumeSaved(stored, saved?.Feedback, wanted, synced, welcome: true)) AskForChangedOptions();
        }

        /// <summary>
        /// Options that shape the session (direction, question types, round size) were changed outside it since it started
        /// (Einstellungen, the set's options, another device): «Neu starten?» as after the options (issue #7, 24.11.2026,
        /// Windows; before, the session went on with the old ones for days, and nothing said so). After «Später»
        /// (KeepChangedOptions) it is not asked again while the options stay so.
        /// </summary>
        void AskForChangedOptions()
        {
            if (!IsFree || s.Session is not { FinishedAt: null } session) return;
            var current = CurrentSettingsOf(s.Options, session);
            var changes = SettingsChanges(SessionSettingsOf(session), current);
            if (changes.Count == 0 || s.Kept?.Covers(session.StartedAt, KeptSettingsJson(current)) == true) return;
            PauseAdvance();
            s.Prompt = new Prompt.RestartForOptions(changes);
        }

        /// <summary>«Später» on «Neu starten?»: the session keeps its settings while the options are as now (stored on this device).</summary>
        void KeepChangedOptions()
        {
            if (s.Session is not { FinishedAt: null } session) return;
            var kept = new KeptOptions(session.StartedAt, KeptSettingsJson(CurrentSettingsOf(s.Options, session)));
            s.Kept = kept;
            Emit(new Effect.KeepOptions(kept));
        }

        /// <summary>Resumes a stored session; false when it had to start a new one instead.</summary>
        bool ResumeSaved(LearnState saved, JSONValue? feedback, StudySubset? wanted, bool synced, bool welcome)
        {
            var state = LearnEngine.CopyState(saved);
            // Time away from the screen is not study time.
            if (double.IsFinite(Now) && state.FinishedAt is null) state.UpdatedAt = Now;
            s.Session = state;
            s.Subset = state.Subset;
            bool pruned = PruneState();
            bool changed = SyncProgress(env.Progress) || synced || pruned;
            s.Pending = PendingFeedbackOf(s.Session!, feedback);
            s.RoundStartCounts = null;
            if (changed) Persist();
            if (s.Session is null || s.Session.Order.Count == 0)
            {
                StartFresh(wanted ?? StudySubset.All);
                return false;
            }
            if (welcome && HasLearnAnswers(s.Session)) Emit(new Effect.Toast(WELCOME_BACK, Tone.Neutral));
            if (s.Pending is not null) ReopenFeedback();
            else Advance();
            return true;
        }

        /// <summary>A new session over subset (progress: by default the env's; review: by default as State.Review says).</summary>
        void StartFresh(StudySubset subset, IReadOnlyDictionary<string, CardProgress>? progress = null, bool? review = null)
        {
            ClearAdvance();
            s.Feedback = null;
            s.Pending = null;
            s.Question = null;
            s.Highlighted = null;
            s.Draft = "";
            freshStarts++;
            var fresh = LearnEngine.CreateLearn(s.Cards, s.Options, subset, progress ?? env.Progress, env.Rng, Now, review ?? s.Review, s.Recheck);
            s.Subset = fresh.Subset;
            if (fresh.Order.Count == 0 || LearnEngine.IsFinished(fresh))
            {
                // Nothing to study.
                s.Session = null;
                if (fresh.Order.Count == 0) ShowEmpty(fresh.Subset);
                else ShowAllMastered(fresh);
                return;
            }
            s.Session = fresh;
            s.RoundStartCounts = LearnEngine.CountsOf(fresh);
            Persist();
            ShowQuestion();
        }

        /// <summary>Drops cards that were deleted (or emptied) since the session started; their options in other questions are replaced.</summary>
        bool PruneState()
        {
            if (s.Session is not { } session) return false;
            var byId = CardsById(s.Cards);
            bool changed = false;
            foreach (var id in session.Order.ToList())
            {
                if (IsUsable(byId.GetValueOrDefault(id))) continue;
                session = LearnEngine.RemoveCard(session, id, Now, s.Cards, env.Rng);
                changed = true;
            }
            s.Session = session;
            return changed;
        }

        /// <summary>Learn and Write share one progress model: answers given elsewhere move a card's stage here too. Returns whether the session changed.</summary>
        bool SyncProgress(IReadOnlyDictionary<string, CardProgress> progress)
        {
            if (s.Session is not { } session || LearnEngine.MatchesProgress(session, progress)) return false;
            s.Session = LearnEngine.SyncProgress(session, progress, Now);
            return true;
        }

        /// <summary>The next step after a question, a round or a resume.</summary>
        void Advance()
        {
            if (s.Session is not { } session || session.Order.Count == 0)
            {
                SessionEmptied();
                return;
            }
            if (LearnEngine.IsFinished(session)) Finish();
            else if (LearnEngine.IsRoundOver(session)) ShowCheckpoint();
            else ShowQuestion();
        }

        /// <summary>Every card of the session vanished (deleted elsewhere).</summary>
        void SessionEmptied()
        {
            var current = s.Session?.Subset ?? StudySubset.All;
            var subset = current.Kind == StudySubsetKind.CardIds ? StudySubset.All : current;
            if (s.Cards.Any(c => IsUsable(c)) && freshStarts < 2) StartFresh(subset);
            else
            {
                s.Session = null;
                Emit(new Effect.ClearLearn());
                ShowEmpty(StudySubset.All);
            }
        }

        // MARK: Questions

        QuestionInfo? InfoFor(LearnEngine.Question q) =>
            CardsById(s.Cards).TryGetValue(q.CardId, out var card) ? QuestionInfoOf(q, card, s.Cards, s.TermLang, s.DefLang) : null;

        /// <summary>info with the current texts of its card (the stored one when the card is gone).</summary>
        QuestionInfo RefreshedInfo(QuestionInfo info) =>
            InfoFor(new LearnEngine.Question(info.Qid, info.CardId, info.Type, info.Ask, info.Type == QuestionType.Mc ? info.StoredChoices : null)) ?? info;

        void ShowQuestion()
        {
            ClearAdvance();
            if (s.Session is not { } session)
            {
                Advance();
                return;
            }
            var q = LearnEngine.Current(session);
            bool pruned = false;
            var byId = CardsById(s.Cards);
            while (q is not null && !IsUsable(byId.GetValueOrDefault(q.CardId)))
            {
                session = LearnEngine.RemoveCard(session, q.CardId, Now, s.Cards, env.Rng);
                pruned = true;
                q = LearnEngine.Current(session);
            }
            s.Session = session;
            if (pruned) Persist();
            if (q is null)
            {
                Advance();
                return;
            }
            // Never null: a usable card exists.
            if (InfoFor(q) is not { } info) return;
            s.Phase = Phase.QuestionOf(q.Type);
            s.Question = info;
            s.Feedback = null;
            s.Highlighted = null;
            s.Typed = "";
            s.Draft = "";
            s.Transitions++;
            var lead = info.IsReview ? $"{REVIEW_LABEL}. " : "";
            if (q.Type == QuestionType.Mc)
            {
                var pick = L($"Wähle die richtige Antwort, 1 bis {info.Choices.Count}.");
                Announce($"{lead}{info.PromptLabel}: {info.Prompt}. {pick}");
            }
            else
                Announce($"{lead}{info.PromptLabel}: {info.Prompt}" + (session.AnswerWith == AnswerWith.Both ? $". {info.Placeholder}." : ""));
            Lock();
            if (s.Options.Audio && info.Ask == AskSide.Definition) Emit(new Effect.Speak(info.Prompt, info.PromptLang));
        }

        // MARK: Answering (learn-answer.js)

        /// <summary>The question on screen must be the session's current one before an answer counts.</summary>
        bool IsAnswerable(QuestionType type)
        {
            if (!s.Phase.IsQuestion || s.Phase.QuestionType != type || s.Question is not { } info || s.Session is not { } session) return false;
            if (LearnEngine.Current(session)?.Qid == info.Qid) return true;
            ShowQuestion();
            return false;
        }

        void Record(QuestionInfo info, bool correct)
        {
            if (s.Session is not { } session) return;
            Emit(new Effect.RecordAnswer(info.CardId, correct, Now));
            s.Session = LearnEngine.Answer(session, correct, Now);
        }

        /// <summary>Audio option: read the target-language side once the answer is known.</summary>
        void SpeakAnswer(string cardId)
        {
            if (!s.Options.Audio || !CardsById(s.Cards).TryGetValue(cardId, out var card)) return;
            Emit(new Effect.Speak(card.Term, s.TermLang));
        }

        void Choose(int index)
        {
            if (s.Question is not { } q || index < 0 || index >= q.Choices.Count) return;
            if (IsAnswerable(QuestionType.Mc)) CommitMc(index);
        }

        void DontKnow()
        {
            if (s.Phase == Phase.Mc)
            {
                if (IsAnswerable(QuestionType.Mc)) CommitMc(null);
            }
            else if (s.Phase == Phase.Written)
            {
                if (IsAnswerable(QuestionType.Written) && s.Question is { } info) CommitWritten(info, "", null, dontKnow: true, synonym: false);
            }
        }

        void CommitMc(int? chosenIndex)
        {
            if (s.Question is not { } info) return;
            ClearAdvance();
            int ci = info.Choices.ToList().FindIndex(c => c.CardId == info.CardId);
            int? correctIndex = ci >= 0 ? ci : null;
            bool correct = chosenIndex is not null && chosenIndex == correctIndex;
            Record(info, correct);
            s.Pending = correct ? null : PendingFeedback.Mc(info.Qid, info.CardId, info.Ask, info.StoredChoices, chosenIndex is { } c2 ? info.Choices[c2].CardId : null);
            Persist();
            s.Feedback = new Feedback(correct ? FeedbackKind.Correct : chosenIndex is null ? FeedbackKind.DontKnow : FeedbackKind.Wrong,
                CorrectIndex: correctIndex, ChosenIndex: chosenIndex, Demoted: info.IsReview && !correct);
            s.Highlighted = null;
            s.Typed = "";
            SpeakAnswer(info.CardId);
            ShowMcResult(Presentation.Answer);
        }

        enum Presentation { Answer, Resume, Refresh }

        /// <summary>The feedback of a multiple-choice answer (also after a relaunch).</summary>
        void ShowMcResult(Presentation how)
        {
            if (s.Feedback is not { } f || s.Question is not { } info) return;
            s.Phase = Phase.FeedbackOf(f.Kind);
            if (how != Presentation.Refresh) s.Transitions++;
            if (f.Kind == FeedbackKind.Correct)
            {
                if (f.Title.Length == 0)
                {
                    f = f with { Title = PickPraise(s.LastPraise, env.Rng) };
                    s.LastPraise = f.Title;
                }
                f = f with { AutoAdvanceMs = ADVANCE_MS };
                s.Feedback = f;
                Announce(f.Title);
                if (how == Presentation.Answer) Emit(new Effect.Haptic(HapticKind.Success));
                Lock();
                StartAdvance(ADVANCE_MS);
                return;
            }
            f = f with { Title = f.Kind == FeedbackKind.DontKnow ? DONT_KNOW_TITLE : MISS_TITLE };
            s.Feedback = f;
            var demoted = f.Demoted ? $" {DEMOTED_TEXT}." : "";
            var lead = f.Kind == FeedbackKind.DontKnow ? L("Kein Problem.") : L("Nicht ganz.");
            var answer = L($"Richtige Antwort: {info.Expected}.");
            Announce($"{lead} {answer}{demoted}");
            if (how == Presentation.Answer && f.Kind == FeedbackKind.Wrong) Emit(new Effect.Haptic(HapticKind.Failure));
            Lock();
        }

        void SubmitAnswer(string value)
        {
            if (!IsAnswerable(QuestionType.Written) || s.Question is not { } shown) return;
            var info = RefreshedInfo(shown);
            if (!HasText(value))
            {
                s.Rejections++;
                Announce(L("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht?»."));
                return;
            }
            var graded = GradeQuestion(info, value, s.Cards, s.Options.Tolerance, env.ExtraAnswers(info.SynonymQuery));
            CommitWritten(info, JSCompat.Trim(value), graded.Result, dontKnow: false, synonym: graded.IsSynonym);
        }

        void CommitWritten(QuestionInfo info, string given, GradeResult? result, bool dontKnow, bool synonym)
        {
            ClearAdvance();
            bool correct = result?.Correct == true;
            Record(info, correct);
            s.Pending = correct ? null : PendingFeedback.Written(info.Qid, info.CardId, info.Ask, given, dontKnow);
            Persist();
            s.Question = info;
            s.Feedback = new Feedback(correct ? FeedbackKind.Correct : dontKnow ? FeedbackKind.DontKnow : FeedbackKind.Wrong, Given: given, Result: result,
                Synonym: synonym, Demoted: info.IsReview && !correct);
            SpeakAnswer(info.CardId);
            if (correct) ShowWrittenCorrect();
            else ShowWrittenIncorrect(Presentation.Answer);
        }

        void ShowWrittenCorrect()
        {
            if (s.Feedback is not { } f || f.Result is not { } result) return;
            s.Phase = Phase.FeedbackOf(FeedbackKind.Correct);
            s.Transitions++;
            // "Genau!" right above a "Genau: …" correction would read oddly; a synonym shows the word the card asked for.
            if (f.Title.Length == 0)
            {
                if (f.Synonym) f = f with { Title = SYNONYM_TITLE };
                else if (result.Exact)
                {
                    f = f with { Title = PickPraise(s.LastPraise, env.Rng) };
                    s.LastPraise = f.Title;
                }
                else f = f with { Title = TOLERATED_TITLE };
            }
            var exactLabel = f.Synonym ? L("Gesucht war:") : L("Genau:");
            int ms = result.Exact ? ADVANCE_MS : ADVANCE_MS_WITH_NOTES;
            f = f with { ExactLabel = result.Exact ? null : exactLabel, AutoAdvanceMs = ms };
            s.Feedback = f;
            Announce(result.Exact ? f.Title : $"{f.Title} {exactLabel} {result.ExpectedDisplay}");
            Emit(new Effect.Haptic(HapticKind.Success));
            Lock();
            StartAdvance(ms);
        }

        void ShowWrittenIncorrect(Presentation how)
        {
            if (s.Feedback is not { } f || s.Question is not { } info) return;
            bool dontKnow = f.Kind == FeedbackKind.DontKnow;
            f = f with
            {
                Copy = s.Options.Learn.Retype,
                Hint = f.Result?.Hint is { } h ? Labels.HINT_LABELS.GetValueOrDefault(h) : null,
                CanOverride = !dontKnow && HasText(f.Given),
                Title = dontKnow ? DONT_KNOW_TITLE : MISS_TITLE,
            };
            s.Feedback = f;
            var phase = f.Copy ? Phase.Copy : Phase.FeedbackOf(f.Kind);
            if (phase != s.Phase) s.Draft = "";
            s.Phase = phase;
            if (how != Presentation.Refresh) s.Transitions++;
            var lead = dontKnow ? L("Kein Problem.") : L("Nicht ganz.");
            var answer = L($"Richtige Antwort: {info.Expected}.");
            var hint = f.Hint is { } hl ? $" {hl}." : "";
            var demoted = f.Demoted ? $" {DEMOTED_TEXT}." : "";
            var tail = f.Copy ? " " + L("Tippe die richtige Antwort ab.") : "";
            Announce($"{lead} {answer}{hint}{demoted}{tail}");
            if (how == Presentation.Answer && !dontKnow) Emit(new Effect.Haptic(HapticKind.Failure));
            Lock();
        }

        /// <summary>
        /// The copy typed out continues by itself after a short beat, like Return (CopyStep); typing on so that it no
        /// longer is stops the countdown.
        /// </summary>
        void ContinueTypedOutCopy()
        {
            if (!IsFree || s.Phase != Phase.Copy || s.Question is not { } shown) return;
            var info = RefreshedInfo(shown);
            if (!CopyStep.IsTypedOut(s.Draft, info.Expected, s.Options.Tolerance, info.AnswerLang))
            {
                ClearAdvance();
                return;
            }
            if (s.AutoAdvanceToken is null) StartAdvance(CopyStep.AdvanceMs);
        }

        void SubmitCopy(string value)
        {
            if (s.Phase != Phase.Copy || s.Question is not { } shown) return;
            var info = RefreshedInfo(shown);
            if (CopyAccepted(value, info, s.Options.Tolerance)) ContinueNext(fromUser: true);
            else
            {
                s.Rejections++;
                Announce(L("Noch nicht ganz – tippe die richtige Antwort genau ab."));
            }
        }

        /// <summary>"Ich hatte recht": the written miss counts as correct (progress and session).</summary>
        void OverrideLast()
        {
            if (s.Question is not { Type: QuestionType.Written } q || s.Feedback is not { Kind: FeedbackKind.Wrong } || s.Session is not { } session) return;
            if (!(s.Phase == Phase.FeedbackOf(FeedbackKind.Wrong) || s.Phase == Phase.Copy)) return;
            var cardId = q.CardId;
            ClearAdvance();
            Emit(new Effect.OverrideLastAnswer(cardId));
            s.Session = LearnEngine.Override(session, Now);
            // The stored progress decides (it differs only if the card was answered elsewhere since).
            var progress = new Dictionary<string, CardProgress>(env.Progress, StringComparer.Ordinal);
            if (progress.TryGetValue(cardId, out var prev) && prev.LastResult == AnswerResult.Incorrect) progress[cardId] = Mastery.ApplyOverride(prev);
            SyncProgress(progress);
            s.Pending = null;
            Persist();
            Emit(new Effect.Toast(L("Als richtig gezählt"), Tone.Success));
            ContinueNext(fromUser: false);
        }

        /// <summary>The next question (or checkpoint/finish) after feedback. fromUser: clicks and keys respect the input lock.</summary>
        void ContinueNext(bool fromUser)
        {
            if (!(s.Phase.IsFeedback || s.Phase == Phase.Copy)) return;
            if (fromUser && Locked)
            {
                SkipPraiseWhenUnlocked();
                return;
            }
            ClearAdvance();
            if (s.Pending is not null)
            {
                // The miss is dealt with: a relaunch now continues after it.
                s.Pending = null;
                Persist();
            }
            if (s.Session is { } session && LearnEngine.IsRoundOver(session)) Advance();
            else ShowQuestion();
        }

        /// <summary>The "Nicht ganz" screen that was open when the session was left; the answer itself is already recorded.</summary>
        void ReopenFeedback()
        {
            if (s.Pending is not { } p) return;
            var q = new LearnEngine.Question(p.Qid, p.CardId, p.Type, p.Ask, p.Type == QuestionType.Mc ? p.Choices : null);
            if (InfoFor(q) is not { } info)
            {
                s.Pending = null;
                Persist();
                Advance();
                return;
            }
            s.Question = info;
            s.Highlighted = null;
            s.Typed = "";
            s.Draft = "";
            if (p.Type == QuestionType.Mc)
            {
                var choices = info.Choices.ToList();
                int? chosenIndex = p.Chosen is { } chosen && choices.FindIndex(c => c.CardId == chosen) is var i and >= 0 ? i : null;
                int ci = choices.FindIndex(c => c.CardId == p.CardId);
                s.Feedback = new Feedback(chosenIndex is null ? FeedbackKind.DontKnow : FeedbackKind.Wrong, CorrectIndex: ci >= 0 ? ci : null,
                    ChosenIndex: chosenIndex, Demoted: info.IsReview);
                ShowMcResult(Presentation.Resume);
            }
            else
            {
                var given = p.Given ?? "";
                bool dontKnow = p.DontKnow == true;
                var result = dontKnow ? null : GradeQuestion(info, given, s.Cards, s.Options.Tolerance).Result;
                s.Feedback = new Feedback(dontKnow ? FeedbackKind.DontKnow : FeedbackKind.Wrong, Given: given, Result: result, Demoted: info.IsReview);
                ShowWrittenIncorrect(Presentation.Resume);
            }
        }

        // MARK: Checkpoint and finish

        void ShowCheckpoint(bool refresh = false)
        {
            ClearAdvance();
            if (s.Session is not { } session) return;
            var cp = LearnEngine.CheckpointOf(session);
            if (cp.Answered == 0)
            {
                // Nothing was answered this round (its cards were removed): refill without a checkpoint.
                session = LearnEngine.NextRound(session, s.Cards, env.Rng, Now);
                s.Session = session;
                s.RoundStartCounts = LearnEngine.CountsOf(session);
                Persist();
                if (LearnEngine.IsFinished(session)) Finish();
                else if (LearnEngine.IsRoundOver(session)) SessionEmptied();
                else ShowQuestion();
                return;
            }
            s.Phase = Phase.Checkpoint;
            s.Question = null;
            s.Feedback = null;
            s.Highlighted = null;
            s.Draft = "";
            if (refresh) return;
            s.Transitions++;
            Announce(L($"Runde {cp.Round} geschafft. {cp.Counts.Mastered} von {cp.Counts.Total} gemeistert."));
            Lock();
        }

        void GoNextRound(bool fromUser)
        {
            if (s.Phase != Phase.Checkpoint || s.Session is not { } session || (fromUser && Locked)) return;
            var next = LearnEngine.NextRound(session, s.Cards, env.Rng, Now);
            s.Session = next;
            s.RoundStartCounts = LearnEngine.CountsOf(next);
            Persist();
            Advance();
        }

        void Finish()
        {
            ClearAdvance();
            if (s.Session is not { } session) return;
            // Closes the last round into the history and stamps finishedAt.
            s.Session = LearnEngine.NextRound(session, s.Cards, env.Rng, Now);
            s.Pending = null;
            Persist();
            ShowFinish();
        }

        void ShowFinish(bool refresh = false)
        {
            if (s.Session is not { } session) return;
            var stats = LearnEngine.FinalStatsOf(session);
            if (stats.Total <= 0)
            {
                SessionEmptied();
                return;
            }
            s.Phase = Phase.Finished;
            s.Question = null;
            s.Feedback = null;
            s.Highlighted = null;
            s.Draft = "";
            if (refresh) return;
            s.Transitions++;
            Announce(L($"Geschafft! {FinishTitle(session.Subset, stats.Total)}"));
            Emit(new Effect.Haptic(HapticKind.Success));
            Lock();
        }

        void ShowMessage(Phase phase)
        {
            ClearAdvance();
            s.Phase = phase;
            s.Question = null;
            s.Feedback = null;
            s.Highlighted = null;
            s.Draft = "";
            s.Pending = null;
            s.Transitions++;
            Lock();
        }

        void ShowEmpty(StudySubset subset)
        {
            s.Subset = subset;
            s.ScopeCardIds = [];
            ShowMessage(Phase.Empty);
        }

        /// <summary>Everything in scope is already mastered at the start.</summary>
        void ShowAllMastered(LearnState fresh)
        {
            s.Subset = fresh.Subset;
            s.ScopeCardIds = [.. fresh.Order];
            ShowMessage(Phase.AllMastered);
        }

        void Leave()
        {
            // Leaving: the time studied until now is kept.
            if (s.IsStudying && s.Session is { } session)
            {
                s.Session = LearnEngine.Tick(session, Now);
                Persist();
            }
            ClearAdvance();
            Emit(new Effect.Navigate(Destination.Set));
        }

        // MARK: Live updates

        /// <summary>The set or the progress changed elsewhere.</summary>
        void Reconcile()
        {
            if (s.Session is null)
            {
                RefreshMessage();
                return;
            }
            bool pruned = PruneState();
            // Answers given elsewhere (e.g. in Write mode) move the stages here too.
            bool synced = SyncProgress(env.Progress);
            if (pruned || synced) Persist();
            switch (s.Phase.Kind)
            {
                case PhaseKind.Question or PhaseKind.Feedback or PhaseKind.Copy:
                {
                    if (s.Question is not { } shown || s.Session is not { } current) return;
                    var head = LearnEngine.Current(current);
                    bool same = head?.Qid == shown.Qid && head?.Type == shown.Type
                        && (head?.Choices ?? []).SequenceEqual(shown.Type == QuestionType.Mc ? shown.StoredChoices : []);
                    if (s.Phase.IsQuestion && !same) ShowQuestion();
                    else if (CardsById(s.Cards).ContainsKey(shown.CardId)) RefreshCurrent(regrade: false);
                    break;
                }
                case PhaseKind.Checkpoint:
                {
                    if (!(pruned || synced) || s.Session is not { } current) return;
                    if (current.Order.Count > 0 && !LearnEngine.IsFinished(current) && LearnEngine.CheckpointOf(current).Answered > 0) ShowCheckpoint(refresh: true);
                    else Advance();
                    break;
                }
                case PhaseKind.Finished:
                    if (pruned) ShowFinish(refresh: true);
                    break;
            }
        }

        /// <summary>The message screens follow the set: the scope's cards of an "everything mastered" screen that were deleted drop out.</summary>
        void RefreshMessage()
        {
            if (s.Phase != Phase.AllMastered) return;
            var byId = CardsById(s.Cards);
            s.ScopeCardIds = s.ScopeCardIds.Where(id => IsUsable(byId.GetValueOrDefault(id))).ToList();
        }

        /// <summary>Shows the current texts of the question on screen (after an edit here or elsewhere).</summary>
        void RefreshCurrent(bool regrade)
        {
            if (s.Question is not { } shown || !CardsById(s.Cards).ContainsKey(shown.CardId)) return;
            var info = RefreshedInfo(shown);
            s.Question = info;
            if (s.Highlighted is { } h && (h < 0 || h >= info.Choices.Count)) s.Highlighted = null;
            if (s.Phase == Phase.Mc && s.Typed.Length > 0) UpdateTypeAhead(info);
            if (!regrade || info.Type != QuestionType.Written || s.Feedback is not { } f || f.Kind == FeedbackKind.Correct) return;
            if (!(s.Phase.IsFeedback || s.Phase == Phase.Copy)) return;
            // If the corrected card now accepts what was typed, offer to count it.
            var r = f.Kind == FeedbackKind.Wrong && HasText(f.Given) ? GradeQuestion(info, f.Given, s.Cards, s.Options.Tolerance).Result : null;
            s.Feedback = f with { EditedCorrect = r?.Correct == true };
            ShowWrittenIncorrect(Presentation.Refresh);
        }

        // MARK: Dialogs and card actions (learn-dialogs.js)

        void ToggleStar()
        {
            if (!s.IsStudyStep || s.Question is not { } q) return;
            int i = s.Cards.FindIndex(c => c.Id == q.CardId);
            if (i < 0) return;
            s.Cards[i] = s.Cards[i] with { Starred = !s.Cards[i].Starred };
            s.Question = q with { Starred = s.Cards[i].Starred };
            Emit(new Effect.ToggleStar(q.CardId));
        }

        void EditCard(Card card)
        {
            int i = s.Cards.FindIndex(c => c.Id == card.Id);
            if (i < 0) return;
            Emit(new Effect.UpdateCard(card));
            s.Cards[i] = card;
            if (s.IsStudyStep) RefreshCurrent(regrade: true);
            Emit(new Effect.Toast(L("Karte gespeichert"), Tone.Success));
        }

        void OptionsChanged(StudyOptions options)
        {
            var before = s.Options;
            s.Options = options;
            // The copy step applies at once to an open written miss.
            if (before.Learn.Retype != options.Learn.Retype && s.Question?.Type == QuestionType.Written && s.Feedback is { Kind: not FeedbackKind.Correct }
                && (s.Phase.IsFeedback || s.Phase == Phase.Copy))
                ShowWrittenIncorrect(Presentation.Refresh);
            // Changed outside while the session is on screen (imported from another device): asks at once. Changes in the
            // options ask when they close (OverlayDismissed).
            if (s.Overlay is null && SessionSettingsOf(before) != SessionSettingsOf(options)) AskForChangedOptions();
        }

        void OverlayDismissed()
        {
            if (s.Overlay is null) return;
            var before = s.OptionsBeforeOverlay;
            s.Overlay = null;
            s.OptionsBeforeOverlay = null;
            // Direction, question types and round size shape the session: they need a restart (the repetition questions
            // and the rechecks applied when they were switched).
            if (before is not null && s.Session is { FinishedAt: null } session)
            {
                bool review = session.Review is not null, recheck = session.Recheck is not null;
                var current = SessionSettingsOf(s.Options, review, recheck);
                var changes = SettingsChanges(SessionSettingsOf(session), current);
                if (SettingsChanges(SessionSettingsOf(before, review, recheck), current).Count > 0 && changes.Count > 0)
                {
                    s.Prompt = new Prompt.RestartForOptions(changes);
                    return;
                }
            }
            ResumeAfterOverlay();
        }

        /// <summary>
        /// A switched «Wiederholungsfragen» (review) or «Nachkontrolle nach Fehlern» (recheck) applies to the running
        /// session at once (State.Review/Recheck), also while the options are open, so the stored session never lags
        /// behind the other stored ones: switched off, their questions go (also the one on screen, which makes way for the
        /// next one); switched on, they come from now on. Only the switched one: a session started for its repetition
        /// questions keeps them when the rechecks are switched.
        /// </summary>
        void ApplySwitches(bool review = false, bool recheck = false)
        {
            if (!(review || recheck) || s.Session is not { FinishedAt: null } session) return;
            var next = session;
            if (review) next = LearnEngine.SetReview(next, s.Review, env.Progress, Now);
            if (recheck) next = LearnEngine.SetRecheck(next, s.Recheck, Now);
            if (ReferenceEquals(next, session)) return;
            s.Session = next;
            Persist();
            if (s.Phase.IsQuestion && LearnEngine.Current(next)?.Qid != s.Question?.Qid) ShowQuestion();
        }

        /// <summary>A closed overlay or prompt restarts the countdown it interrupted.</summary>
        void ResumeAfterOverlay()
        {
            if (!s.AutoAdvancePaused) return;
            s.AutoAdvancePaused = false;
            if (s.Phase == Phase.Copy)
            {
                ContinueTypedOutCopy();
                return;
            }
            if (s.Phase != Phase.FeedbackOf(FeedbackKind.Correct) || s.Feedback is not { } f) return;
            Lock();
            StartAdvance(f.AutoAdvanceMs ?? ADVANCE_MS);
        }

        void Restart()
        {
            switch (s.Phase.Kind)
            {
                case PhaseKind.Question or PhaseKind.Feedback or PhaseKind.Copy or PhaseKind.Checkpoint:
                    if (s.Session is null) return;
                    PauseAdvance();
                    s.Prompt = new Prompt.RestartSession();
                    break;
                case PhaseKind.Finished or PhaseKind.AllMastered:
                    RequestRelearn();
                    break;
            }
        }

        /// <summary>"Nochmal lernen": asks before the scope's progress is reset.</summary>
        void RequestRelearn()
        {
            List<string> ids;
            if (s.Phase == Phase.Finished) ids = s.Session?.Order.ToList() ?? [];
            else if (s.Phase == Phase.AllMastered) ids = s.ScopeCardIds.ToList();
            else return;
            if (ids.Count == 0) return;
            s.Prompt = new Prompt.Relearn(ids);
        }

        void PromptAnswered(bool confirmed)
        {
            if (s.Prompt is not { } prompt) return;
            s.Prompt = null;
            switch (prompt)
            {
                case Prompt.RestartSession or Prompt.RestartForOptions:
                    if (confirmed) StartFresh(s.Session?.Subset ?? s.Subset);
                    else
                    {
                        if (prompt is Prompt.RestartForOptions) KeepChangedOptions();
                        ResumeAfterOverlay();
                    }
                    break;
                case Prompt.Relearn relearn:
                {
                    if (!confirmed)
                    {
                        ResumeAfterOverlay();
                        return;
                    }
                    // Forget the progress of the scope's cards, then start over.
                    var subset = s.Subset;
                    var progress = new Dictionary<string, CardProgress>(env.Progress, StringComparer.Ordinal);
                    if (subset.Equals(StudySubset.All))
                    {
                        Emit(new Effect.ResetProgress(null));
                        progress.Clear();
                    }
                    else
                    {
                        Emit(new Effect.ResetProgress(relearn.CardIds));
                        foreach (var id in relearn.CardIds) progress.Remove(id);
                    }
                    StartFresh(subset, progress);
                    break;
                }
                case Prompt.ReplaceSession replace:
                    if (confirmed) StartFresh(replace.Wanted);
                    else
                    {
                        if (HasLearnAnswers(s.Session)) Emit(new Effect.Toast(WELCOME_BACK, Tone.Neutral));
                        ResumeAfterOverlay();
                    }
                    break;
            }
        }
    }
}

/// <summary>Swift <c>Character</c> helpers for typed letters (grapheme clusters, like String.count / removeLast).</summary>
internal static class Graphemes
{
    public static int Count(string s) => s.Length == 0 ? 0 : new StringInfo(s).LengthInTextElements;

    public static string DropLast(string s)
    {
        if (s.Length == 0) return s;
        var starts = StringInfo.ParseCombiningCharacters(s);
        return s[..starts[^1]];
    }

    static string Last(string s)
    {
        var starts = StringInfo.ParseCombiningCharacters(s);
        return s[starts[^1]..];
    }

    /// <summary>Swift <c>Character.isWhitespace</c> of the last character.</summary>
    public static bool LastIsWhitespace(string s) => s.Length > 0 && char.IsWhiteSpace(Last(s), 0);

    /// <summary>Swift <c>allSatisfy(\.isWhitespace)</c> (true for "").</summary>
    public static bool AllWhitespace(string s)
    {
        if (s.Length == 0) return true;
        var starts = StringInfo.ParseCombiningCharacters(s);
        return starts.All(i => char.IsWhiteSpace(s, i));
    }
}
