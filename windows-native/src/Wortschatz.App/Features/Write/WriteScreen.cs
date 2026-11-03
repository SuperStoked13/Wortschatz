using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Learn;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using Event = Wortschatz.Core.WriteFlow.Event;
using FK = Wortschatz.Core.WriteFlow.FeedbackKind;
using Phase = Wortschatz.Core.WriteFlow.Phase;
using PhaseKind = Wortschatz.Core.WriteFlow.PhaseKind;

namespace Wortschatz.App.Features.Write;

/// <summary>
/// Write mode, "Schreiben" (Mac: WriteScreen.swift, WriteStage.swift, WritePromptCard.swift, WriteActionBar.swift,
/// WriteSummaryView.swift, WriteResultsView.swift): every term is written; wrong ones come back in the next round until
/// all are right. Top: back pill, "Runde N" with Verbleibend · Falsch · Richtig and the progress line, Optionen and
/// Neu starten. The prompt card has the tools 🔊 ★ ✎ and the answer box; the floating action bar the status pill.
/// Like Lernen, the screen is rebuilt on every change and plays the Mac's motions by comparing with the last render.
/// </summary>
public sealed class WriteScreen : Screen
{
    readonly WriteController _c;
    readonly TextBox _field;
    readonly Border _focusSink = new() { Focusable = true, Width = 0, Height = 0 };
    readonly ProgressLine _line = new(0, WsTheme.P.Success.Fill, 88);
    bool _rendered;
    int _shownSerial = -1, _shownRejections, _shownStreak;
    Phase? _shownPhase;
    Action? _editorSave;

    public WriteScreen(AppModel model, MainWindow window, StudyRequest request) : base(model, window)
    {
        _c = new WriteController(model, request);
        _c.Changed += Render;
        _field = StudyAnswerBox.Field("Antwort eingeben");
        _field.TextChanged += (_, _) =>
        {
            if (_c.State.IsInputEditable && (_field.Text ?? "") != _c.State.Input) _c.Send(new Event.InputChanged(_field.Text ?? ""));
        };
    }

    public override bool UsesSidebar => false;
    public WriteController Controller => _c;
    WriteFlow.State S => _c.State;
    static Palette P => WsTheme.P;

    public override void Activate()
    {
        _c.Activate();
        Render();
        StudyEntrance.RevealScreen(View);
    }

    public override void Deactivate() => _c.Deactivate();
    public override void WindowActivityChanged(bool active) => _c.WindowActivityChanged(active);
    public override void Refresh() { }
    protected override Control Build() => new Border();

    static void Detach(Control c)
    {
        if (c.Parent is Panel panel) panel.Children.Remove(c);
        else if (c.Parent is Decorator d) d.Child = null;
        else if (c.Parent is ContentControl cc) cc.Content = null;
    }

    /// <summary>What changed since the last render (its changes play the motions).</summary>
    sealed class Moves(WriteScreen s)
    {
        public readonly bool First = !s._rendered;
        public readonly bool NewQuestion = s.S.QuestionSerial != s._shownSerial && s.S.Question is not null;
        public readonly bool PhaseChanged = s._shownPhase != s.S.Phase;
        public readonly bool Rejected = s.S.Rejections > s._shownRejections;
        public readonly bool StreakGrew = s._c.Streak.Current > s._shownStreak;

        public void Remember()
        {
            s._rendered = true;
            s._shownSerial = s.S.QuestionSerial;
            s._shownPhase = s.S.Phase;
            s._shownRejections = s.S.Rejections;
            s._shownStreak = s._c.Streak.Current;
        }
    }

    void Render()
    {
        foreach (var c in new Control[] { _field, _focusSink, _line }) Detach(c);
        var motion = new Moves(this);
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        root.Children.Add(TopRow());
        bool message = S.Phase.Kind is PhaseKind.Empty or PhaseKind.Missing;
        Control main = S.Phase.Kind switch
        {
            PhaseKind.Question or PhaseKind.Feedback or PhaseKind.Copy => Column(motion),
            PhaseKind.Summary => SummaryView(motion.PhaseChanged),
            PhaseKind.Results => ResultsView(motion.PhaseChanged),
            PhaseKind.Starting => new Border(),
            _ => MessageView(),
        };
        if (motion.PhaseChanged && S.Phase.Kind is PhaseKind.Summary or PhaseKind.Results or PhaseKind.Empty or PhaseKind.Missing)
            Effects.FadeIn(main, Motion.Soft(0.4));
        var stage = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
        stage.Children.Add(Ui.Scroll(main));
        if (!message && S.Phase.Kind != PhaseKind.Starting)
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
        ((ContentControl)View).Content = root;
        bool newStep = motion.NewQuestion || motion.PhaseChanged;
        motion.Remember();
        FocusAfterRender(newStep);
    }

    void FocusAfterRender(bool newStep)
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (S.IsBlocked) return;
            if (S.IsInputEditable)
            {
                if ((_field.Text ?? "") != S.Input)
                {
                    _field.Text = S.Input;
                    _field.CaretIndex = S.Input.Length;
                }
                _field.Focus();
            }
            else if (newStep) _focusSink.Focus();
        }, DispatcherPriority.Input);
    }

    // MARK: Top row

    /// <summary>"Runde 2", Verbleibend · Falsch · Richtig, the progress line and "5/12" (Mac: WriteToolbarProgress).</summary>
    Control TopRow()
    {
        Control? center = null;
        if (WriteFlow.CountersOf(S) is { } c)
        {
            _line.SetValue(c.Progress, Motion.Snappy);
            Control Counter(int value, string label, Color color) => Ui.H(5,
                new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = WsTheme.B(color), VerticalAlignment = VerticalAlignment.Center },
                Ui.Text($"{value}", 13.5, FontWeight.Bold), Ui.Text(label, 13.5, color: P.TextSecondary));
            var row = Ui.H(16, Ui.Text($"Runde {c.Round}", 14, FontWeight.SemiBold, P.TextSecondary),
                Ui.H(12, Counter(c.Remaining, "Verbleibend", P.New.Fill), Counter(c.Incorrect, "Falsch", P.Failure.Fill), Counter(c.Correct, "Richtig", P.Success.Fill)),
                _line, Ui.Text($"{c.Correct}/{c.Total}", 14, FontWeight.Medium, P.TextSecondary));
            _line.VerticalAlignment = VerticalAlignment.Center;
            var capsule = Ui.Glass(row, 999, new Thickness(18, 0), strong: true, shadow: false);
            capsule.Height = 40;
            AutomationProperties.SetName(capsule, WriteFlow.CountersAccessibilityLabel(c));
            ToolTip.SetTip(capsule, WriteFlow.CountersAccessibilityLabel(c));
            center = capsule;
        }
        bool results = S.Phase == Phase.Results;
        var options = Ui.IconButton(IconName.Sliders, "Optionen (Ctrl+K)", () => _c.Send(new Event.RequestOptions()));
        options.IsEnabled = S.Phase.IsCard;
        var restart = Ui.IconButton(IconName.RotateCcw, results ? "Nochmal von vorne (Ctrl+Shift+R)" : "Neu starten (Ctrl+Shift+R)", () => _c.Send(new Event.Restart()));
        restart.IsEnabled = S.Session is not null;
        foreach (var b in new[] { options, restart }) b.Focusable = false;
        return StudyChrome.TopRow(StudyChrome.BackPill(S.Set?.Title ?? "Zurück", () => _c.Send(new Event.Leave())), center, Ui.H(8, options, restart));
    }

    // MARK: Question

    double TopInset => Math.Max(20, Math.Min(112, (Window.Bounds.Height - 40 - 52 - 560) / 2));

    Control Column(Moves motion)
    {
        var q = S.Question!;
        var column = new StackPanel { Spacing = 16, Width = 760, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, TopInset, 0, 24) };
        if (WriteFlow.RoundNote(S) is { } note)
        {
            var capsule = new Border
            {
                Child = Ui.H(8, Icons.Icon(IconName.Repeat, 15, P.AccentText, 2), Ui.Text(note, 13.5, FontWeight.Medium, P.AccentText)),
                Background = WsTheme.B(P.AccentSoft),
                CornerRadius = new CornerRadius(999),
                Padding = new Thickness(16, 6),
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            column.Children.Add(capsule);
        }
        column.Children.Add(PromptCard(q, motion));
        return column;
    }

    /// <summary>The prompt card (Mac: WritePromptCard): the prompt's language and tools, the prompt, the answer area.</summary>
    Control PromptCard(WriteFlow.Question q, Moves motion)
    {
        var tools = Ui.H(4);
        if (q.PromptLang != Lang.Other)
            tools.Children.Add(Ui.IconButton(IconName.Speaker, "Vorlesen (Ctrl+R)", () => _c.Send(new Event.Speak(WriteFlow.SpeechTarget.Prompt)), 32, ButtonKind.Plain));
        tools.Children.Add(Ui.IconButton(q.Starred ? IconName.StarFilled : IconName.Star, q.Starred ? "Markierung entfernen (Ctrl+D)" : "Markieren (Ctrl+D)",
            () => _c.Send(new Event.ToggleStar()), 32, ButtonKind.Plain, q.Starred ? P.Star : null));
        tools.Children.Add(Ui.IconButton(IconName.Pencil, "Karte bearbeiten (Ctrl+E)", () => _c.Send(new Event.RequestEdit()), 32, ButtonKind.Plain));
        foreach (var b in tools.Children.OfType<Button>()) b.Focusable = false;
        var header = Ui.Row(Ui.Eyebrow(q.PromptLabel, P.TextSecondary), tools, 12);
        var prompt = StudyText.InLang(q.Prompt, q.PromptLang, q.Prompt.Length switch { < 28 => 40, < 70 => 32, _ => 25 }, FontWeight.Bold, font: WsTheme.Prompt);
        prompt.LetterSpacing = -0.3;
        prompt.Margin = new Thickness(0, 0, 0, 4);
        AutomationProperties.SetName(prompt, $"{q.PromptLabel}: {q.Prompt}");
        AutomationProperties.SetHeadingLevel(prompt, 1);
        if (motion.First) Effects.EntranceShift(prompt, x: StudyEntrance.PromptShift);
        else if (motion.NewQuestion && S.AnimatesQuestion) Effects.PromptSwapIn(prompt);
        var body = new StackPanel { Spacing = 16 };
        body.Children.Add(header);
        body.Children.Add(prompt);
        body.Children.Add(AnswerArea(q, motion));
        return Ui.Hero(body, new Thickness(28));
    }

    /// <summary>
    /// The answer area: the box while asking and, after a correct answer, the same box in green with "Genau: …" and the
    /// notes; after a miss "Deine Antwort", "Richtige Antwort" with 🔊, the copy field and "Bearbeiten".
    /// </summary>
    Control AnswerArea(WriteFlow.Question q, Moves motion)
    {
        _field.FlowDirection = q.AnswerLang.IsRTL() ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        _field.PlaceholderText = WriteFlow.FieldPlaceholder(S);
        var f = S.Feedback;
        if (S.Phase == Phase.Question || (S.Phase == Phase.FeedbackOf(FK.Correct) && f is not null))
        {
            bool correct = S.Phase != Phase.Question;
            var box = StudyAnswerBox.Create(correct ? null : _field, correct ? f!.Given : null, q.AnswerLang, isActive: !correct, isInvalid: false,
                shake: motion.Rejected && !correct, accepted: correct && motion.PhaseChanged);
            if (!correct) return box;
            var details = Ui.V(8);
            if (f!.ShowsExact && f.Result is { } r)
                details.Children.Add(Ui.H(6, Ui.Text(f.ExactLabel, 17, color: P.TextSecondary), StudyText.InLang(r.ExpectedDisplay, q.AnswerLang, 17, FontWeight.SemiBold)));
            var notes = new WrapPanel { ItemSpacing = 6, LineSpacing = 6 };
            foreach (var n in f.Notes) notes.Children.Add(Ui.Chip(n.Label, n.IsSynonym ? null : P.Warning));
            if (notes.Children.Count > 0) details.Children.Add(notes);
            if (details.Children.Count == 0) return box;
            if (motion.PhaseChanged) Effects.AnswerSwapIn(details);
            return Ui.V(12, box, details);
        }
        if (f is null) return new Border();
        var parts = new StackPanel { Spacing = 16, Margin = new Thickness(0, 4, 0, 0) };
        if (f.ShowsGiven)
            parts.Children.Add(Ui.V(6, Ui.H(8, Ui.Eyebrow("Deine Antwort", P.TextSecondary), f.ShowsHint ? Ui.Chip(f.HintLabel!, P.Warning, IconName.Lightbulb) : null),
                StudyText.Diff(f.Given, q.Expected, q.AnswerLang, 22)));
        var speak = Ui.IconButton(IconName.Speaker, "Antwort vorlesen", () => _c.Send(new Event.Speak(WriteFlow.SpeechTarget.Answer)), 32, ButtonKind.Plain);
        speak.Focusable = false;
        parts.Children.Add(Ui.V(6, Ui.Eyebrow("Richtige Antwort", P.TextSecondary), Ui.H(8, StudyText.InLang(q.Expected, q.AnswerLang, 22, FontWeight.Medium, P.Success.Text), speak)));
        if (f.EditedNote is { } edited)
            parts.Children.Add(Ui.H(8, StudyStatusPill.FeedbackSymbol(StudyStatus.Kinds.Correct, P.Success.Fill, 16), Ui.Text(edited, 14, FontWeight.Medium, P.Success.Text)));
        if (S.Phase == Phase.Copy)
            parts.Children.Add(Ui.V(8, Ui.Eyebrow(WriteFlow.FieldLabel(S), P.TextSecondary),
                StudyAnswerBox.Create(_field, null, q.AnswerLang, isActive: true, isInvalid: S.InputInvalid, shake: motion.Rejected, accepted: false)));
        var edit = Ui.Secondary("Bearbeiten", () => _c.Send(new Event.RequestEdit()), IconName.Pencil, "Ctrl E", 34);
        edit.Focusable = false;
        parts.Children.Add(edit);
        if (motion.PhaseChanged && S.Phase != Phase.Copy) Effects.AnswerSwapIn(parts);
        return parts;
    }

    // MARK: Summary, results, messages

    /// <summary>After a round (Mac: WriteSummaryView): the verdict, the ratio ring with the counts, the rows.</summary>
    Control SummaryView(bool appeared)
    {
        var sum = S.Summary!;
        double ratio = WriteFlow.SummaryRatio(sum);
        var eyebrow = Ui.Eyebrow(WriteFlow.SummaryEyebrow(sum), P.TextSecondary);
        var title = Ui.Text(WriteFlow.SummaryTitle(ratio), 34, FontWeight.Bold, wrap: TextWrapping.Wrap, font: WsTheme.Prompt, align: TextAlignment.Center);
        var text = Ui.Text(WriteFlow.SummaryText(sum), 18, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        foreach (var t in new Control[] { eyebrow, title, text }) t.HorizontalAlignment = HorizontalAlignment.Center;
        var ring = new RatioRing(ratio, ratio >= 0.8 ? P.Success.Fill : P.Accent, WriteFlow.PercentText(ratio), animate: appeared);
        var details = Ui.V(12, Ui.Text($"{sum.Correct} von {sum.Total} richtig", 17, FontWeight.Bold, font: WsTheme.Prompt),
            Ui.H(8, Ui.Chip($"{sum.Correct} richtig", P.Success, IconName.Check), Ui.Chip($"{sum.Incorrect} falsch", P.Failure, IconName.X)));
        if (WriteFlow.CountersOf(S) is { } c)
        {
            var overall = Ui.Row(Ui.Text("Insgesamt", 13.5, color: P.TextSecondary), Ui.Text($"{c.Correct} von {c.Total} geschafft", 13.5, color: P.TextSecondary));
            var line = new ProgressLine(c.Progress, P.Success.Fill, double.NaN, 8) { HorizontalAlignment = HorizontalAlignment.Stretch };
            details.Children.Add(Ui.V(6, overall, line));
        }
        details.VerticalAlignment = VerticalAlignment.Center;
        var cardRow = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 24 };
        cardRow.Children.Add(ring);
        Grid.SetColumn(details, 1);
        cardRow.Children.Add(details);
        var stack = Ui.V(24, Ui.V(8, eyebrow, title, text), Ui.Hero(cardRow, new Thickness(24), 22));
        var rows = WriteFlow.SummaryRows(S);
        var missed = rows.Where(r => r.Correct != true).ToList();
        var hit = rows.Where(r => r.Correct == true).ToList();
        if (missed.Count > 0) stack.Children.Add(StudyChrome.TermList("Noch üben", missed.Select(r => (r.Term, r.Definition, (Control?)ResultMark(false)))));
        if (hit.Count > 0) stack.Children.Add(StudyChrome.TermList("Richtig", hit.Select(r => (r.Term, r.Definition, (Control?)ResultMark(true)))));
        stack.Width = 760;
        stack.Margin = new Thickness(0, 24, 0, 24);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        return stack;
    }

    /// <summary>✓ or ✗ in a soft circle (Mac: WriteTermList's result marker).</summary>
    static Control ResultMark(bool correct)
    {
        var palette = correct ? P.Success : P.Failure;
        var mark = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = WsTheme.B(palette.Soft),
            Child = Icons.Icon(correct ? IconName.Check : IconName.X, 12, palette.Text, 3),
        };
        mark.Child.HorizontalAlignment = HorizontalAlignment.Center;
        mark.Child.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(mark, correct ? "Richtig" : "Falsch");
        return mark;
    }

    /// <summary>The end (Mac: WriteResultsView): trophy, "Geschafft!", four tiles with captions, the set's mastery, confetti.</summary>
    Control ResultsView(bool appeared)
    {
        var res = S.Results!;
        var stats = res.Stats;
        var circle = new Border { Width = 92, Height = 92, CornerRadius = new CornerRadius(46), Background = ProgressLine.Gradient(P.Accent), BoxShadow = BoxShadows.Parse($"0 6 32 0 {WsButton.Hex(P.Accent, 0.35)}") };
        var trophy = Icons.Icon(IconName.Trophy, 40, Colors.White, 2.2);
        trophy.HorizontalAlignment = HorizontalAlignment.Center;
        trophy.VerticalAlignment = VerticalAlignment.Center;
        circle.Child = trophy;
        circle.HorizontalAlignment = HorizontalAlignment.Center;
        circle.Margin = new Thickness(0, 0, 0, 8);
        if (appeared) Effects.Pop(trophy, 1.22);
        var title = Ui.Text("Geschafft!", 34, FontWeight.Bold, font: WsTheme.Prompt);
        var subtitle = Ui.Text(WriteFlow.ResultsSubtitle(res), 18, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        title.HorizontalAlignment = subtitle.HorizontalAlignment = HorizontalAlignment.Center;
        var time = WriteFlow.CompactDurationOf(stats.ElapsedMs);
        var tiles = StatTile.Row(12,
            StatTile.Create(res.CardCount == 1 ? "Begriff" : "Begriffe", $"{res.CardCount}", IconName.Stack, P.Accent, caption: res.BothDirections ? "in beide Richtungen" : "geschrieben"),
            StatTile.Create("Treffer", WriteFlow.PercentText(stats.Accuracy), IconName.Target, P.Success.Fill, caption: "beim ersten Versuch"),
            StatTile.Create(stats.Rounds == 1 ? "Runde" : "Runden", $"{stats.Rounds}", IconName.Repeat, P.Info.Fill, caption: "bis alles sass"),
            StatTile.Create(time.Label, time.Value, IconName.Clock, P.Flame, caption: "aktive Lernzeit"));
        var stack = Ui.V(24, Ui.V(12, circle, title, subtitle), tiles);
        if (S.Set is { } set)
        {
            var progress = Model.ProgressOf(set);
            int total = progress.Fresh + progress.Learning + progress.Mastered;
            var bar = new AnimatedStatusBar(progress.Mastered, progress.Learning, progress.Fresh, double.NaN, 10) { HorizontalAlignment = HorizontalAlignment.Stretch };
            var legend = Ui.H(20,
                Legend(P.Mastered.Fill, "Gemeistert", progress.Mastered), Legend(P.Learning.Fill, "Am Lernen", progress.Learning), Legend(P.New.Fill, "Neu", progress.Fresh));
            var head = Ui.Row(Ui.Text("Dein Lernset", 17, FontWeight.Bold, font: WsTheme.Prompt),
                Ui.Text($"{progress.Percent} % gemeistert", 19, FontWeight.Bold, progress.Mastered > 0 ? P.Mastered.Text : P.TextSecondary, font: WsTheme.Prompt));
            var card = Ui.Hero(Ui.V(16, head, bar, legend), new Thickness(24), 22);
            AutomationProperties.SetName(card, $"Dein Lernset: {progress.Percent} Prozent gemeistert");
            _ = total;
            stack.Children.Add(card);
        }
        var hardest = WriteFlow.HardestRows(S);
        if (hardest.Count == 0)
        {
            var none = Ui.H(8, Icons.Icon(IconName.Sparkles, 18, P.AccentText, 2), Ui.Text(WriteFlow.FlawlessText, 17, FontWeight.Medium, P.AccentText));
            none.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(none);
        }
        else stack.Children.Add(StudyChrome.TermList("Am häufigsten falsch", hardest.Select(r => (r.Term, r.Definition, (Control?)Ui.Chip(r.MissesLabel ?? "", P.Failure)))));
        stack.Width = 760;
        stack.Margin = new Thickness(0, 24, 0, 24);
        var layer = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        layer.Children.Add(stack);
        // Confetti when the results appear, not again when the screen is rebuilt.
        layer.Children.Add(new CelebrationView { Origin = new Point(0.5, 0.1), PlaysOnAttach = appeared });
        return layer;
    }

    static Control Legend(Color color, string label, int value) => Ui.H(6,
        new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = WsTheme.B(color), VerticalAlignment = VerticalAlignment.Center },
        Ui.Text(label, 13.5, color: P.TextSecondary), Ui.Text($"{value}", 13.5, FontWeight.Bold));

    /// <summary>Nothing to write (Mac: WriteMessageView): an empty state with its buttons.</summary>
    Control MessageView()
    {
        var m = S.Phase == Phase.Missing ? WriteFlow.MissingMessage : WriteFlow.EmptyMessage(S.EmptySubset ?? StudySubset.All);
        var actions = new List<Control>();
        if (S.Phase == Phase.Empty) actions.Add(Ui.Secondary("Zurück zum Lernset", () => _c.Send(new Event.Leave()), keyHint: "Esc", height: 44));
        if (WriteFlow.ReturnAction(S) is { } label) actions.Add(Ui.Primary(label, () => _c.Send(new Event.Proceed()), "↵", m.PrimaryOpensEditor ? IconName.Plus : null));
        var view = EmptyStateView.Create(Icons.ForSymbol(m.SystemImage), m.Title, m.Text, actions.ToArray());
        view.Margin = new Thickness(32, 80, 32, 32);
        return view;
    }

    // MARK: Action bar and overlays

    /// <summary>The pill for the state (Mac: WriteActionBar.status).</summary>
    StudyStatus? Status()
    {
        int streak = _c.Streak.Current;
        if (S.Phase == Phase.Question) return new StudyStatus(StudyStatus.Kinds.Typing, Streak: streak);
        if (S.Feedback is not { } f) return null;
        if (S.Phase == Phase.FeedbackOf(FK.Correct))
            return new StudyStatus(StudyStatus.Kinds.Correct, f.Title, S.AutoAdvance is not null ? WriteFlow.ReturnHint(S) : null, Streak: streak);
        if (S.Phase == Phase.FeedbackOf(FK.Wrong)) return new StudyStatus(StudyStatus.Kinds.Wrong, f.Title, Streak: streak);
        if (S.Phase == Phase.FeedbackOf(FK.DontKnow)) return new StudyStatus(StudyStatus.Kinds.DontKnow, f.Title, Streak: streak);
        if (S.Phase == Phase.Copy) return new StudyStatus(f.DontKnow ? StudyStatus.Kinds.DontKnow : StudyStatus.Kinds.Wrong, f.Title, Streak: streak);
        return null;
    }

    Control ActionBar(Moves motion)
    {
        var f = S.Feedback;
        var trailing = new List<Control?>();
        switch (S.Phase.Kind)
        {
            case PhaseKind.Question:
                trailing.Add(Ui.Secondary("Weiss ich nicht", () => _c.Send(new Event.DontKnow()), keyHint: "Alt ↵", height: 44));
                break;
            case PhaseKind.Feedback or PhaseKind.Copy when S.Phase.IsMiss && f is { CanOverride: true }:
                trailing.Add(Ui.Secondary(f.OverrideLabel, () => _c.Send(new Event.Override()), IconName.Check, "Ctrl ↵", 44));
                break;
            case PhaseKind.Summary:
                trailing.Add(Ui.Secondary("Zurück zum Lernset", () => _c.Send(new Event.Leave()), keyHint: "Esc", height: 44));
                break;
            case PhaseKind.Results:
                if (S.Results?.CanRetry == true) trailing.Add(Ui.Secondary("Fertig", () => _c.Send(new Event.Leave()), keyHint: "Esc", height: 44));
                trailing.Add(Ui.Secondary("Nochmal von vorne", () => _c.Send(new Event.Restart()), IconName.RotateCcw, "Ctrl Shift R", 44));
                break;
        }
        if (WriteFlow.ReturnAction(S) is { } label)
            trailing.Add(Ui.Primary(label, () => _c.Send(S.IsInputEditable ? new Event.Submit(_field.Text ?? "") : new Event.Proceed()), "↵", height: 44));
        Control? pill = null;
        if (Status() is { } status)
        {
            var countdown = _c.Countdown is { } cd && cd.Token == S.AutoAdvance?.Token ? cd : null;
            pill = StudyStatusPill.Create(status, countdown, motion.NewQuestion || motion.PhaseChanged, motion.StreakGrew);
        }
        return StudyActionBarView.Create(pill, trailing);
    }

    Control? OverlayLayer()
    {
        if (S.Prompt is { } prompt)
            return StudyChrome.Overlay(StudyChrome.PromptCard(prompt.Title, prompt.MessageText, prompt.ConfirmLabel, prompt.CancelLabel, false,
                ok => _c.Send(new Event.PromptAnswered(ok))), () => _c.Send(new Event.PromptAnswered(false)));
        if (S.Overlay is WriteFlow.Overlay.Options)
            return StudyChrome.Overlay(StudyChrome.OptionsPanel(Model, _c.SetId, StudyMode.Write,
                options => _c.Send(new Event.OptionsChanged(options)),
                () => _c.Send(new Event.OverlayDismissed()),
                () => _c.Send(new Event.OverlayDismissed(RestartRequested: true))), () => _c.Send(new Event.OverlayDismissed()));
        if (S.Overlay is WriteFlow.Overlay.Editor && WriteFlow.EditorCard(S) is { } card && S.Set is { } set)
        {
            var editor = StudyChrome.CardEditor(set, card, (term, definition) => _c.Send(new Event.EditCard(card with { Term = term, Definition = definition })),
                () => _c.Send(new Event.OverlayDismissed()), out var save);
            _editorSave = save;
            return StudyChrome.Overlay(editor, () => _c.Send(new Event.OverlayDismissed()));
        }
        _editorSave = null;
        return null;
    }

    // MARK: Keys

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        var mods = e.KeyModifiers;
        if (S.Prompt is not null)
        {
            if (isRepeat) return true;
            if (e.Key is Key.Enter or Key.Return) _c.Send(new Event.PromptAnswered(true));
            else if (e.Key == Key.Escape) _c.Send(new Event.PromptAnswered(false));
            return true;
        }
        if (S.Overlay is not null)
        {
            if (e.Key == Key.Escape)
            {
                _c.Send(new Event.OverlayDismissed());
                return true;
            }
            if (S.Overlay is WriteFlow.Overlay.Editor && e.Key is Key.Enter or Key.Return && !isRepeat && _editorSave is { } save)
            {
                save();
                return true;
            }
            return false;
        }
        if (mods == KeyModifiers.Control)
        {
            switch (e.Key)
            {
                case Key.R: _c.Send(new Event.Speak(WriteFlow.SpeechTarget.Prompt)); return true;
                case Key.D: _c.Send(new Event.ToggleStar()); return true;
                case Key.K: _c.Send(new Event.RequestOptions()); return true;
                case Key.E: _c.Send(new Event.RequestEdit()); return true;
            }
        }
        if (mods == (KeyModifiers.Control | KeyModifiers.Shift) && e.Key == Key.R)
        {
            _c.Send(new Event.Restart());
            return true;
        }
        if (Translate(e) is not { } key) return false;
        bool inField = Window.TextFieldFocused;
        if (inField && key.Kind is not (KeyKind.Return or KeyKind.OptionReturn or KeyKind.CommandReturn or KeyKind.Escape)) return false;
        if (key.Kind == KeyKind.Return && S.IsInputEditable && !isRepeat)
        {
            _c.Send(new Event.Submit(_field.Text ?? ""));
            return true;
        }
        _c.Send(new Event.Key(key, isRepeat));
        return true;
    }

    public override bool HandleText(string text)
    {
        if (S.IsBlocked || Window.TextFieldFocused) return false;
        if (S.IsInputEditable)
        {
            _field.Text = (_field.Text ?? "") + text;
            _field.CaretIndex = _field.Text.Length;
            _field.Focus();
            return true;
        }
        _c.Send(new Event.Key(TextKey(text)));
        return true;
    }
}
