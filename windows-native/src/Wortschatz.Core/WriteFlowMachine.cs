namespace Wortschatz.Core;

// Port of WriteFlowMachine.swift: the engine of WriteFlow. One reducer step as a small mutable machine
// whose methods mirror the functions of src/screens/write.js one to one (startFresh, showNextQuestion,
// commitAnswer, continueNext, afterRoundEnds, reconcile, …). Only WriteFlow.Start and WriteFlow.Reduce
// use it. It works on a Clone of the state; records inside it are replaced (`with`), never mutated.

public static partial class WriteFlow
{
    sealed class Machine
    {
        State s;
        readonly Env env;
        readonly List<Effect> effects = [];
        Dictionary<string, Card> cards;

        public Machine(State state, Env env)
        {
            s = state.Clone();
            this.env = env;
            cards = CardIndex(state.Set?.Cards ?? []);
        }

        /// <summary>The state and the effects, with repeated saves and announcements collapsed into the latest one.</summary>
        public (State, List<Effect>) Finish()
        {
            bool seenSave = false, seenAnnounce = false;
            var kept = new List<Effect>();
            for (int i = effects.Count - 1; i >= 0; i--)
            {
                var effect = effects[i];
                if (effect is Effect.SaveSession)
                {
                    if (seenSave) continue;
                    seenSave = true;
                }
                else if (effect is Effect.Announce)
                {
                    if (seenAnnounce) continue;
                    seenAnnounce = true;
                }
                kept.Add(effect);
            }
            kept.Reverse();
            return (s, kept);
        }

        // MARK: Helpers

        /// <summary>Within EnterLockMs after a transition. A lock further in the future is stale (clock set back) and never blocks.</summary>
        bool Locked
        {
            get
            {
                double remaining = s.LockUntil - env.Now;
                return remaining > 0 && remaining <= EnterLockMs;
            }
        }

        void Lock() => s.LockUntil = env.Now + EnterLockMs;

        void ClearAdvance() => s.AutoAdvance = null;

        /// <summary>
        /// Return (or a click on "Weiter") within the lock after a correct answer moves on the moment the lock ends,
        /// so the praise can always be skipped. A miss stays readable for the whole lock.
        /// </summary>
        void SkipPraiseWhenUnlocked()
        {
            if (s.IsBlocked || s.Phase != Phase.FeedbackOf(FeedbackKind.Correct) || !Locked) return;
            double lockedAt = s.LockUntil - EnterLockMs;
            if (env.Now - lockedAt < SkipMinGapMs) return;
            StartAdvance(Math.Max(1, (int)Math.Ceiling(s.LockUntil - env.Now)));
        }

        /// <summary>Schedules the auto-advance in ms (a new token, so an older timer is ignored).</summary>
        void StartAdvance(int ms)
        {
            s.NextToken++;
            s.AutoAdvance = new AutoAdvance(s.NextToken, ms);
            effects.Add(new Effect.ScheduleAutoAdvance(ms, s.NextToken));
        }

        void Persist()
        {
            if (s.Session is { } session) effects.Add(new Effect.SaveSession(session, s.Pending));
        }

        void Announce(string text) => effects.Add(new Effect.Announce(text));

        void IndexCards() => cards = CardIndex(s.Set?.Cards ?? []);

        bool Usable(string cardId) => IsUsableCard(cards.GetValueOrDefault(cardId));

        Question? QuestionInfoOf(SessionQuestion? q) =>
            q is not null && s.Set is { } set && cards.TryGetValue(q.CardId, out var card) ? QuestionInfo(set, card, q) : null;

        Question? InfoFor(Question? info) => QuestionInfoOf(info?.SessionQuestion);

        /// <summary>GradeQuestion with the set and tolerance of the flow.</summary>
        SynonymGradeResult Grade(Question info, string given) =>
            GradeQuestion(s.Set, info, given, s.Options.Tolerance, env.ExtraAnswers(info.SynonymQuery));

        /// <summary>The question whose card the star, the editor and the speaker act on.</summary>
        Question? ActiveInfo()
        {
            if (!s.Phase.IsCard || s.Session is not { } session) return null;
            if (s.Phase == Phase.Question) return QuestionInfoOf(WriteSession.Current(session));
            return s.Feedback is not null ? InfoFor(s.Question) : null;
        }

        /// <summary>Distinct card ids of the session's questions, in asking order.</summary>
        List<string> CardIdsInSession()
        {
            if (s.Session is not { } session) return [];
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var ids = new List<string>();
            var ordered = new HashSet<string>(session.Order, StringComparer.Ordinal);
            var rest = session.Questions.Keys.Where(k => !ordered.Contains(k)).Order(StringComparer.Ordinal);
            foreach (var qid in session.Order.Concat(rest))
                if (session.Questions.TryGetValue(qid, out var q) && seen.Add(q.CardId)) ids.Add(q.CardId);
            return ids;
        }

        /// <summary>A subset given as a name ("all", "starred", …), else All.</summary>
        StudySubset NamedSubset() => s.Session?.Subset.Kind switch
        {
            StudySubsetKind.Starred => StudySubset.Starred,
            StudySubsetKind.Learning => StudySubset.Learning,
            StudySubsetKind.Missed => StudySubset.Missed,
            _ => StudySubset.All,
        };

        // MARK: Events

        public void Handle(Event e)
        {
            switch (e)
            {
                case Event.Key k: HandleKey(k.Input, k.IsRepeat); break;
                case Event.InputChanged: break; // handled in Reduce
                case Event.Submit submit:
                    if (s.IsBlocked) return;
                    if (s.Phase == Phase.Question)
                    {
                        s.Input = submit.Text;
                        SubmitAnswer(submit.Text);
                    }
                    else if (s.Phase == Phase.Copy)
                    {
                        s.Input = submit.Text;
                        SubmitCopy(submit.Text);
                    }
                    break;
                case Event.DontKnow:
                    if (!s.IsBlocked) DontKnow();
                    break;
                case Event.Proceed:
                    if (!s.IsBlocked) PrimaryAction();
                    break;
                case Event.Override:
                    if (!s.IsBlocked) OverrideLast();
                    break;
                case Event.AutoAdvanceFired fired:
                    if (s.AutoAdvance is { } pending && pending.Token == fired.Token) ContinueNext(fromUser: false);
                    break;
                case Event.ToggleStar:
                    if (!s.IsBlocked) ToggleStar();
                    break;
                case Event.Speak speak:
                {
                    if (!s.Phase.IsCard || s.Question is not { } q) return;
                    var (text, lang) = speak.Target == SpeechTarget.Prompt ? (q.Prompt, q.PromptLang) : (q.Expected, q.AnswerLang);
                    // The speaker buttons only exist for languages with a voice.
                    if (lang != Lang.Other && HasText(text)) effects.Add(new Effect.Speak(text, lang));
                    break;
                }
                case Event.RequestEdit:
                    if (!s.IsBlocked) OpenEdit();
                    break;
                case Event.EditCard edit: SaveEdit(edit.Card); break;
                case Event.RequestOptions:
                    if (!s.IsBlocked) OpenOptions();
                    break;
                case Event.OptionsChanged changed: s.Options = changed.Options; break;
                case Event.OverlayDismissed dismissed: CloseOverlay(dismissed.RestartRequested); break;
                case Event.PromptAnswered answered: AnswerPrompt(answered.Confirmed); break;
                case Event.Restart:
                    if (s.IsBlocked) return;
                    if (s.Phase == Phase.Results) StartFresh(NamedSubset());
                    else ConfirmRestart(resumesTimer: false);
                    break;
                case Event.RetryMissed:
                    if (!s.IsBlocked) RetryMissed();
                    break;
                case Event.PracticeAll:
                    if (!s.IsBlocked && s.Phase == Phase.Empty) StartFresh(StudySubset.All);
                    break;
                case Event.Leave: effects.Add(new Effect.Exit()); break;
                case Event.SetChanged changed: Reconcile(changed.Set); break;
                case Event.CardsChanged changed:
                    if (s.Set is { } set) Reconcile(set with { Cards = changed.Cards.ToList() });
                    break;
                case Event.SetDeleted: Reconcile(null); break;
                case Event.ClockTick:
                    if (!IsStudying(s) || s.Session is not { } ticking) return;
                    s.Session = WriteSession.Tick(ticking, env.Now);
                    Persist();
                    break;
                case Event.ClockResumed:
                    if (s.Session is not { FinishedAt: null } running) return;
                    var resumed = WriteSession.CopyState(running);
                    resumed.UpdatedAt = env.Now;
                    s.Session = resumed;
                    break;
            }
        }

        /// <summary>
        /// write-keys.js: Return is the primary action; held keys and presses right after a transition are swallowed;
        /// any printable key continues after a correct answer. Nothing happens while a sheet or alert is open.
        /// </summary>
        void HandleKey(KeyInput key, bool isRepeat)
        {
            if (s.IsBlocked || isRepeat) return;
            switch (key.Kind)
            {
                case KeyKind.Return:
                    if (Locked)
                    {
                        SkipPraiseWhenUnlocked();
                        return;
                    }
                    PrimaryAction();
                    break;
                case KeyKind.OptionReturn:
                    if (Locked) return;
                    if (s.Phase == Phase.Question) DontKnow();
                    break;
                case KeyKind.CommandReturn:
                    if (Locked) return;
                    if (s.Phase.IsMiss) OverrideLast();
                    break;
                case KeyKind.Escape: effects.Add(new Effect.Exit()); break;
                case KeyKind.Digit: ContinueOnKey(key.Digit.ToString(System.Globalization.CultureInfo.InvariantCulture)); break;
                case KeyKind.Character: ContinueOnKey(key.Text ?? ""); break;
            }
        }

        /// <summary>"Weiter mit beliebiger Taste": a printable key continues after a correct answer and lands in the next question's field (a space only continues).</summary>
        void ContinueOnKey(string text)
        {
            if (s.Phase != Phase.FeedbackOf(FeedbackKind.Correct) || text.Length != 1) return;
            ContinueNext(fromUser: false);
            if (s.Phase == Phase.Question && text != " ") s.Input = text;
        }

        /// <summary>What Return (and the primary button) does in the current phase (spec §4.3).</summary>
        void PrimaryAction()
        {
            switch (s.Phase.Kind)
            {
                case PhaseKind.Starting: break;
                case PhaseKind.Question: SubmitAnswer(s.Input); break;
                case PhaseKind.Feedback: ContinueNext(fromUser: true); break;
                case PhaseKind.Copy: SubmitCopy(s.Input); break;
                case PhaseKind.Summary: GoNextRound(fromUser: true); break;
                case PhaseKind.Results:
                    if (s.Results?.CanRetry == true) RetryMissed();
                    else effects.Add(new Effect.Exit());
                    break;
                case PhaseKind.Empty:
                    if ((s.EmptySubset ?? StudySubset.All).Kind == StudySubsetKind.All) effects.Add(new Effect.EditSet());
                    else StartFresh(StudySubset.All);
                    break;
                case PhaseKind.Missing: effects.Add(new Effect.Exit()); break;
            }
        }

        // MARK: Sessions

        public void Boot(SessionState? saved, PendingFeedback? feedback, StudySubset? wanted, bool forceNew, double? marker)
        {
            bool showResultsAgain = CanShowResults(saved, forceNew, wanted, marker);
            if (saved is null || !(showResultsAgain || CanResume(saved, forceNew, wanted)))
            {
                // A requested subset must not drop a round the learner already answered in without asking.
                if (wanted is not null && saved is not null && CanResume(saved) && HasAnswers(saved))
                {
                    s.Prompt = new Prompt.ReplaceRound(wanted, saved, feedback);
                    return;
                }
                StartFresh(wanted ?? StudySubset.All);
                return;
            }
            ResumeSaved(saved, feedback, showResultsAgain, wanted);
        }

        void StartFresh(StudySubset subset)
        {
            ClearAdvance();
            s.Feedback = null;
            s.Pending = null;
            if (s.Set is not { } set) return;
            var fresh = WriteSession.CreateSession(set.Cards, s.Options, subset, env.Rng, env.Now, env.Progress);
            if (fresh.Order.Count == 0)
            {
                ShowEmpty(subset);
                return;
            }
            s.Session = fresh;
            Persist();
            ShowNextQuestion(animate: false);
        }

        /// <summary>Drops the questions whose card was deleted (or emptied) since the session started.</summary>
        bool PruneSession()
        {
            bool changed = false;
            foreach (var id in CardIdsInSession())
            {
                if (Usable(id)) continue;
                if (s.Session is not { } session) break;
                s.Session = WriteSession.RemoveCard(session, id, env.Now);
                changed = true;
            }
            return changed;
        }

        void ResumeSaved(SessionState saved, PendingFeedback? feedback, bool showResultsAgain, StudySubset? wanted)
        {
            var session = WriteSession.CopyState(saved);
            // Time away is not study time (a finished session's clock is stopped).
            if (!showResultsAgain) session.UpdatedAt = env.Now;
            s.Session = session;
            bool pruned = PruneSession();
            s.Pending = showResultsAgain ? null : PendingFeedbackOf(s.Session, feedback);
            if (pruned) Persist();
            if (s.Session is not { } current || current.Order.Count == 0)
            {
                StartFresh(wanted ?? StudySubset.All);
                return;
            }
            if (showResultsAgain)
            {
                // Also closes the last round when the screen was left during the final "Richtig!".
                FinishSession();
                return;
            }
            if (HasAnswers(current)) effects.Add(new Effect.ShowToast(Toast.WelcomeBack));
            if (s.Pending is not null) ReopenFeedback();
            else AfterRoundEnds();
        }

        /// <summary>The "Nicht ganz" screen that was open when Write mode was left; the answer itself is already recorded.</summary>
        void ReopenFeedback()
        {
            if (s.Pending is not { } pending || QuestionInfoOf(s.Session?.Questions.GetValueOrDefault(pending.Qid)) is not { } info)
            {
                s.Pending = null;
                AfterRoundEnds();
                return;
            }
            var result = pending.DontKnow || !HasText(pending.Given) ? null : Grade(info, pending.Given).Result;
            PresentQuestion(info, animate: false);
            s.Feedback = new Feedback(pending.Given, result, pending.DontKnow);
            ShowIncorrect();
        }

        // MARK: Question

        void ShowNextQuestion(bool animate = true)
        {
            ClearAdvance();
            if (s.Session is not { } session) return;
            var q = WriteSession.Current(session);
            bool pruned = false;
            while (q is not null && !Usable(q.CardId))
            {
                session = WriteSession.RemoveCard(session, q.CardId, env.Now);
                pruned = true;
                q = WriteSession.Current(session);
            }
            s.Session = session;
            if (pruned) Persist();
            if (q is null || QuestionInfoOf(q) is not { } info)
            {
                AfterRoundEnds();
                return;
            }
            // The answer field kept focus (the screen reader does not read the new prompt by itself).
            bool keepsFocus = s.Phase == Phase.Question || s.Phase == Phase.FeedbackOf(FeedbackKind.Correct) || s.Phase == Phase.Copy;
            bool enteringStage = !s.Phase.IsCard;
            PresentQuestion(info, animate && !enteringStage);
            Lock();
            if (keepsFocus)
            {
                bool both = session.SetOptions.AnswerWith == AnswerWith.Both;
                Announce($"{info.PromptLabel}: {info.Prompt}{(both ? $". {info.Placeholder}." : "")}");
            }
            if (s.Options.Audio && info.Ask == AskSide.Definition) effects.Add(new Effect.Speak(info.Prompt, info.PromptLang));
        }

        /// <summary><c>card.setQuestion</c>: the card shows info with an empty, editable answer field.</summary>
        void PresentQuestion(Question info, bool animate)
        {
            s.Phase = Phase.Question;
            s.Question = info;
            s.Feedback = null;
            s.Input = "";
            s.InputInvalid = false;
            s.QuestionSerial++;
            s.AnimatesQuestion = animate;
            s.Summary = null;
            s.Results = null;
            s.EmptySubset = null;
        }

        void SubmitAnswer(string value)
        {
            if (s.Phase != Phase.Question || s.Session is not { } session || QuestionInfoOf(WriteSession.Current(session)) is not { } info) return;
            if (!HasText(value))
            {
                s.Rejections++;
                Announce("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht».");
                return;
            }
            var graded = Grade(info, value);
            CommitAnswer(info, JSCompat.Trim(value), graded.Result, dontKnow: false, synonym: graded.IsSynonym);
        }

        void DontKnow()
        {
            if (s.Phase != Phase.Question || s.Session is not { } session || QuestionInfoOf(WriteSession.Current(session)) is not { } info) return;
            CommitAnswer(info, "", null, dontKnow: true, synonym: false);
        }

        void CommitAnswer(Question info, string given, GradeResult? result, bool dontKnow, bool synonym)
        {
            ClearAdvance();
            if (s.Session is not { } session) return;
            bool correct = result?.Correct == true;
            double at = env.Now;
            effects.Add(new Effect.RecordAnswer(info.CardId, correct, at));
            s.Session = WriteSession.Answer(session, correct, at);
            s.Pending = correct ? null : new PendingFeedback(info.Qid, given, dontKnow);
            Persist();
            s.Question = info;
            s.Feedback = new Feedback(given, result, dontKnow, Synonym: synonym);
            if (s.Options.Audio && s.Set is { } set && cards.TryGetValue(info.CardId, out var card))
                effects.Add(new Effect.Speak(card.Term, set.TermLang));
            if (correct)
            {
                effects.Add(new Effect.Haptic(HapticKind.Success));
                ShowCorrect();
            }
            else
            {
                if (!dontKnow) effects.Add(new Effect.Haptic(HapticKind.Failure));
                ShowIncorrect();
            }
        }

        string PickPraise()
        {
            var pool = Praise.Where(p => p != s.LastPraise).ToList();
            int index = (int)Math.Floor(env.Rng() * pool.Count);
            s.LastPraise = pool[Math.Min(Math.Max(index, 0), pool.Count - 1)];
            return s.LastPraise;
        }

        void ShowCorrect()
        {
            if (s.Feedback is not { } fb || fb.Result is not { } result) return;
            s.Phase = Phase.FeedbackOf(FeedbackKind.Correct);
            // "Genau!" right above a "Genau: …" correction would read oddly; a synonym shows the word the card asked for.
            var praise = fb.Synonym ? "Auch richtig!" : result.Exact ? PickPraise() : "Richtig!";
            fb = fb with { Praise = praise };
            s.Feedback = fb;
            int ms = s.Options.AutoAdvance ? (result.Exact ? AdvanceMs : AdvanceMsWithNotes) : 0;
            Announce(result.Exact ? praise : $"{praise} {fb.ExactLabel} {result.ExpectedDisplay}");
            Lock();
            if (ms > 0) StartAdvance(ms);
        }

        void ShowIncorrect()
        {
            if (s.Feedback is not { } fb || s.Question is not { } info) return;
            fb = fb with { Copy = s.Options.CopyAnswer };
            s.Feedback = fb;
            s.Phase = fb.Copy ? Phase.Copy : Phase.FeedbackOf(fb.DontKnow ? FeedbackKind.DontKnow : FeedbackKind.Wrong);
            if (fb.Copy)
            {
                // The copy field starts empty.
                s.Input = "";
                s.InputInvalid = false;
            }
            var lead = fb.DontKnow ? "Kein Problem." : "Nicht ganz.";
            var hint = fb.HintLabel is { } h ? $" {h}." : "";
            var tail = fb.Copy ? " Tippe die richtige Antwort ab." : "";
            Announce($"{lead} Richtige Antwort: {info.Expected}.{hint}{tail}");
            Lock();
        }

        void SubmitCopy(string value)
        {
            if (!s.Phase.IsMiss || s.Feedback is not { } fb) return;
            if (!fb.Copy)
            {
                ContinueNext(fromUser: true);
                return;
            }
            var info = InfoFor(s.Question) ?? s.Question;
            if (CopyAccepted(value, info, s.Options.Tolerance)) ContinueNext(fromUser: true);
            else
            {
                s.InputInvalid = true;
                s.Rejections++;
                Announce("Noch nicht ganz – tippe die richtige Antwort genau ab.");
            }
        }

        /// <summary>fromUser: keys and clicks respect the short lock, so one press never skips two steps.</summary>
        void ContinueNext(bool fromUser)
        {
            if (!s.Phase.IsCard || s.Phase == Phase.Question || s.Session is not { } session) return;
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
            if (WriteSession.IsRoundOver(session)) AfterRoundEnds();
            else ShowNextQuestion();
        }

        void OverrideLast()
        {
            if (!s.Phase.IsMiss || s.Feedback is not { CanOverride: true } || s.Question is not { } info || s.Session is not { } session) return;
            ClearAdvance();
            effects.Add(new Effect.OverrideLastAnswer(info.CardId));
            s.Session = WriteSession.Override(session, info.Qid, env.Now);
            s.Pending = null;
            Persist();
            effects.Add(new Effect.ShowToast(Toast.CountedAsCorrect));
            ContinueNext(fromUser: false);
        }

        // MARK: Rounds and results

        void AfterRoundEnds()
        {
            if (s.Session is not { } session) return;
            if (session.Order.Count == 0) SessionEmptied();
            else if (WriteSession.IsFinished(session)) FinishSession();
            else if (WriteSession.IsRoundOver(session)) ShowSummary();
            else ShowNextQuestion();
        }

        void LeaveCard()
        {
            s.Question = null;
            s.Feedback = null;
            s.Input = "";
            s.InputInvalid = false;
        }

        void ShowSummary()
        {
            ClearAdvance();
            if (s.Session is not { } session) return;
            var summary = WriteSession.RoundSummaryOf(session);
            LeaveCard();
            s.Phase = Phase.Summary;
            s.Summary = summary;
            s.Results = null;
            Announce($"Runde {summary.Round} geschafft: {summary.Correct} von {summary.Total} richtig.");
            Lock();
        }

        void GoNextRound(bool fromUser)
        {
            if (s.Phase != Phase.Summary || (fromUser && Locked) || s.Session is not { } session) return;
            var next = WriteSession.NextRound(session, env.Rng, env.Now);
            s.Session = next;
            Persist();
            if (WriteSession.IsFinished(next)) FinishSession();
            else ShowNextQuestion(animate: false);
        }

        /// <summary>write.js <c>finish</c>: closes the last round into the history and stamps finishedAt.</summary>
        void FinishSession()
        {
            ClearAdvance();
            if (s.Session is not { } session) return;
            s.Session = WriteSession.NextRound(session, env.Rng, env.Now);
            Persist();
            ShowResults();
        }

        void ShowResults()
        {
            if (s.Session is not { } session) return;
            LeaveCard();
            s.Phase = Phase.Results;
            s.Summary = null;
            var stats = WriteSession.FinalStatsOf(session);
            if (stats.Total == 0)
            {
                SessionEmptied();
                return;
            }
            s.Results = new Results(stats, stats.MissedCardIds.Where(Usable).ToList(), CardIdsInSession().Count,
                session.SetOptions.AnswerWith == AnswerWith.Both);
            var percent = JSCompat.NumberToString(JSCompat.Round(stats.Accuracy * 100));
            Announce($"Geschafft! {percent} Prozent beim ersten Versuch richtig.");
            Lock();
        }

        void RetryMissed()
        {
            if (s.Phase != Phase.Results || s.Results?.RetryCardIds is not { Count: > 0 } missed) return;
            StartFresh(StudySubset.CardIds(missed));
        }

        // MARK: Messages

        void ShowEmpty(StudySubset subset)
        {
            ClearAdvance();
            LeaveCard();
            s.Pending = null;
            s.Phase = Phase.Empty;
            s.EmptySubset = subset;
            s.Summary = null;
            s.Results = null;
        }

        /// <summary>Every question of the session vanished (cards deleted elsewhere).</summary>
        void SessionEmptied()
        {
            if (s.Set?.Cards.Any(IsUsableCard) == true) StartFresh(NamedSubset());
            else ShowEmpty(StudySubset.All);
        }

        void ShowGone()
        {
            ClearAdvance();
            LeaveCard();
            s.Phase = Phase.Missing;
            s.Set = null;
            s.Session = null;
            s.Pending = null;
            s.Summary = null;
            s.Results = null;
            s.EmptySubset = null;
            s.Overlay = null;
            s.Prompt = null;
            IndexCards();
        }

        // MARK: Card edits

        void ToggleStar()
        {
            if (ActiveInfo() is not { } info || s.Set is not { } set) return;
            int index = set.Cards.FindIndex(c => c.Id == info.CardId);
            if (index < 0) return;
            effects.Add(new Effect.ToggleStar(info.CardId));
            var newCards = set.Cards.ToList();
            newCards[index] = newCards[index] with { Starred = !newCards[index].Starred };
            s.Set = set with { Cards = newCards };
            IndexCards();
            if (s.Question?.CardId == info.CardId) s.Question = s.Question with { Starred = newCards[index].Starred };
        }

        void OpenEdit()
        {
            if (ActiveInfo() is not { } info || !cards.ContainsKey(info.CardId)) return;
            bool resumesTimer = s.AutoAdvance is not null;
            ClearAdvance();
            s.Overlay = new Overlay.Editor(info.SessionQuestion, info.Ask, resumesTimer);
        }

        void SaveEdit(Card edited)
        {
            if (s.Overlay is not Overlay.Editor editor || s.Set is not { } set) return;
            int index = set.Cards.FindIndex(c => c.Id == editor.Question.CardId);
            if (index < 0) return;
            var term = JSCompat.Trim(edited.Term);
            var definition = JSCompat.Trim(edited.Definition);
            // The editor never saves an empty side.
            if (term.Length == 0 || definition.Length == 0) return;
            var newCards = set.Cards.ToList();
            newCards[index] = newCards[index] with { Term = term, Definition = definition };
            effects.Add(new Effect.UpdateCard(newCards[index]));
            s.Set = set with { Cards = newCards };
            IndexCards();
            ApplyCardEdit(editor.Question);
            effects.Add(new Effect.ShowToast(Toast.CardSaved));
            s.Overlay = null;
            ResumeAfterOverlay(editor.ResumesTimer, copyChanged: false);
        }

        void ApplyCardEdit(SessionQuestion question)
        {
            if (QuestionInfoOf(question) is not { } updated) return;
            if (s.Phase.IsMiss && s.Feedback is { } fb)
            {
                s.Question = updated;
                // If the corrected card now accepts what was typed, offer to count it.
                var r = !fb.DontKnow && HasText(fb.Given) ? Grade(updated, fb.Given).Result : null;
                s.Feedback = fb with { EditedCorrect = r?.Correct == true };
                ShowIncorrect();
            }
            else s.Question = updated;
        }

        // MARK: Options and dialogs

        void OpenOptions()
        {
            if (!(s.Phase.IsCard || s.Phase == Phase.Summary || s.Phase == Phase.Results)) return;
            bool resumesTimer = s.AutoAdvance is not null;
            ClearAdvance();
            s.Overlay = new Overlay.Options(new OptionsBaseline(s.Options), resumesTimer);
        }

        void CloseOverlay(bool restartRequested)
        {
            switch (s.Overlay)
            {
                case null: return;
                case Overlay.Editor editor:
                    s.Overlay = null;
                    ResumeAfterOverlay(editor.ResumesTimer, copyChanged: false);
                    break;
                case Overlay.Options options:
                    s.Overlay = null;
                    AfterOptions(options.Before, options.ResumesTimer, restartRequested);
                    break;
            }
        }

        void AfterOptions(OptionsBaseline before, bool resumesTimer, bool restartRequested)
        {
            if (restartRequested)
            {
                ConfirmRestart(resumesTimer);
                return;
            }
            bool directionChanged = s.Options.AnswerWith != before.AnswerWith;
            bool orderChanged = directionChanged || s.Options.Shuffle != before.Shuffle;
            bool copyChanged = s.Options.CopyAnswer != before.CopyAnswer;
            if (s.Session is { FinishedAt: null } session && orderChanged
                && (session.SetOptions.AnswerWith != s.Options.AnswerWith || session.SetOptions.Shuffle != s.Options.Shuffle))
            {
                s.Prompt = new Prompt.RestartForOptions(directionChanged, resumesTimer, copyChanged);
                return;
            }
            ResumeAfterOverlay(resumesTimer, copyChanged);
        }

        /// <summary>Hands the step back after a sheet or alert: restarts the auto-advance it paused and shows the copy step when it was switched.</summary>
        void ResumeAfterOverlay(bool resumesTimer, bool copyChanged)
        {
            s.FocusSerial++;
            if (!s.Phase.IsCard) return;
            if (s.Phase == Phase.FeedbackOf(FeedbackKind.Correct) && (resumesTimer || s.Options.AutoAdvance)) ShowCorrect();
            else if (s.Phase.IsMiss && copyChanged) ShowIncorrect();
        }

        void ConfirmRestart(bool resumesTimer)
        {
            if (s.Phase == Phase.Empty || s.Phase == Phase.Missing || s.Phase == Phase.Starting) return;
            bool timerWasRunning = resumesTimer || s.AutoAdvance is not null;
            ClearAdvance();
            s.Prompt = new Prompt.Restart(timerWasRunning);
        }

        void AnswerPrompt(bool confirmed)
        {
            if (s.Prompt is not { } prompt) return;
            s.Prompt = null;
            switch (prompt)
            {
                case Prompt.Restart restart:
                    if (confirmed) StartFresh(s.Session?.Subset ?? StudySubset.All);
                    else ResumeAfterOverlay(restart.ResumesTimer, copyChanged: false);
                    break;
                case Prompt.RestartForOptions options:
                    if (confirmed && s.Session is { } session) StartFresh(session.Subset);
                    else ResumeAfterOverlay(options.ResumesTimer, options.CopyChanged);
                    break;
                case Prompt.ReplaceRound replace:
                    if (confirmed) StartFresh(replace.Wanted);
                    // The round's own subset applies.
                    else ResumeSaved(replace.Saved, replace.Feedback, showResultsAgain: false, wanted: null);
                    break;
            }
        }

        // MARK: Live updates

        /// <summary>The card being edited was deleted elsewhere: the editor closes (resuming the step).</summary>
        void CloseEditorOfDeletedCard()
        {
            if (s.Overlay is not Overlay.Editor editor || cards.ContainsKey(editor.Question.CardId)) return;
            s.Overlay = null;
            ResumeAfterOverlay(editor.ResumesTimer, copyChanged: false);
        }

        /// <summary>The set changed outside the flow (write.js <c>reconcile</c>).</summary>
        void Reconcile(VocabSet? fresh)
        {
            if (fresh is null)
            {
                ShowGone();
                return;
            }
            s.Set = fresh;
            IndexCards();
            try
            {
                if (s.Session is null) return;
                bool pruned = PruneSession();
                if (pruned) Persist();
                switch (s.Phase.Kind)
                {
                    case PhaseKind.Question:
                        if (QuestionInfoOf(s.Session is { } cur ? WriteSession.Current(cur) : null) is { } info) s.Question = info;
                        else AfterRoundEnds();
                        break;
                    case PhaseKind.Feedback or PhaseKind.Copy:
                        if (InfoFor(s.Question) is { } updated) s.Question = updated;
                        break;
                    case PhaseKind.Summary when pruned:
                        AfterRoundEnds();
                        break;
                    case PhaseKind.Results when pruned:
                        ShowResults();
                        break;
                }
            }
            finally
            {
                CloseEditorOfDeletedCard();
            }
        }
    }
}
