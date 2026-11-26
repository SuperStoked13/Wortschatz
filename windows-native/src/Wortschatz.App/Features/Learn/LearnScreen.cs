using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;
using Phase = Wortschatz.Core.LearnFlow.Phase;
using PhaseKind = Wortschatz.Core.LearnFlow.PhaseKind;

namespace Wortschatz.App.Features.Learn;

/// <summary>
/// The Learn screen (Mac: LearnScreen.swift, LearnStage.swift, LearnPromptCard.swift, ChoiceTile.swift,
/// LearnActionBar.swift, LearnCheckpointView.swift, LearnFinishView.swift) in the Glas design: back pill, "Runde N" with
/// the progress capsule, Optionen and Neu starten on top; the prompt card with its tools (🔊 ★ ✎) and, for multiple
/// choice, the 2×2 answer tiles below it; the floating action bar with the status pill (key hints, feedback, streak,
/// countdown) on the left and the Enter action on the right.
///
/// The screen is rebuilt from LearnController.State on every change, like before. What moves is decided by comparing
/// with what the last render showed (Mac: SwiftUI transitions): a new question glides in (prompt from the right, tiles
/// from below), a tile that turns wrong shakes, a rejected entry shakes, the pill bounces, the progress glides. The
/// first render is the screen's entrance (Mac: StudyEntrance).
/// </summary>
public sealed class LearnScreen : Screen
{
    readonly LearnController _c;
    readonly TextBox _answer;
    readonly TextBox _copy;
    readonly Border _focusSink = new() { Focusable = true, Width = 0, Height = 0 };
    readonly ProgressCapsuleView _capsule;
    readonly TextBlock _roundText;
    // What the last render showed: its changes play the motions.
    bool _rendered;
    string? _shownQid;
    Phase? _shownPhase;
    int _shownTransitions = -1, _shownRejections, _shownStreak;
    ChoiceTileState[] _shownTiles = [];
    bool? _shownStarred;
    Card? _editing;
    Action? _editorSave;
    readonly SpeakingIndicator _speaking;
    /// <summary>The key down that typed the next text is an auto-repeat (TextInput carries no repeat flag).</summary>
    bool _textKeyRepeats;
    /// <summary>Narrow window: the progress capsule gets compact (Mac: width below 1120).</summary>
    bool _compact;

    public LearnScreen(AppModel model, MainView window, StudyRequest request) : base(model, window)
    {
        _c = new LearnController(model, request);
        _c.Changed += Render;
        _speaking = new SpeakingIndicator(model.Speech);
        _c.Spoke += _speaking.Started;
        _answer = StudyAnswerBox.Field(L("Antwort eingeben"));
        _answer.TextChanged += (_, _) =>
        {
            if (_c.State.Phase == Phase.Written) _c.Send(new LearnFlow.Event.DraftChanged(_answer.Text ?? ""));
        };
        _copy = StudyAnswerBox.Field(AppDevice.IsPhone ? L("Antwort abtippen") : L("Richtige Antwort abtippen"));
        _copy.TextChanged += (_, _) =>
        {
            if (_c.State.Phase == Phase.Copy) _c.Send(new LearnFlow.Event.DraftChanged(_copy.Text ?? ""));
        };
        var counts = _c.State.Counts;
        _capsule = new ProgressCapsuleView(counts.Fresh, counts.Learning, counts.Mastered);
        _roundText = Ui.Text("", 14, FontWeight.SemiBold, WsTheme.P.TextSecondary);
    }

    public override bool UsesSidebar => false;

    /// <summary>The screen's controller (the snapshot tool drives it).</summary>
    public LearnController Controller => _c;

    LearnFlow.State S => _c.State;
    static Palette P => WsTheme.P;

    public override void Activate()
    {
        _compact = Window.StudyArea.Width is > 0 and < CompactWidth;
        Window.SizeChanged += OnWindowSize;
        _c.OptionsRequested = OpenOptionsAtRecheck;
        _c.Activate(holdingToasts: true);
        Render();
        StudyEntrance.RevealScreen(View);
        // Toasts ("Willkommen zurück") once the screen has come in (Mac: StudyEntrance.toastDelay).
        DispatcherTimer.RunOnce(_c.ReleaseToasts, TimeSpan.FromMilliseconds(580));
    }

    public override void Deactivate()
    {
        Window.SizeChanged -= OnWindowSize;
        Window.Title = "Wortschatz";
        _c.Deactivate();
    }

    public override void WindowActivityChanged(bool active) => _c.WindowActivityChanged(active);

    /// <summary>The window width below which the progress capsule shows bare numbers (Mac: LearnScreen, 1120).</summary>
    const double CompactWidth = 1120;

    void OnWindowSize(object? sender, SizeChangedEventArgs e)
    {
        bool compact = e.NewSize.Width / Window.StudyScale < CompactWidth;
        if (compact == _compact) return;
        _compact = compact;
        Render();
    }

    /// <summary>Our own effects re-render through the controller; the store notification only forwards outside changes.</summary>
    public override void Refresh() { }

    /// <summary>The library changed (also from elsewhere): what differs reaches the flow (Mac: onChange(of: model.revision)).</summary>
    public override void LibraryChanged() => _c.StoreDidChange();

    protected override Control Build() => new Border();

    bool _holdRender;

    /// <summary>
    /// Runs many steps without drawing each of them, then draws once (the snapshot tool's fast-forward: drawing every
    /// step queued work for thousands of screens, 15–25 s per fast-forward instead of 1–2 s).
    /// </summary>
    public void WithoutRendering(Action steps)
    {
        _holdRender = true;
        try
        {
            steps();
        }
        finally
        {
            _holdRender = false;
            Render();
        }
    }

    void Render()
    {
        if (_holdRender) return;
        // The fields and the capsule are reused across renders (focus, caret, the bar's glide): out of the old tree first.
        foreach (var c in new Control[] { _answer, _copy, _focusSink, _capsule, _roundText }) Detach(c);
        var motion = new Moves(this);
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        root.Children.Add(TopRow());

        bool messages = S.Phase.Kind is PhaseKind.AllMastered or PhaseKind.Empty;
        Control main = S.Phase.Kind switch
        {
            PhaseKind.Question or PhaseKind.Feedback or PhaseKind.Copy => QuestionColumn(motion),
            PhaseKind.Checkpoint => CheckpointView(motion),
            PhaseKind.Finished => FinishView(motion.PhaseChanged),
            _ => MessageView(),
        };
        if (motion.PhaseChanged && S.Phase.Kind is PhaseKind.Checkpoint or PhaseKind.Finished or PhaseKind.AllMastered or PhaseKind.Empty)
            Effects.FadeIn(main, Motion.Soft(0.4));
        var scroll = Ui.Scroll(main);
        var stage = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
        stage.Children.Add(scroll);
        if (!messages)
        {
            var bar = ActionBar(motion);
            Grid.SetRow(bar, 1);
            stage.Children.Add(bar);
        }
        Grid.SetRow(stage, 1);
        root.Children.Add(stage);
        root.Children.Add(_focusSink);
        if (OverlayLayer() is { } overlay)
        {
            Grid.SetRowSpan(overlay, 2);
            root.Children.Add(overlay);
        }
        // A click beside the answer field while typing: the keys stay in the field (Mac: onChange(of: focus)).
        root.AddHandler(InputElement.PointerReleasedEvent, (_, _) => KeepFieldFocus(), Avalonia.Interactivity.RoutingStrategies.Bubble, handledEventsToo: true);
        ((ContentControl)View).Content = root;
        // The window's name in the taskbar (Mac: navigationTitle "Lernen", subtitle the set).
        var setTitle = Model.Set(_c.SetId)?.Title ?? S.SetTitle;
        Window.Title = setTitle.Length > 0 ? L($"Lernen – {setTitle}") : L("Lernen");
        motion.Remember();
        FocusAfterRender(motion.NewStep);
    }

    void KeepFieldFocus()
    {
        if (S.Prompt is not null || S.Overlay is not null || _editing is not null || Window.TextFieldFocused) return;
        var field = S.Phase == Phase.Written ? _answer : S.Phase == Phase.Copy ? _copy : null;
        if (field is null) return;
        Dispatcher.UIThread.Post(() =>
        {
            if (!Window.TextFieldFocused && field.IsEffectivelyVisible) field.Focus();
        }, DispatcherPriority.Input);
    }

    /// <summary>What changed since the last render, and the bookkeeping for the next one.</summary>
    sealed class Moves(LearnScreen s)
    {
        public readonly bool First = !s._rendered;
        public readonly bool NewQuestion = s.S.Question?.Qid != s._shownQid && s.S.Question is not null;
        public readonly bool PhaseChanged = s._shownPhase != s.S.Phase;
        public readonly bool NewStep = s.S.Transitions != s._shownTransitions;
        public readonly bool Rejected = s.S.Rejections > s._shownRejections;
        public readonly bool StreakGrew = s._c.Streak.Current > s._shownStreak;
        /// <summary>The card on screen was just starred or unstarred (the star bounces).</summary>
        public readonly bool StarToggled = s.S.Question is { } q && q.Qid == s._shownQid && s._shownStarred is { } was && was != q.Starred;
        public ChoiceTileState[] Tiles = [];

        public void Remember()
        {
            s._rendered = true;
            s._shownQid = s.S.Question?.Qid;
            s._shownPhase = s.S.Phase;
            s._shownTransitions = s.S.Transitions;
            s._shownRejections = s.S.Rejections;
            s._shownStreak = s._c.Streak.Current;
            s._shownTiles = Tiles;
            s._shownStarred = s.S.Question?.Starred;
        }
    }

    void FocusAfterRender(bool newStep)
    {
        var phase = S.Phase;
        Dispatcher.UIThread.Post(() =>
        {
            if (S.Prompt is not null || S.Overlay is not null || _editing is not null) return;
            if (phase == Phase.Written)
            {
                if (newStep && _answer.Text != S.Draft)
                {
                    _answer.Text = S.Draft;
                    _answer.CaretIndex = _answer.Text?.Length ?? 0;
                }
                _answer.Focus();
            }
            else if (phase == Phase.Copy)
            {
                if (newStep) _copy.Text = "";
                _copy.Focus();
            }
            else if (newStep) _focusSink.Focus();
        }, DispatcherPriority.Input);
    }

    // MARK: Top row

    /// <summary>"‹ Lernset", "Runde 2" with the progress capsule (Mac: LearnToolbarProgress), Optionen and Neu starten.</summary>
    Control TopRow()
    {
        var set = Model.Set(_c.SetId);
        Control? center = null;
        if (S.Session is not null)
        {
            var counts = S.Counts;
            _capsule.Update(counts.Fresh, counts.Learning, counts.Mastered);
            _capsule.Compact = _compact;
            _roundText.Text = L($"Runde {S.Round}");
            var capsule = Ui.Glass(Ui.H(_compact ? 10 : 16, _roundText, _capsule), 999, new Thickness(_compact ? 14 : 18, 0), strong: true, shadow: false);
            capsule.Height = 40;
            // Phone: three coloured numbers without words – a tap says what they count (06.11.2026).
            if (AppDevice.IsPhone)
                capsule.Tapped += (_, _) => Model.ShowToast(new ToastMessage(L($"Runde {S.Round}: {counts.Fresh} neu · {counts.Learning} am Lernen · {counts.Mastered} gemeistert")));
            center = capsule;
        }
        bool finished = S.Phase == Phase.Finished;
        var options = Ui.IconButton(IconName.Sliders, L("Optionen (Ctrl+K)"), OpenOptions);
        options.IsEnabled = CanShowOptions;
        var restart = Ui.IconButton(IconName.RotateCcw, finished ? L("Nochmal lernen (Ctrl+Shift+R)") : L("Neu starten (Ctrl+Shift+R)"),
            () => _c.Send(finished ? new LearnFlow.Event.Relearn() : new LearnFlow.Event.Restart()));
        restart.IsEnabled = CanRestart;
        foreach (var b in new[] { options, restart }) b.Focusable = false;
        return StudyChrome.TopRow(StudyChrome.BackPill(set?.Title ?? S.SetTitle, () => _c.Send(new LearnFlow.Event.Exit())), center, Ui.H(8, options, restart));
    }

    /// <summary>The options apply to sessions: also on the checkpoint and the finish, not on the message screens (Mac: canShowOptions).</summary>
    bool CanShowOptions => S.Prompt is null && S.Phase.Kind is not (PhaseKind.AllMastered or PhaseKind.Empty);

    /// <summary>"Neu starten" / "Nochmal lernen" (Mac: enabledCommands .restart): everywhere but the empty screen.</summary>
    bool CanRestart => S.Phase.Kind is not PhaseKind.Empty;

    // MARK: Question

    /// <summary>The question sits a little below the top row in tall windows and close to it in short ones.</summary>
    double TopInset => AppDevice.IsPhone ? 14 : Math.Max(20, Math.Min(112, (Window.StudyArea.Height - 40 - 52 - 560) / 2));

    bool _introShown;

    Control QuestionColumn(Moves motion)
    {
        var q = S.Question!;
        var column = new StackPanel { Spacing = 20, Width = 760, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, TopInset, 0, 24) };
        // The hint stays through the answer's feedback: gone with each feedback and back with the next question, it made
        // the card and the answers jump up and down at every question (Joan's phone, 06.11.2026).
        bool intro = !Model.Preferences.LearnIntroHintDismissed
            && (S.ShowsIntroHint || (_introShown && S.IsStudyStep && S.Session is { Rounds.Count: 0 }));
        _introShown = intro;
        if (intro) column.Children.Add(IntroHint());
        column.Children.Add(PromptCard(q, motion));
        if (q.Type == QuestionType.Mc)
        {
            var tiles = Tiles(q, motion);
            column.Children.Add(tiles);
            if (motion.First) Effects.EntranceShift(tiles, y: StudyEntrance.TileShift);
            else if (motion.NewQuestion)
            {
                // New tiles rise into place a moment after the old ones are gone.
                if (Motion.ReduceMotion) Effects.AnswerSwapIn(tiles);
                else Effects.Of(tiles).Enter(new Placement(Y: StudyEntrance.TileShift, Opacity: 0), Motion.Gentle.Delayed(0.06));
            }
            if (TypeAheadHint(q, motion) is { } hint) column.Children.Add(hint);
        }
        return column;
    }

    /// <summary>"Neue Begriffe kommen zuerst als Multiple Choice …" until the first checkpoint, closable.</summary>
    Control IntroHint()
    {
        var close = Ui.IconButton(IconName.X, L("Hinweis schliessen"), () =>
        {
            Model.Preferences.LearnIntroHintDismissed = true;
            Render();
        }, 22, ButtonKind.Plain);
        close.Focusable = false;
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 12 };
        row.Children.Add(Icons.Icon(IconName.Sparkles, 15, P.AccentText, 2));
        var text = Ui.Text(LearnFlow.INTRO_HINT, 13.5, color: P.Text, wrap: TextWrapping.Wrap);
        text.Opacity = 0.85;
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        Grid.SetColumn(close, 2);
        row.Children.Add(close);
        return new Border { Child = row, Background = WsTheme.B(P.AccentSoft), CornerRadius = new CornerRadius(999), Padding = new Thickness(16, 7, 8, 7) };
    }

    /// <summary>The study card (Mac: LearnPromptCard): the prompt's language, the tools, the prompt, the written answer area.</summary>
    Control PromptCard(LearnFlow.QuestionInfo q, Moves motion)
    {
        var header = Ui.Row(
            Ui.H(10, Ui.Eyebrow(q.PromptLabel, P.TextSecondary), q.IsReview ? ReviewChip() : q.IsRecheck ? RecheckChip() : null),
            Tools(q, motion), 12);
        var (promptSize, promptText) = StudyText.FitPrompt(q.Prompt, q.PromptLang, PromptSize(q.Prompt), FontWeight.Bold);
        var prompt = StudyText.InLang(promptText, q.PromptLang, promptSize, FontWeight.Bold, font: WsTheme.Prompt, hyphenate: false);
        prompt.LetterSpacing = -0.3;
        AutomationProperties.SetName(prompt, $"{q.PromptLabel}: {q.Prompt}");
        AutomationProperties.SetHeadingLevel(prompt, 1);
        if (motion.First) Effects.EntranceShift(prompt, x: StudyEntrance.PromptShift);
        else if (motion.NewQuestion) Effects.PromptSwapIn(prompt);
        var body = new StackPanel { Spacing = 16 };
        body.Children.Add(header);
        prompt.Margin = new Thickness(0, 0, 0, 4);
        body.Children.Add(prompt);
        if (q.Type == QuestionType.Written && WrittenSection(q, motion) is { } written) body.Children.Add(written);
        return Ui.Hero(body, new Thickness(28));
    }

    /// <summary>The prompt's size (Mac: Typography.prompt(for:)): short words large, sentences smaller.</summary>
    static double PromptSize(string text) => text.Length switch { < 28 => 40, < 70 => 32, _ => 25 };

    Control ReviewChip()
    {
        var chip = Ui.Chip(LearnFlow.REVIEW_LABEL, P.Mastered, IconName.RotateCcw);
        ToolTip.SetTip(chip, L("Diesen Begriff hast du schon gemeistert. Ist deine Antwort falsch, ist er wieder am Lernen."));
        AutomationProperties.SetName(chip, L("Wiederholungsfrage"));
        return chip;
    }

    /// <summary>"Nachkontrolle": a card missed earlier in the session comes back once more (Mac: LearnRecheckChip).</summary>
    Control RecheckChip()
    {
        var chip = Ui.Chip(LearnFlow.RECHECK_LABEL, P.Learning, IconName.Repeat);
        ToolTip.SetTip(chip, LearnFlow.RECHECK_HELP);
        AutomationProperties.SetName(chip, LearnFlow.RECHECK_LABEL);
        return chip;
    }

    /// <summary>
    /// 🔊 (Ctrl+R), ★ (Ctrl+D), ✎ (Ctrl+E) in the card's corner (Mac: LearnIconButton). The speaker moves while
    /// something is read aloud, the star bounces when it is toggled.
    /// </summary>
    Control Tools(LearnFlow.QuestionInfo q, Moves motion)
    {
        var speak = Ui.IconButton(IconName.Speaker, L("Vorlesen (Ctrl+R)"), () => _c.Send(new LearnFlow.Event.SpeakPrompt()), 32, ButtonKind.Plain);
        var star = Ui.IconButton(q.Starred ? IconName.StarFilled : IconName.Star, q.Starred ? L("Markierung entfernen (Ctrl+D)") : L("Markieren (Ctrl+D)"),
            () => _c.Send(new LearnFlow.Event.ToggleStar()), 32, ButtonKind.Plain, q.Starred ? P.Star : null);
        var edit = Ui.IconButton(IconName.Pencil, L("Karte bearbeiten (Ctrl+E)"), EditCurrentCard, 32, ButtonKind.Plain);
        foreach (var b in new[] { speak, star, edit }) b.Focusable = false;
        if (speak.Chrome.Child is { } speakerIcon) _speaking.Attach(speakerIcon);
        if (motion.StarToggled && star.Chrome.Child is { } starIcon) Effects.Pop(starIcon, 1.3);
        return Ui.H(4, speak, star, edit);
    }

    Control Tiles(LearnFlow.QuestionInfo q, Moves motion)
    {
        var typeAhead = LearnFlow.TypeAheadOf(S);
        var tiles = new List<Control>();
        var states = new ChoiceTileState[q.Choices.Count];
        for (int i = 0; i < q.Choices.Count; i++)
        {
            int index = i;
            states[i] = ChoiceTile.From(LearnFlow.OptionStateOf(S, i));
            ChoiceTileState? before = !motion.NewQuestion && i < _shownTiles.Length ? _shownTiles[i] : null;
            tiles.Add(ChoiceTile.Create(i + 1, q.Choices[i].Text, states[i], typeAhead.Ranges.TryGetValue(i, out var r) ? r : null, q.AnswerLang,
                () => _c.Send(new LearnFlow.Event.Choose(index)),
                () =>
                {
                    if (S.Phase == Phase.Mc && S.Typed.Length == 0 && S.Highlighted != index) _c.Send(new LearnFlow.Event.Highlight(index));
                }, before));
        }
        motion.Tiles = states;
        var grid = ChoiceTile.Grid(tiles);
        AutomationProperties.SetName(grid, StudyText.AnswersNoun);
        return grid;
    }

    /// <summary>
    /// Below the tiles while letters are typed (Mac: LearnTypeAheadHint): the letters, what Enter does with them and how
    /// to correct them. Shakes when Enter finds no answer to choose.
    /// </summary>
    Control? TypeAheadHint(LearnFlow.QuestionInfo q, Moves motion)
    {
        if (S.Phase != Phase.Mc || S.Typed.Length == 0) return null;
        var match = LearnFlow.TypeAheadOf(S);
        var typed = StudyText.InLang(S.Typed, q.AnswerLang, 14, FontWeight.SemiBold, match.Matching.Count == 0 ? P.Failure.Text : P.Text);
        // One line; long letters lose their beginning, so the last typed ones stay visible (Mac: truncationMode(.head)).
        typed.TextWrapping = TextWrapping.NoWrap;
        typed.TextTrimming = TextTrimming.LeadingCharacterEllipsis;
        typed.MaxWidth = 220;
        var row = Ui.H(12, Icons.Icon(IconName.Keyboard, 17, P.TextSecondary), typed);
        if (match.Selected is { } selected && selected < q.Choices.Count)
        {
            row.Children.Add(Ui.KeyCap("↵"));
            var picks = Ui.Text(L($"wählt «{q.Choices[selected].Text}»"), 14, color: P.TextSecondary);
            picks.TextWrapping = TextWrapping.NoWrap;
            picks.TextTrimming = TextTrimming.CharacterEllipsis;
            picks.MaxWidth = 300;
            row.Children.Add(picks);
        }
        else row.Children.Add(Ui.Text(match.Matching.Count == 0 ? L("Keine Antwort passt") : L("Weiter tippen …"), 14, color: P.TextSecondary));
        row.Children.Add(Ui.Text(L("Rücktaste korrigiert · Esc löscht"), 12, color: P.TextTertiary));
        var hint = new Border
        {
            Child = row,
            Background = WsTheme.B(P.Dark ? Palette.Hex(0xFFFFFF, 0.08) : Palette.Hex(0x101828, 0.05)),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(16, 8),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        if (motion.Rejected) Effects.Shake(hint, 6);
        return hint;
    }

    /// <summary>
    /// The written answer area (Mac: LearnWrittenSection): the field while asking; after a correct answer the same box
    /// turns green with what was typed; after a miss "Deine Antwort" (with the diff), "Richtige Antwort" with 🔊, the copy
    /// field and "Bearbeiten".
    /// </summary>
    Control? WrittenSection(LearnFlow.QuestionInfo q, Moves motion)
    {
        var f = S.Feedback;
        // Phone: "Auf Französisch …" – the long hint does not fit the field at its size.
        _answer.PlaceholderText = AppDevice.IsPhone ? q.PlaceholderShort : q.Placeholder;
        _answer.FlowDirection = q.AnswerLang.IsRTL() ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        _copy.FlowDirection = _answer.FlowDirection;
        StudyAnswerBox.ForAnswers(_answer, q.AnswerLang);
        StudyAnswerBox.ForAnswers(_copy, q.AnswerLang);
        if (S.Phase == Phase.Written || S.Phase == Phase.FeedbackOf(LearnFlow.FeedbackKind.Correct))
        {
            bool correct = S.Phase != Phase.Written && f is not null;
            var box = StudyAnswerBox.Create(correct ? null : _answer, correct ? f!.Given : null, q.AnswerLang, isActive: !correct, isInvalid: false,
                shake: motion.Rejected && !correct, accepted: correct && motion.PhaseChanged);
            // While asking: the accent buttons of the answer language below the box (Mac: SpecialCharacterBar).
            if (!correct) return SpecialCharacterBar.Create(q.AnswerLang, _answer) is { } accents ? Ui.V(10, box, accents) : box;
            if (f is null || CorrectDetails(f, q) is not { } details) return box;
            if (motion.PhaseChanged) Effects.AnswerSwapIn(details);
            return Ui.V(12, box, details);
        }
        if (f is null) return null;
        var parts = new StackPanel { Spacing = 16, Margin = new Thickness(0, 4, 0, 0) };
        if (f.Kind == LearnFlow.FeedbackKind.Wrong && LearnFlow.HasText(f.Given))
            parts.Children.Add(FeedbackRow(L("Deine Antwort"), f.Hint is { } hint && !f.EditedCorrect ? Ui.Chip(hint, P.Warning, IconName.Lightbulb) : null,
                StudyText.Diff(f.Given, q.Expected, q.AnswerLang, 22)));
        var speak = Ui.IconButton(IconName.Speaker, L("Antwort vorlesen"), () => _c.Speak(q.Expected, q.AnswerLang), 32, ButtonKind.Plain);
        speak.Focusable = false;
        parts.Children.Add(FeedbackRow(L("Richtige Antwort"), null,
            Ui.H(8, StudyText.InLang(q.Expected, q.AnswerLang, 22, FontWeight.Medium, P.Success.Text), speak)));
        if (f.EditedCorrect) parts.Children.Add(Ui.H(8, StudyStatusPill.FeedbackSymbol(StudyStatus.Kinds.Correct, P.Success.Fill, 16), Ui.Text(LearnFlow.EDITED_CORRECT_TEXT, 14, FontWeight.Medium, P.Success.Text)));
        if (S.Phase == Phase.Copy)
        {
            parts.Children.Add(StudyAnswerBox.Create(_copy, null, q.AnswerLang, isActive: true, isInvalid: S.Rejections > 0, shake: motion.Rejected, accepted: false));
            if (SpecialCharacterBar.Create(q.AnswerLang, _copy) is { } accents) parts.Children.Add(accents);
        }
        var edit = Ui.Secondary(L("Bearbeiten"), EditCurrentCard, IconName.Pencil, "Ctrl E", 34);
        edit.Focusable = false;
        parts.Children.Add(edit);
        if (motion.PhaseChanged && S.Phase != Phase.Copy) Effects.AnswerSwapIn(parts);
        return parts;
    }

    /// <summary>Below a correct written answer: "Genau: …" / "Gesucht war: …" and the tolerance notes (Mac: LearnCorrectDetails).</summary>
    static Control? CorrectDetails(LearnFlow.Feedback f, LearnFlow.QuestionInfo q)
    {
        var parts = Ui.V(8);
        if (f.ExactLabel is { } label && f.Result is { } r && r.ExpectedDisplay.Length > 0)
            parts.Children.Add(Ui.H(6, Ui.Text(label, 17, color: P.TextSecondary), StudyText.InLang(r.ExpectedDisplay, q.AnswerLang, 17, FontWeight.SemiBold)));
        if (f.Result is { } res)
        {
            var notes = new WrapPanel { ItemSpacing = 6, LineSpacing = 6 };
            foreach (var note in res.Notes)
                if (Labels.NOTE_LABELS.TryGetValue(note, out var text))
                    notes.Children.Add(StudyChrome.NoteChip(text));
            if (notes.Children.Count > 0) parts.Children.Add(notes);
        }
        return parts.Children.Count > 0 ? parts : null;
    }

    /// <summary>A labelled block of the miss details ("DEINE ANTWORT", "RICHTIGE ANTWORT"; Mac: StudyFeedbackRow).</summary>
    static Control FeedbackRow(string title, Control? accessory, Control content) => Ui.V(6, Ui.H(8, Ui.Eyebrow(title, P.TextSecondary), accessory), content);

    // MARK: Checkpoint, finish, messages

    /// <summary>
    /// "Runde N geschafft" (Mac: LearnCheckpointView): the round's verdict, the overall progress on a glass card (the
    /// segmented bar grows from where the round started), the counts and the round's cards with their answers.
    /// </summary>
    Control CheckpointView(Moves motion)
    {
        var cp = S.Checkpoint!;
        double ratio = cp.Answered == 0 ? 0 : (double)cp.Correct / cp.Answered;
        var c = cp.Counts;
        var eyebrow = Ui.Eyebrow(L($"Runde {cp.Round} geschafft"), P.TextSecondary);
        var title = Ui.Text(LearnFlow.CheckpointTitle(ratio), 34, FontWeight.Bold, wrap: TextWrapping.Wrap, font: WsTheme.Prompt, align: TextAlignment.Center);
        var text = Ui.Text(LearnFlow.CheckpointText(cp), 18, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        foreach (var t in new Control[] { eyebrow, title, text }) t.HorizontalAlignment = HorizontalAlignment.Center;
        var head = Ui.V(8, eyebrow, title, text);

        var from = S.RoundStartCounts;
        bool grows = motion.PhaseChanged && from is not null && !Motion.ReduceMotion;
        var bar = grows
            ? new SegmentedBar(from!.Mastered, from.Learning, c.Total, S.Segments)
            : new SegmentedBar(c.Mastered, c.Learning, c.Total, S.Segments);
        if (grows) bar.Grow(c.Mastered, c.Learning);
        var percent = Ui.Text(WriteFlow.PercentText(c.Total > 0 ? (double)c.Mastered / c.Total : 0), 22, FontWeight.Bold, c.Mastered > 0 ? P.Mastered.Text : P.TextSecondary, font: WsTheme.Prompt);
        var legend = Ui.H(20, Legend(P.New.Fill, L("Neu"), c.Fresh), Legend(P.Learning.Fill, L("Am Lernen"), c.Learning), Legend(P.Mastered.Fill, L("Gemeistert"), c.Mastered));
        var progress = Ui.V(16, Ui.Row(Ui.Text(LearnFlow.MasteredLine(c.Mastered, c.Total), 17, FontWeight.Bold, font: WsTheme.Prompt), percent), bar, legend);
        AutomationProperties.SetName(progress, L($"Gesamtfortschritt: {LearnFlow.ProgressText(c.Fresh, c.Learning, c.Mastered, c.Total)}"));
        var card = Ui.Hero(progress, new Thickness(24), 22);

        var cards = LearnFlow.CardsById(S.Cards);
        var rows = cp.Items.Where(i => cards.ContainsKey(i.CardId)).Select(i =>
        {
            var item = cards[i.CardId];
            var status = LearnFlow.CheckpointStatus(i.Stage);
            var dots = Ui.H(3, i.Results.Select(ok => (Control?)new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = WsTheme.B(ok ? P.Success.Fill : P.Failure.Fill) }).ToArray());
            dots.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetName(dots, L($"Antworten: {string.Join(", ", i.Results.Select(ok => ok ? L("richtig") : L("falsch")))}"));
            return new StudyChrome.TermRow(item.Term, item.Definition, S.TermLang, S.DefLang, Trailing: Ui.H(12, dots, Ui.Chip(status.Label, P.Status(status.Status))));
        }).ToList();
        var stack = Ui.V(24, head, card, rows.Count > 0 ? StudyChrome.TermList(L("In dieser Runde"), rows) : null);
        stack.Width = 760;
        stack.Margin = new Thickness(0, 24, 0, 24);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        return stack;
    }

    static Control Legend(Color color, string label, int value) => Ui.H(6,
        new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = WsTheme.B(color), VerticalAlignment = VerticalAlignment.Center },
        Ui.Text(label, 13.5, color: P.TextSecondary), Ui.Text($"{value}", 13.5, FontWeight.Bold));

    /// <summary>The end of a session (Mac: LearnFinishView): the trophy, the title, the statistics, with confetti.</summary>
    Control FinishView(bool appeared)
    {
        var stats = S.FinalStats!;
        var subset = S.Session?.Subset ?? S.Subset;
        var circle = new Border { Width = 92, Height = 92, CornerRadius = new CornerRadius(46), Background = ProgressLine.Gradient(P.Accent), BoxShadow = BoxShadows.Parse($"0 6 32 0 {WsButton.Hex(P.Accent, 0.35)}") };
        var trophy = Icons.Icon(IconName.Trophy, 40, Colors.White, 2.2);
        trophy.HorizontalAlignment = HorizontalAlignment.Center;
        trophy.VerticalAlignment = VerticalAlignment.Center;
        circle.Child = trophy;
        circle.HorizontalAlignment = HorizontalAlignment.Center;
        circle.Margin = new Thickness(0, 0, 0, 8);
        if (appeared) Effects.Pop(trophy, 1.22);
        var title = Ui.Text(LearnFlow.FinishTitle(subset, stats.Total), 34, FontWeight.Bold, wrap: TextWrapping.Wrap, font: WsTheme.Prompt, align: TextAlignment.Center);
        var subtitle = Ui.Text(LearnFlow.FinishSubtitle(stats, subset), 18, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        title.HorizontalAlignment = subtitle.HorizontalAlignment = HorizontalAlignment.Center;
        var time = WriteFlow.CompactDurationOf(stats.ElapsedMs);
        var tiles = StatTile.Row(12,
            StatTile.Create(stats.Total == 1 ? L("Begriff") : L("Begriffe"), $"{stats.Total}", IconName.Stack, P.Accent),
            StatTile.Create(stats.Rounds == 1 ? L("Runde") : L("Runden"), $"{stats.Rounds}", IconName.Repeat, P.Info.Fill),
            StatTile.Create(stats.Answered == 1 ? L("Antwort") : StudyText.AnswersNoun, $"{stats.Answered}", IconName.Book, P.Learning.Fill),
            StatTile.Create(L("Treffer"), WriteFlow.PercentText(stats.Accuracy), IconName.Target, P.Success.Fill),
            TimeTile(time.Label, time.Value, stats.ElapsedMs));
        var stack = Ui.V(24, Ui.V(12, circle, title, subtitle), tiles);
        if (_c.BestStreak >= AnswerStreak.VisibleFrom)
            stack.Children.Add(Capsule(IconName.Flame, L($"Beste Serie: {_c.BestStreak} richtig in Folge"), P.Flame, Palette.Hex(Ui.Rgb(P.Flame), 0.12)));
        if (S.Session is { } session && LearnEngine.ReviewStatsOf(session) is { } rs && LearnFlow.ReviewLine(rs) is { } line)
            stack.Children.Add(Capsule(IconName.RotateCcw, line, P.Mastered.Text, P.Mastered.Soft));
        var cards = LearnFlow.CardsById(S.Cards);
        var hardest = stats.Hardest.Where(h => cards.ContainsKey(h.CardId)).ToList();
        if (hardest.Count == 0)
        {
            var none = Ui.H(8, Icons.Icon(IconName.Sparkles, 18, P.AccentText, 2), Ui.Text(L("Kein einziger Fehler – beeindruckend!"), 17, FontWeight.Medium, P.AccentText));
            none.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(none);
        }
        else stack.Children.Add(StudyChrome.TermList(L("Am häufigsten falsch"), hardest.Select(h =>
            new StudyChrome.TermRow(cards[h.CardId].Term, cards[h.CardId].Definition, S.TermLang, S.DefLang,
                Trailing: Ui.H(10, Ui.Chip(L($"{h.Misses}× falsch"), P.Failure), StudyChrome.StarToggle(Model, _c.SetId, h.CardId))))));
        stack.Width = 760;
        stack.Margin = new Thickness(0, 24, 0, 24);
        var layer = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        layer.Children.Add(stack);
        // Confetti when the finish appears, not again when the screen is rebuilt.
        layer.Children.Add(new CelebrationView { Origin = new Point(0.5, 0.1), PlaysOnAttach = appeared });
        return layer;
    }

    /// <summary>The study time tile; a screen reader says "Zeit" and the whole duration (Mac: accessibilityLabel "Zeit").</summary>
    internal static Control TimeTile(string label, string value, double elapsedMs, string? caption = null)
    {
        var tile = StatTile.Create(label, value, IconName.Clock, P.Flame, caption: caption);
        AutomationProperties.SetName(tile, L($"Zeit: {TimeUtil.FormatDuration(elapsedMs)}"));
        return tile;
    }

    static Control Capsule(IconName icon, string text, Color color, Color background) => new Border
    {
        Child = Ui.H(8, Icons.Icon(icon, 17, color, 2), Ui.Text(text, 16, FontWeight.Medium, color, TextWrapping.Wrap)),
        Background = WsTheme.B(background),
        CornerRadius = new CornerRadius(999),
        Padding = new Thickness(16, 8),
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    /// <summary>Everything mastered, nothing to study (Mac: LearnMessageView): an empty state with its own buttons.</summary>
    Control MessageView()
    {
        if (LearnFlow.MessageOf(S) is not { } m) return new Border();
        var actions = new List<Control>
        {
            Ui.Secondary(L("Zurück zum Lernset"), () => _c.Send(new LearnFlow.Event.Exit()), keyHint: "Esc", height: 44),
        };
        if (m.OffersWrite) actions.Add(Ui.Secondary(L("Schreiben üben"), () => Model.Study(_c.SetId, StudyMode.Write, forceNew: true), IconName.Keyboard, height: 44));
        if (m.OffersReview)
        {
            var review = Ui.Secondary(L("Alle wiederholen"), () => _c.Send(new LearnFlow.Event.StartReview()), IconName.RotateCcw, height: 44);
            ToolTip.SetTip(review, L("Jeden gemeisterten Begriff einmal abfragen. Was falsch ist, lernst du neu."));
            actions.Add(review);
        }
        actions.Add(Ui.Primary(m.PrimaryLabel, () => _c.Send(new LearnFlow.Event.Proceed())));
        var view = EmptyStateView.Create(Icons.ForSymbol(m.SystemImage), m.Title, m.Text, actions.ToArray());
        view.Margin = AppDevice.IsPhone ? new Thickness(20, 40, 20, 24) : new Thickness(32, 80, 32, 32);
        return view;
    }

    // MARK: Action bar and overlays

    /// <summary>The pill for the state (Mac: LearnStatus.init), with the streak.</summary>
    StudyStatus? Status()
    {
        var f = S.Feedback;
        int streak = _c.Streak.Current;
        string? Demoted(LearnFlow.Feedback fb) => fb.Demoted ? LearnFlow.DEMOTED_TEXT : null;
        switch (S.Phase.Kind)
        {
            case PhaseKind.Question:
                return S.Phase == Phase.Mc
                    ? new StudyStatus(StudyStatus.Kinds.Keys, Choices: S.Question?.Choices.Count ?? 4, Streak: streak)
                    : new StudyStatus(StudyStatus.Kinds.Typing, Streak: streak);
            case PhaseKind.Feedback when f is not null:
                return S.Phase.FeedbackKind switch
                {
                    LearnFlow.FeedbackKind.Correct => new StudyStatus(StudyStatus.Kinds.Correct, f.Title, Streak: streak),
                    LearnFlow.FeedbackKind.Wrong => new StudyStatus(StudyStatus.Kinds.Wrong, f.Title, Demoted(f), Streak: streak),
                    _ => new StudyStatus(StudyStatus.Kinds.DontKnow, f.Title, Demoted(f), Streak: streak),
                };
            case PhaseKind.Copy when f is not null:
                // One whole text with the demotion and without it (Mac: LearnStatus).
                return new StudyStatus(f.Kind == LearnFlow.FeedbackKind.DontKnow ? StudyStatus.Kinds.DontKnow : StudyStatus.Kinds.Wrong, f.Title,
                    Demoted(f) is { } d ? L($"{d}. Tippe die richtige Antwort ab.") : L("Tippe die richtige Antwort ab."), Streak: streak);
            default:
                return null;
        }
    }

    /// <summary>The floating bar (Mac: LearnActionBar): status pill, the step's other actions, the Enter action.</summary>
    Control ActionBar(Moves motion)
    {
        var f = S.Feedback;
        var trailing = new List<Control?>();
        switch (S.Phase.Kind)
        {
            case PhaseKind.Question:
                trailing.Add(Ui.Secondary(L("Weiss ich nicht?"), () => _c.Send(new LearnFlow.Event.DontKnow()), keyHint: "Alt ↵", height: 44));
                break;
            case PhaseKind.Feedback or PhaseKind.Copy when f is not null && (S.Phase.FeedbackKind == LearnFlow.FeedbackKind.Wrong || S.Phase == Phase.Copy):
                if (LearnFlow.OverrideLabel(S) is { } over)
                {
                    var b = Ui.Secondary(over, () => _c.Send(new LearnFlow.Event.Override()), IconName.Check, "Ctrl ↵", 44);
                    trailing.Add(b);
                }
                break;
            case PhaseKind.Checkpoint:
                trailing.Add(Ui.Secondary(L("Zurück zum Lernset"), () => _c.Send(new LearnFlow.Event.Exit()), keyHint: "Esc", height: 44));
                break;
            case PhaseKind.Finished:
                trailing.Add(Ui.Secondary(L("Schreiben üben"), () => Model.Study(_c.SetId, StudyMode.Write, forceNew: true), IconName.Keyboard, height: 44));
                trailing.Add(Ui.Secondary(L("Nochmal lernen"), () => _c.Send(new LearnFlow.Event.Relearn()), IconName.RotateCcw, "Ctrl Shift R", 44));
                break;
        }
        if (LearnFlow.ReturnAction(S) is { } label) trailing.Add(Ui.Primary(label, () => _c.Send(new LearnFlow.Event.Proceed()), "↵", height: 44));
        Control? pill = null;
        if (Status() is { } status)
        {
            // Not for the short beat after a copy is typed out (CopyStep): there it would only flicker.
            var countdown = _c.Countdown is { } cd && cd.Token == S.AutoAdvanceToken && S.Phase != Phase.Copy ? cd : null;
            pill = StudyStatusPill.Create(status, countdown, motion.NewStep, motion.StreakGrew);
        }
        return StudyActionBarView.Create(pill, trailing);
    }

    Control? OverlayLayer()
    {
        if (LearnFlow.PromptContentOf(S) is { } pc)
            return StudyChrome.Overlay(StudyChrome.PromptCard(pc.Title, pc.Message, pc.ConfirmLabel, pc.CancelLabel, pc.IsDestructive,
                ok => _c.Send(new LearnFlow.Event.PromptAnswered(ok))), () => _c.Send(new LearnFlow.Event.PromptAnswered(false)));
        if (S.Overlay == LearnFlow.Overlay.Options)
            return StudyChrome.Overlay(StudyChrome.OptionsPanel(Model, _c.SetId, StudyMode.Learn,
                options =>
                {
                    _c.Send(new LearnFlow.Event.OptionsChanged(options));
                    // Wiederholungsfragen and Nachkontrolle apply at once (also while the options are open).
                    _c.SwitchesMayHaveChanged();
                },
                () => _c.Send(new LearnFlow.Event.OverlayDismissed()),
                () =>
                {
                    _c.Send(new LearnFlow.Event.OverlayDismissed());
                    _c.Send(new LearnFlow.Event.Restart());
                }, runningNote: LearnFlow.RunningSettingsNote(S)), () => _c.Send(new LearnFlow.Event.OverlayDismissed()));
        if (_editing is { } card && Model.Set(_c.SetId) is { } set)
        {
            var editor = StudyChrome.CardEditor(set, card, (term, definition) =>
            {
                CloseEditor();
                _c.Send(new LearnFlow.Event.EditCard(card with { Term = term, Definition = definition }));
            }, CloseEditor, out var save);
            _editorSave = save;
            return StudyChrome.Overlay(editor, CloseEditor);
        }
        return null;
    }

    void OpenOptions()
    {
        if (S.Overlay is null && _editing is null && CanShowOptions) _c.Send(new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options));
    }

    /// <summary>"Optionen" in the hint at the first recheck: the options, scrolled to "Nachkontrolle nach Fehlern".</summary>
    void OpenOptionsAtRecheck()
    {
        OpenOptions();
        if (S.Overlay == LearnFlow.Overlay.Options) RevealOption(StudyChrome.RecheckOptionClass);
    }

    /// <summary>Scrolls the open options to the row with style class <paramref name="cls"/> (StudyChrome.*OptionClass).</summary>
    public void RevealOption(string cls) => Dispatcher.UIThread.Post(() =>
    {
        if (View.GetVisualDescendants().OfType<Control>().FirstOrDefault(c => c.Classes.Contains(cls)) is { } row)
            row.BringIntoView(new Rect(0, -24, row.Bounds.Width, row.Bounds.Height + 72));
    }, DispatcherPriority.Loaded);

    /// <summary>✎ (Ctrl+E): the card editor for the current question's card (Mac: LearnCardEditor).</summary>
    void EditCurrentCard()
    {
        if (S.Overlay is not null || S.Prompt is not null || _editing is not null || _c.CurrentCard is not { } card) return;
        _editing = card;
        Render();
    }

    void CloseEditor()
    {
        _editing = null;
        _editorSave = null;
        Render();
    }

    // MARK: Keys

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        var mods = e.KeyModifiers;
        _textKeyRepeats = isRepeat;
        // Enter/Esc that pick or cancel a Pinyin candidate, a dead key: the composition's, not the screen's.
        if (StudyInput.IsComposing(e, TopLevel.GetTopLevel(Window))) return false;
        if (_editing is not null)
        {
            if (e.Key == Key.Escape) CloseEditor();
            else if (e.Key is Key.Enter or Key.Return && !isRepeat) _editorSave?.Invoke();
            else return false;
            return true;
        }
        if (S.Prompt is not null)
        {
            if (isRepeat) return true;
            if (e.Key is Key.Enter or Key.Return) _c.Send(new LearnFlow.Event.PromptAnswered(!(LearnFlow.PromptContentOf(S)?.IsDestructive ?? false)));
            else if (e.Key == Key.Escape) _c.Send(new LearnFlow.Event.PromptAnswered(false));
            return true;
        }
        if (S.Overlay is not null)
        {
            if (e.Key != Key.Escape) return false;
            _c.Send(new LearnFlow.Event.OverlayDismissed());
            return true;
        }
        // A held shortcut acts once (Mac: LearnController.handle ignores repeats of ⌘K, ⌘R, ⌘D, ⇧⌘R).
        if (mods == KeyModifiers.Control && e.Key is Key.R or Key.D or Key.K or Key.E)
        {
            if (isRepeat) return true;
            switch (e.Key)
            {
                case Key.R: _c.Send(new LearnFlow.Event.SpeakPrompt()); break;
                case Key.D: _c.Send(new LearnFlow.Event.ToggleStar()); break;
                case Key.K: OpenOptions(); break;
                default: EditCurrentCard(); break;
            }
            return true;
        }
        if (mods == (KeyModifiers.Control | KeyModifiers.Shift) && e.Key == Key.R)
        {
            if (!isRepeat && CanRestart) _c.Send(S.Phase == Phase.Finished ? new LearnFlow.Event.Relearn() : new LearnFlow.Event.Restart());
            return true;
        }
        bool inField = Window.TextFieldFocused;
        // Entf removes the last typed letter on multiple choice, like the Backspace key (Mac: fn-⌦).
        if (e.Key == Key.Delete && mods == KeyModifiers.None && !inField && S.Phase == Phase.Mc)
        {
            _c.Press(KeyInput.DeleteBackward, isRepeat);
            return true;
        }
        if (Translate(e) is not { } key) return false;
        if (inField && key.Kind is not (KeyKind.Return or KeyKind.OptionReturn or KeyKind.CommandReturn or KeyKind.Escape)) return false;
        _c.Press(key, isRepeat);
        return true;
    }

    public override bool HandleText(string text)
    {
        if (S.Prompt is not null || S.Overlay is not null || _editing is not null || Window.TextFieldFocused) return false;
        if (S.Phase == Phase.Written)
        {
            // Typing anywhere on a written question goes into the answer field.
            _answer.Text = (_answer.Text ?? "") + text;
            _answer.CaretIndex = _answer.Text.Length;
            _answer.Focus();
            return true;
        }
        // A held digit or letter chooses once (the reducer drops repeats); the repeat flag comes from its key down.
        bool repeat = _textKeyRepeats;
        _textKeyRepeats = false;
        _c.Press(TextKey(text), repeat);
        return true;
    }
}
