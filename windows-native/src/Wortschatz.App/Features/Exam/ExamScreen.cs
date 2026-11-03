using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Exam;

/// <summary>
/// Prüfung (Mac: ExamScreen.swift, ExamSetupView.swift, ExamSheetView.swift, ExamResultsView.swift,
/// ExamController.swift): set up (time limit, number of words, direction, how small mistakes count), answer every
/// question on one sheet, hand in (or the time runs out), then the Swiss grade with every answer marked. An exam
/// records no progress.
/// </summary>
public sealed class ExamScreen : Screen
{
    enum Stage { Setup, Sheet, Results }

    readonly string _setId;
    Stage _stage = Stage.Setup;
    Stage? _shownStage;
    ExamSettings _settings;
    List<ExamQuestion> _questions = [];
    readonly Dictionary<int, TextBox> _fields = [];
    ExamResult? _result;
    double _startedAt;
    DispatcherTimer? _timer;
    TextBlock? _clock;
    IReadOnlyList<string>? _retakeIds;
    /// <summary>The results were just handed in (the grade settles in, confetti plays); false for later rebuilds.</summary>
    bool _resultAppeared;

    public ExamScreen(AppModel model, MainWindow window, StudyRequest request) : base(model, window)
    {
        _setId = request.SetId;
        _settings = model.Preferences.ExamSettings(_setId);
        if (request.Subset is { Kind: StudySubsetKind.CardIds } s) _retakeIds = s.CardIdList;
    }

    public override bool UsesSidebar => false;
    Palette P => WsTheme.P;
    VocabSet? Set => Model.Set(_setId);

    public override void Deactivate() => _timer?.Stop();

    public override void Refresh()
    {
        if (_stage != Stage.Sheet) base.Refresh();
    }

    protected override Control Build()
    {
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Control? center = null;
        if (_stage == Stage.Sheet && _settings.Minutes > 0)
        {
            _clock = Ui.Text("", 15, FontWeight.Bold);
            var cap = Ui.Glass(Ui.H(10, Icons.Icon(IconName.Clock, 17, P.TextSecondary), _clock), 999, new Thickness(18, 0), strong: true, shadow: false);
            cap.Height = 40;
            center = cap;
            UpdateClock();
        }
        root.Children.Add(StudyChrome.TopRow(StudyChrome.BackPill(Set?.Title ?? "Zurück", () => Model.BackToSet(_setId)), center, null));
        Control main = _stage switch
        {
            Stage.Setup => SetupView(),
            Stage.Sheet => SheetView(),
            _ => ResultsView(),
        };
        var stage = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
        stage.Children.Add(Ui.Scroll(main));
        var bar = ActionBar();
        Grid.SetRow(bar, 1);
        stage.Children.Add(bar);
        Grid.SetRow(stage, 1);
        root.Children.Add(stage);
        // Each step fades in where it stands (Mac: the stages' .transition(.opacity)).
        if (_shownStage != _stage)
        {
            if (_shownStage is null) StudyEntrance.RevealScreen(View);
            else Effects.FadeIn(main, Motion.Soft(0.4));
            _shownStage = _stage;
        }
        return root;
    }

    // MARK: Setup

    Control SetupView()
    {
        var set = Set;
        if (set is null) return new Border();
        int available = Core.Exam.Scope(set.Cards, _settings, _retakeIds).Count;
        int planned = Core.Exam.QuestionCount(_settings, available);
        var names = LearnOptionsCopy.SideNames(set.TermLang, set.DefLang);
        void Change(ExamSettings s)
        {
            _settings = s;
            Model.Preferences.SaveExamSettings(_setId, s);
            Refresh();
        }
        // Only the counts below the set's size, then "Alle N" (Mac: countChoices / countBinding).
        var counts = ExamSettings.CountChoices.Where(c => c == 0 || c < available).Select(c => (c, c == 0 ? $"Alle {available}" : $"{c}")).ToList();
        int shownCount = _settings.Count <= 0 || _settings.Count >= available ? 0 : _settings.Count;
        var countCaption = planned >= available ? "Alle Begriffe, in zufälliger Reihenfolge." : $"{planned} von {available} Begriffen, zufällig ausgewählt.";
        var timeCaption = _settings.Minutes <= 0
            ? "So viel Zeit, wie du brauchst. Die Zeit wird trotzdem gemessen."
            : $"Ist die Zeit um, wird abgegeben. Empfohlen: etwa {Labels.Plural(Math.Max(1, (int)Math.Ceiling(planned * 0.5)), "Minute", "Minuten")} für {Labels.Plural(planned, "Wort", "Wörter")}.";
        var direction = _settings.AnswerWith switch
        {
            AnswerWith.Both => "Die Richtung wechselt zufällig von Frage zu Frage.",
            AnswerWith.Definition => $"Du siehst {names.Term.Seen} und antwortest {names.Definition.Answered}.",
            _ => $"Du siehst {names.Definition.Seen} und antwortest {names.Term.Answered}.",
        };
        var rows = new List<Control>
        {
            Row("Wörter", IconName.Stack, countCaption, Segmented(counts, shownCount, v => Change(_settings with { Count = v }), counts.Count > 4 ? 64 : 76)),
            Row("Zeitlimit", IconName.Clock, timeCaption,
                Menu<int>(ExamSettings.MinuteChoices.Select(m => (m, m == 0 ? "Ohne" : $"{m} Min.")).ToList(), _settings.Minutes, v => Change(_settings with { Minutes = v }))),
            Row("Antworten auf", IconName.Repeat, direction,
                Segmented<AnswerWith>([(AnswerWith.Term, names.Term.Label), (AnswerWith.Definition, names.Definition.Label), (AnswerWith.Both, "Beides")], _settings.AnswerWith,
                    v => Change(_settings with { AnswerWith = v }), 100)),
            Row("Kleine Fehler", IconName.CheckCircle, ExamCopy.ToleranceText(_settings.Tolerance),
                Segmented(EnumRaw.All<ExamTolerance>().Select(t => (t, ExamCopy.ToleranceTitle(t))).ToList(), _settings.Tolerance,
                    v => Change(_settings with { Tolerance = v }), 104)),
        };
        int starred = set.Cards.Count(c => c.Starred);
        if (starred > 0 && _retakeIds is null)
            rows.Add(Row($"Nur markierte ({starred})", IconName.Star, "Nur die Begriffe mit Stern abfragen.", Switch(_settings.StarredOnly, v => Change(_settings with { StarredOnly = v }))));
        var list = new StackPanel { Spacing = 16 };
        for (int i = 0; i < rows.Count; i++)
        {
            if (i > 0) list.Children.Add(Ui.Divider());
            list.Children.Add(rows[i]);
        }

        // Header (Mac: ExamSetupView.header): the cap on an accent disc, "Prüfungsmodus", the title and what it is.
        var disc = new Border
        {
            Width = 80, Height = 80, CornerRadius = new CornerRadius(40), Background = ProgressLine.Gradient(P.Accent),
            BoxShadow = BoxShadows.Parse($"0 5 28 0 {WsButton.Hex(P.Accent, 0.35)}"), HorizontalAlignment = HorizontalAlignment.Center,
            Child = Icons.Icon(IconName.Exam, 34, Colors.White, 2.2),
        };
        disc.Child.HorizontalAlignment = HorizontalAlignment.Center;
        disc.Child.VerticalAlignment = VerticalAlignment.Center;
        var eyebrow = Ui.Eyebrow(_retakeIds is null ? "Prüfungsmodus" : "Prüfungsmodus · Falsche nochmal");
        var title = Ui.Text("Prüfung einrichten", 32, FontWeight.Bold, font: WsTheme.Prompt);
        var lead = Ui.Text("Alle Fragen auf einer Seite, mit Zeitlimit und einer Note wie in der Schule.", 17, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        foreach (var c in new Control[] { eyebrow, title, lead }) c.HorizontalAlignment = HorizontalAlignment.Center;
        disc.Margin = new Thickness(0, 0, 0, 6);
        var header = Ui.V(6, disc, eyebrow, title, lead);

        var card = Ui.Glass(list, 26, new Thickness(26, 22), strong: true);
        var notes = Ui.V(6,
            Note(IconName.Info, ExamCopy.SmallMistakesText),
            Note(IconName.Sparkles, "Die Prüfung zählt nicht für «Gemeistert». Was falsch ist, kannst du danach gezielt lernen."));
        var stack = Ui.V(22, header, card, notes);
        stack.Width = 700;
        stack.Margin = new Thickness(0, 18, 0, 24);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        return stack;
    }

    Control Note(IconName icon, string text)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 8 };
        var i = Icons.Icon(icon, 15, P.TextSecondary);
        i.VerticalAlignment = VerticalAlignment.Top;
        i.Margin = new Thickness(0, 2, 0, 0);
        row.Children.Add(i);
        var t = Ui.Text(text, 13.5, color: P.TextSecondary, wrap: TextWrapping.Wrap);
        Grid.SetColumn(t, 1);
        row.Children.Add(t);
        return row;
    }

    /// <summary>"20 Wörter · 10 Minuten" (the setup bar's pill, Mac: ExamSetupView.summary).</summary>
    string SetupSummary()
    {
        if (Set is not { } set) return "";
        int planned = Core.Exam.QuestionCount(_settings, Core.Exam.Scope(set.Cards, _settings, _retakeIds).Count);
        return $"{Labels.Plural(planned, "Wort", "Wörter")} · {ExamCopy.Minutes(_settings.Minutes)}";
    }

    /// <summary>A segmented choice in the Glas look (Mac: <c>.pickerStyle(.segmented)</c>).</summary>
    static Control Segmented<T>(IReadOnlyList<(T Value, string Label)> items, T selected, Action<T> changed, double width)
    {
        int index = Math.Max(0, items.ToList().FindIndex(i => EqualityComparer<T>.Default.Equals(i.Value, selected)));
        var control = new WsSegmented(items.Select(i => i.Label).ToList(), index, width);
        control.SelectionChanged += i => changed(items[i].Value);
        return control;
    }

    /// <summary>A pop-up menu for a longer list of choices (Mac: <c>.pickerStyle(.menu)</c>).</summary>
    static Control Menu<T>(IReadOnlyList<(T Value, string Label)> items, T selected, Action<T> changed)
    {
        var box = new ComboBox { MinWidth = 170 };
        foreach (var (_, label) in items) box.Items.Add(new ComboBoxItem { Content = label });
        box.SelectedIndex = Math.Max(0, items.ToList().FindIndex(i => EqualityComparer<T>.Default.Equals(i.Value, selected)));
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0) changed(items[box.SelectedIndex].Value);
        };
        return box;
    }

    static Control Switch(bool value, Action<bool> changed)
    {
        var s = new WsSwitch(value, "Nur markierte");
        s.Toggled += changed;
        return s;
    }

    /// <summary>A setting: the accent symbol, title and caption on the left, the control on the right (Mac: ExamSettingRow).</summary>
    static Control Row(string label, IconName icon, string caption, Control control)
    {
        var p = WsTheme.P;
        var badge = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(8), Background = WsTheme.B(p.AccentSoft), Child = Icons.Icon(icon, 14, p.AccentText, 2.2), VerticalAlignment = VerticalAlignment.Top };
        badge.Child.HorizontalAlignment = HorizontalAlignment.Center;
        badge.Child.VerticalAlignment = VerticalAlignment.Center;
        var text = Ui.V(2, Ui.Text(label, 15, FontWeight.SemiBold), Ui.Text(caption, 13, color: p.TextSecondary, wrap: TextWrapping.Wrap));
        var left = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 10 };
        left.Children.Add(badge);
        Grid.SetColumn(text, 1);
        left.Children.Add(text);
        control.VerticalAlignment = VerticalAlignment.Center;
        return Ui.Row(left, control, 16);
    }

    void Start()
    {
        if (Set is not { } set) return;
        _questions = Core.Exam.MakeQuestions(set.Cards, _settings, set.TermLang, set.DefLang, _retakeIds);
        if (_questions.Count == 0) return;
        _fields.Clear();
        _startedAt = TimeUtil.NowMs();
        _stage = Stage.Sheet;
        if (_settings.Minutes > 0)
        {
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += (_, _) =>
            {
                if (RemainingMs <= 0) HandIn(timedOut: true);
                else UpdateClock();
            };
            _timer.Start();
        }
        base.Refresh();
        Dispatcher.UIThread.Post(() => _fields.Values.FirstOrDefault()?.Focus(), DispatcherPriority.Input);
    }

    double RemainingMs => _settings.Minutes * 60_000 - (TimeUtil.NowMs() - _startedAt);

    void UpdateClock()
    {
        if (_clock is null) return;
        var left = TimeSpan.FromMilliseconds(Math.Max(0, RemainingMs));
        _clock.Text = $"{(int)left.TotalMinutes}:{left.Seconds:00}";
        _clock.Foreground = WsTheme.B(left.TotalSeconds < 60 ? P.Failure.Text : P.Text);
    }

    // MARK: Sheet

    Control SheetView()
    {
        var list = new StackPanel { Spacing = 10 };
        foreach (var q in _questions)
        {
            if (!_fields.TryGetValue(q.Number, out var field))
            {
                field = Ui.Field(q.AnswerLang == Lang.Other ? "Antwort" : $"Auf {Labels.LangName(q.AnswerLang)} …", "", 16, 44);
                if (q.AnswerLang.IsRTL()) field.FlowDirection = FlowDirection.RightToLeft;
                int number = q.Number;
                field.KeyDown += (_, e) =>
                {
                    if (e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.None)
                    {
                        // Enter moves to the next question (Ctrl+Enter hands in).
                        if (_fields.TryGetValue(number + 1, out var next)) next.Focus();
                        e.Handled = true;
                    }
                };
                _fields[q.Number] = field;
            }
            else if (field.Parent is Panel old) old.Children.Remove(field);
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("36,*,*"), ColumnSpacing = 14 };
            g.Children.Add(Ui.Text($"{q.Number}.", 15, FontWeight.Bold, P.TextTertiary));
            var prompt = StudyText.InLang(q.Prompt, q.PromptLang, 17, FontWeight.SemiBold);
            Grid.SetColumn(prompt, 1);
            g.Children.Add(prompt);
            Grid.SetColumn(field, 2);
            g.Children.Add(field);
            list.Children.Add(Ui.Glass(g, 16, new Thickness(16, 10), shadow: false));
        }
        var head = Ui.V(6, Ui.Eyebrow("Prüfung"), Ui.Text(Set?.Title ?? "", 26, FontWeight.Bold),
            Ui.Text($"{Labels.Plural(_questions.Count, "Frage", "Fragen")} · Enter springt zur nächsten · Ctrl+Enter gibt ab", 14, color: P.TextSecondary));
        var stack = Ui.V(18, head, list);
        stack.Width = 820;
        stack.Margin = new Thickness(0, 22, 0, 0);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        return stack;
    }

    /// <summary>For the snapshot tool: starts the exam, fills the answers and hands it in.</summary>
    public void RunForSnapshot(Func<ExamQuestion, string> answer)
    {
        Start();
        foreach (var q in _questions)
            if (_fields.TryGetValue(q.Number, out var field)) field.Text = answer(q);
        HandIn();
    }

    void HandIn(bool timedOut = false)
    {
        if (_stage != Stage.Sheet || Set is not { } set) return;
        _timer?.Stop();
        var answers = _fields.ToDictionary(f => f.Key, f => f.Value.Text ?? "");
        _result = Core.Exam.Evaluate(_questions, answers, set.Cards, _settings.Tolerance, TimeUtil.NowMs() - _startedAt, timedOut);
        _stage = Stage.Results;
        _resultAppeared = true;
        Model.Sounds.Play(_result.Grade >= 4 ? Services.SoundEffects.Sound.Finished : Services.SoundEffects.Sound.RoundDone);
        if (timedOut) Model.ShowToast(new ToastMessage("Die Zeit ist abgelaufen – die Prüfung wurde abgegeben.", ToastTone.Warning));
        base.Refresh();
        _resultAppeared = false;
    }

    // MARK: Results

    Control ResultsView()
    {
        var r = _result!;
        double grade = r.Grade;
        // The grade in a coloured circle that settles in (Mac: ExamGradeHero): green from 5, accent from 4, else amber.
        var pal = grade >= 5 ? P.Success : grade >= 4 ? new StatusPalette(P.Accent, P.AccentText, P.AccentSoft) : P.Warning;
        var circle = new Border
        {
            Width = 132, Height = 132, CornerRadius = new CornerRadius(66), Background = ProgressLine.Gradient(pal.Fill),
            BoxShadow = BoxShadows.Parse($"0 7 36 0 {WsButton.Hex(pal.Fill, 0.35)}"), HorizontalAlignment = HorizontalAlignment.Center,
            RenderTransformOrigin = RelativePoint.Center,
        };
        var noteLabel = Ui.Text("Note", 13, FontWeight.SemiBold, Colors.White, font: WsTheme.Prompt);
        noteLabel.Opacity = 0.85;
        var gradeText = Ui.Text(Core.Exam.GradeText(grade), 50, FontWeight.Bold, Colors.White, font: WsTheme.Prompt);
        foreach (var t in new[] { noteLabel, gradeText }) t.HorizontalAlignment = HorizontalAlignment.Center;
        var inner = Ui.V(0, noteLabel, gradeText);
        inner.VerticalAlignment = VerticalAlignment.Center;
        circle.Child = inner;
        Avalonia.Automation.AutomationProperties.SetName(circle, $"Note {Core.Exam.GradeText(grade)}");
        if (_resultAppeared) Effects.Of(circle).Enter(new Placement(Scale: 0.86, Opacity: 0), Motion.Arrive(0.6).Delayed(0.1));
        int seconds = (int)Math.Round(r.ElapsedMs / 1000);
        var verdict = Ui.Text(Core.Exam.Verdict(grade), 34, FontWeight.Bold, wrap: TextWrapping.Wrap, font: WsTheme.Prompt, align: TextAlignment.Center);
        var subtitle = Ui.Text($"{ExamCopy.ScoreLine(r)} in {seconds / 60}:{seconds % 60:00}", 18, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        verdict.HorizontalAlignment = subtitle.HorizontalAlignment = HorizontalAlignment.Center;
        var hero = Ui.V(10, circle, verdict, subtitle);
        circle.Margin = new Thickness(0, 0, 0, 8);
        if (r.TimedOut)
        {
            var late = Ui.H(8, Icons.Icon(IconName.Clock, 16, P.Warning.Text, 2), Ui.Text("Die Zeit war um, die Prüfung wurde abgegeben.", 14, FontWeight.Medium, P.Warning.Text));
            late.HorizontalAlignment = HorizontalAlignment.Center;
            hero.Children.Add(late);
        }
        var tiles = StatTile.Row(12,
            StatTile.Create("Richtig", $"{r.Count(ExamMark.Correct)}", IconName.Check, P.Success.Fill),
            StatTile.Create("Kleine Fehler", $"{r.Count(ExamMark.Minor)}", IconName.Lightbulb, P.Warning.Fill),
            StatTile.Create("Falsch", $"{r.Count(ExamMark.Wrong)}", IconName.X, P.Failure.Fill),
            StatTile.Create("Leer", $"{r.Count(ExamMark.Blank)}", IconName.Minimize, P.New.Fill));
        var head = Ui.V(24, hero, tiles);
        var items = new StackPanel { Spacing = 8 };
        foreach (var item in r.Items)
        {
            var mp = item.Mark switch { ExamMark.Correct => P.Success, ExamMark.Minor => P.Warning, ExamMark.Wrong => P.Failure, _ => P.New };
            var q = item.Question;
            var given = item.Given.Length == 0 ? Ui.Text("–", 15, color: P.TextTertiary)
                : item.Mark is ExamMark.Correct ? StudyText.InLang(item.Given, q.AnswerLang, 15, FontWeight.SemiBold, P.Success.Text)
                : StudyText.Diff(item.Given, item.Matched ?? q.Expected, q.AnswerLang, 15);
            var right = Ui.V(4, given, item.Mark is ExamMark.Correct ? null : StudyText.InLang(q.Expected, q.AnswerLang, 14, color: P.Success.Text),
                item.Note is { } note ? Ui.Text(note, 12.5, color: P.TextTertiary) : null);
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("36,*,*,Auto"), ColumnSpacing = 14 };
            g.Children.Add(Ui.Text($"{q.Number}.", 15, FontWeight.Bold, P.TextTertiary));
            var prompt = StudyText.InLang(q.Prompt, q.PromptLang, 15, FontWeight.SemiBold);
            Grid.SetColumn(prompt, 1);
            g.Children.Add(prompt);
            Grid.SetColumn(right, 2);
            g.Children.Add(right);
            var chip = Ui.Chip(ExamCopy.MarkLabel(item), mp);
            Grid.SetColumn(chip, 3);
            g.Children.Add(chip);
            items.Children.Add(Ui.Glass(g, 16, new Thickness(16, 10), shadow: false));
        }
        var stack = Ui.V(24, head, items);
        stack.Width = 820;
        stack.Margin = new Thickness(0, 24, 0, 24);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        if (grade < 5.5) return stack;
        // Confetti for a grade of 5.5 or more (Mac: ExamCelebration), only when the results appear.
        var layer = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        layer.Children.Add(stack);
        layer.Children.Add(new CelebrationView { Origin = new Point(0.5, 0.1), PlaysOnAttach = _resultAppeared });
        return layer;
    }

    // MARK: Actions and keys

    Control ActionBar()
    {
        var items = new List<Control?>();
        switch (_stage)
        {
            case Stage.Setup:
                items.Add(Ui.Secondary("Zurück zum Lernset", () => Model.BackToSet(_setId), keyHint: "Esc", height: 44));
                items.Add(Ui.Primary("Prüfung starten", Start, "↵", height: 44));
                break;
            case Stage.Sheet:
                items.Add(Ui.Primary("Abgeben", () => HandIn(), "Ctrl ↵", height: 44));
                break;
            default:
                items.Add(Ui.Secondary("Zurück zum Lernset", () => Model.BackToSet(_setId), keyHint: "Esc", height: 44));
                if (_result!.CardIdsToPractise.Count > 0)
                {
                    var ids = _result.CardIdsToPractise;
                    items.Add(Ui.Secondary($"Falsche lernen ({ids.Count})", () => Model.Study(_setId, StudyMode.Learn, StudySubset.CardIds(ids)), IconName.Sparkles, height: 44));
                }
                items.Add(Ui.Primary("Neue Prüfung", () =>
                {
                    _stage = Stage.Setup;
                    Refresh();
                }, "↵", height: 44));
                break;
        }
        Control? left = null;
        if (_stage == Stage.Setup)
        {
            var pill = Ui.Glass(Ui.H(8, Icons.Icon(IconName.Stack, 15, P.TextSecondary), Ui.Text(SetupSummary(), 14, FontWeight.Medium, P.TextSecondary)), 999, new Thickness(16, 0), strong: true, shadow: false);
            pill.Height = 44;
            left = pill;
        }
        return StudyActionBarView.Create(left, items, _stage == Stage.Results ? 820 : 760);
    }

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        if (isRepeat) return false;
        bool enter = e.Key is Key.Enter or Key.Return;
        switch (_stage)
        {
            case Stage.Setup when enter && e.KeyModifiers == KeyModifiers.None:
                Start();
                return true;
            case Stage.Sheet when enter && e.KeyModifiers == KeyModifiers.Control:
                HandIn();
                return true;
            case Stage.Results when enter && e.KeyModifiers == KeyModifiers.None:
                _stage = Stage.Setup;
                Refresh();
                return true;
        }
        if (e.Key == Key.Escape && _stage != Stage.Sheet)
        {
            Model.BackToSet(_setId);
            return true;
        }
        return false;
    }
}
