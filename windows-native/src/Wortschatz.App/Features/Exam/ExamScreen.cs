using Avalonia;
using Avalonia.Automation;
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
/// records no progress; the result offers to learn the words that went wrong or to test only them again.
/// </summary>
public sealed class ExamScreen : Screen
{
    enum Stage { Setup, Sheet, Results }

    /// <summary>
    /// The settings are the same for every set (Mac: UserDefaults "exam.settings"); AppPreferences keeps them under
    /// "exam." + this key, i.e. "exam.settings".
    /// </summary>
    const string SharedSettingsKey = "settings";

    readonly string _setId;
    Stage _stage = Stage.Setup;
    Stage? _shownStage;
    ExamSettings _settings;
    List<ExamQuestion> _questions = [];
    readonly Dictionary<int, TextBox> _fields = [];
    /// <summary>The accent buttons under each answer, shown while its field has the focus (Mac: the floating accents).</summary>
    readonly Dictionary<int, Control> _accents = [];
    /// <summary>The rows of the sheet as last built (number badge, focus band, layout).</summary>
    readonly Dictionary<int, SheetRow> _rows = [];
    bool _minuteAnnounced;
    ExamResult? _result;
    double _startedAt;
    DispatcherTimer? _timer;
    TextBlock? _clock, _answeredTop, _answeredPill;
    /// <summary>The clock's symbol (rebuilt in the clock's colour when the last minute begins).</summary>
    Border _clockIcon = new();
    bool? _clockWarns;
    Control? _clockView, _answeredTopView;
    ProgressLine? _answeredLine;
    /// <summary>A retake asks only these cards (the ones to practise after the last exam; Mac: retakeCardIDs).</summary>
    IReadOnlyList<string>? _retakeIds;
    /// <summary>The results were just handed in (the grade settles in, confetti plays); false for later rebuilds.</summary>
    bool _resultAppeared;
    /// <summary>Prompt and answer side by side (wide sheet) or one under the other (narrow window).</summary>
    bool _wide = true;

    sealed record SheetRow(Border Band, Border Badge, TextBlock BadgeText, Grid Layout, Control Prompt, Control Answer);

    public ExamScreen(AppModel model, MainView window, StudyRequest request) : base(model, window)
    {
        _setId = request.SetId;
        _settings = model.Preferences.ExamSettings(SharedSettingsKey);
    }

    public override bool UsesSidebar => false;
    Palette P => WsTheme.P;
    VocabSet? Set => Model.Set(_setId);

    /// <summary>The set has no card with both sides filled in (Mac: ExamController.isEmpty).</summary>
    bool IsEmpty => Set is not { } set || Core.Exam.Scope(set.Cards, ExamSettings.Default).Count == 0;

    static bool HasText(string? text) => JSCompat.Trim(text ?? "").Length > 0;

    int AnsweredCount => _questions.Count(q => _fields.TryGetValue(q.Number, out var f) && HasText(f.Text));

    public override void Deactivate()
    {
        _timer?.Stop();
        if (Model.LeaveGuard == _leaveGuard) Model.LeaveGuard = null;
    }

    Func<Action, bool>? _leaveGuard;

    /// <summary>A running exam with answers is never left without asking (Mac: ExamController leave guard).</summary>
    bool AskBeforeLeaving(Action leave)
    {
        if (_stage != Stage.Sheet || AnsweredCount == 0 || Model.Prompt is not null) return false;
        Model.Ask(PromptRequest.Confirm("Prüfung beenden?", "Die Prüfung wird nicht bewertet, deine Antworten gehen verloren.", "Beenden", () =>
        {
            _timer?.Stop();
            _stage = Stage.Setup;
            leave();
        }, destructive: true));
        return true;
    }

    /// <summary>"Abgeben": asks first when questions are still open (Mac: ExamController.requestSubmit).</summary>
    void RequestHandIn()
    {
        if (_stage != Stage.Sheet || Model.Prompt is not null) return;
        int open = _questions.Count - AnsweredCount;
        if (open == 0)
        {
            HandIn();
            return;
        }
        Model.Ask(PromptRequest.Confirm("Prüfung abgeben?",
            open == 1 ? "Eine Frage ist noch offen. Sie zählt als falsch." : $"{open} Fragen sind noch offen. Sie zählen als falsch.",
            "Abgeben", () => HandIn()));
    }

    /// <summary>Keys are ignored until then: an Enter meant for the next question must not skip the results.</summary>
    double _keysBlockedUntil;

    /// <summary>"Neue Prüfung" (Ctrl+Shift+R): back to the settings; during the exam only after asking.</summary>
    void RequestNewExam()
    {
        void Reset()
        {
            _timer?.Stop();
            _retakeIds = null;
            _stage = Stage.Setup;
            base.Refresh();
        }
        if (!AskBeforeLeaving(Reset)) Reset();
    }

    /// <summary>"Falsche prüfen": a new sheet with only the words to practise (Mac: retakeMistakes).</summary>
    void RetakeMistakes()
    {
        if (_result is not { } r || r.CardIdsToPractise.Count == 0) return;
        _retakeIds = r.CardIdsToPractise;
        Start();
    }

    /// <summary>
    /// "Falsche lernen": a Learn session with the words to practise. Words Lernen counts as mastered are asked again too
    /// (reviewMastered): the exam just found them wrong.
    /// </summary>
    void LearnMistakes()
    {
        if (_result is not { } r || r.CardIdsToPractise.Count == 0) return;
        Model.Study(_setId, StudyMode.Learn, StudySubset.CardIds(r.CardIdsToPractise), reviewMastered: true);
    }

    void Exit() => Model.BackToSet(_setId);

    void AddCards() => Model.OpenEditor(_setId);

    public override void Refresh()
    {
        if (_stage != Stage.Sheet) base.Refresh();
    }

    protected override Control Build()
    {
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        root.Children.Add(StudyChrome.TopRow(StudyChrome.BackPill(Set?.Title ?? "Zurück", Exit), _stage == Stage.Sheet ? SheetStatus() : null, null));
        _leaveGuard ??= AskBeforeLeaving;
        Model.LeaveGuard = _leaveGuard;
        Control main;
        Control? bar = null;
        if (_stage == Stage.Setup && IsEmpty) main = EmptyView();
        else
        {
            main = Ui.Scroll(_stage switch
            {
                Stage.Setup => SetupView(),
                Stage.Sheet => SheetView(),
                _ => ResultsView(),
            });
            bar = ActionBar();
        }
        var stage = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
        stage.Children.Add(main);
        if (bar is not null)
        {
            Grid.SetRow(bar, 1);
            stage.Children.Add(bar);
        }
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

    /// <summary>No card with both sides in the set (Mac: ExamEmptyView).</summary>
    Control EmptyView()
    {
        var view = EmptyStateView.Create(IconName.Exam, "Nichts zu prüfen",
            "Dieses Lernset hat noch keine Begriffe mit Übersetzung. Füge welche hinzu, dann geht es los.",
            Ui.Secondary("Zurück zum Lernset", Exit, keyHint: "Esc", height: 44),
            Ui.Primary("Begriffe hinzufügen", AddCards, "↵", IconName.Plus));
        view.MaxWidth = 760;
        return view;
    }

    // MARK: Setup

    Control SetupView()
    {
        var set = Set;
        if (set is null) return new Border();
        int available = Core.Exam.Scope(set.Cards, _settings).Count;
        int planned = Core.Exam.QuestionCount(_settings, available);
        var names = LearnOptionsCopy.SideNames(set.TermLang, set.DefLang);
        void Change(ExamSettings s)
        {
            if (s == _settings) return;
            _settings = s;
            Model.Preferences.SaveExamSettings(SharedSettingsKey, s);
            Refresh();
        }
        // Only the counts below the set's size, then "Alle N" (Mac: countChoices / countBinding).
        var counts = ExamSettings.CountChoices.Where(c => c == 0 || c < available).Select(c => (c, c == 0 ? $"Alle {available}" : $"{c}")).ToList();
        int shownCount = _settings.Count <= 0 || _settings.Count >= available ? 0 : _settings.Count;
        var countCaption = planned >= available ? "Alle Begriffe, in zufälliger Reihenfolge." : $"{planned} von {available} Begriffen, zufällig ausgewählt.";
        var timeCaption = _settings.Minutes <= 0
            ? "So viel Zeit, wie du brauchst. Die Zeit wird trotzdem gemessen."
            : $"Ist die Zeit um, wird abgegeben. Empfohlen: etwa {Labels.Plural(Math.Max(1, (int)Math.Ceiling(planned * 0.5)), "Minute", "Minuten")} für {Labels.Plural(planned, "Wort", "Wörter")}.";
        var tolerance = Row("Kleine Fehler", IconName.CheckCircle, ExamCopy.ToleranceText(_settings.Tolerance),
            Segmented(EnumRaw.All<ExamTolerance>().Select(t => (t, ExamCopy.ToleranceTitle(t))).ToList(), _settings.Tolerance,
                v => Change(_settings with { Tolerance = v }), 104));
        ToolTip.SetTip(tolerance, ExamCopy.SmallMistakesText);
        var rows = new List<Control>
        {
            Row("Wörter", IconName.Stack, countCaption, Segmented(counts, shownCount, v => Change(_settings with { Count = v }), counts.Count > 4 ? 64 : 76)),
            Row("Zeitlimit", IconName.Clock, timeCaption,
                Menu<int>(ExamSettings.MinuteChoices.Select(m => (m, m == 0 ? "Ohne" : $"{m} Min.")).ToList(), _settings.Minutes, v => Change(_settings with { Minutes = v }))),
            Row("Antworten auf", IconName.Repeat, LearnOptionsCopy.DirectionText(_settings.AnswerWith, names),
                Segmented<AnswerWith>([(AnswerWith.Term, names.Term.Label), (AnswerWith.Definition, names.Definition.Label), (AnswerWith.Both, "Beides")], _settings.AnswerWith,
                    v => Change(_settings with { AnswerWith = v }), 100)),
            tolerance,
        };
        // Starred cards that can be asked (both sides filled in; Mac: starredCount).
        int starred = Core.Exam.Scope(set.Cards, ExamSettings.Default).Count(c => c.Starred);
        if (starred > 0)
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
        var eyebrow = Ui.Eyebrow("Prüfungsmodus");
        var title = Ui.Text("Prüfung einrichten", 32, FontWeight.Bold, font: WsTheme.Prompt);
        AutomationProperties.SetHeadingLevel(title, 1);
        var lead = Ui.Text("Alle Fragen auf einer Seite, mit Zeitlimit und einer Note wie in der Schule.", 17, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        foreach (var c in new Control[] { eyebrow, title, lead }) c.HorizontalAlignment = HorizontalAlignment.Center;
        disc.Margin = new Thickness(0, 0, 0, 6);
        var header = Ui.V(6, disc, eyebrow, title, lead);

        var card = Ui.Glass(list, 26, AppDevice.IsPhone ? new Thickness(18, 18) : new Thickness(26, 22), strong: true);
        var notes = Ui.V(6,
            Note(IconName.Info, ExamCopy.SmallMistakesText),
            Note(IconName.Sparkles, "Die Prüfung zählt nicht für «Gemeistert». Was falsch ist, kannst du danach gezielt lernen."));
        var stack = Ui.V(22, header, card, notes);
        stack.MaxWidth = 700;
        stack.Margin = PageMargin(18);
        return stack;
    }

    /// <summary>The page's margins: on a phone as narrow as on the other pages (32 left only 296 of 390 points).</summary>
    static Thickness PageMargin(double top) => AppDevice.IsPhone ? new Thickness(8, top - 8, 8, 24) : new Thickness(32, top, 32, 24);

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
        int planned = Core.Exam.QuestionCount(_settings, Core.Exam.Scope(set.Cards, _settings).Count);
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

    /// <summary>"Prüfung starten": a new sheet, the clock starts (Mac: ExamController.start).</summary>
    void Start()
    {
        if (_stage == Stage.Sheet || Set is not { } set) return;
        var sheet = Core.Exam.MakeQuestions(set.Cards, _settings, set.TermLang, set.DefLang, _retakeIds);
        if (sheet.Count == 0) return;
        _questions = sheet;
        _fields.Clear();
        _accents.Clear();
        _rows.Clear();
        _result = null;
        _minuteAnnounced = false;
        _startedAt = TimeUtil.NowMs();
        _stage = Stage.Sheet;
        _timer?.Stop();
        // Every second: the clock (time left, or taken without a limit), the warning a minute before the end, the end.
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        base.Refresh();
        Announcer.Announce($"Prüfung gestartet: {Labels.Plural(sheet.Count, "Frage", "Fragen")}" + (_settings.Minutes > 0 ? $", {ExamCopy.Minutes(_settings.Minutes)}." : "."));
        Dispatcher.UIThread.Post(() => _fields.Values.FirstOrDefault()?.Focus(), DispatcherPriority.Input);
    }

    void Tick()
    {
        if (_stage != Stage.Sheet) return;
        if (_settings.Minutes > 0 && RemainingMs <= 0)
        {
            HandIn(timedOut: true);
            return;
        }
        // A minute before the end, once (only on exams longer than two minutes).
        if (_settings.Minutes * 60 > 120 && !_minuteAnnounced && RemainingMs <= 60_000)
        {
            _minuteAnnounced = true;
            Model.ShowToast(new ToastMessage("Noch eine Minute", ToastTone.Warning));
            Announcer.Announce("Noch eine Minute");
        }
        UpdateClock();
    }

    double RemainingMs => _settings.Minutes * 60_000 - (TimeUtil.NowMs() - _startedAt);

    // MARK: Sheet status (top row)

    /// <summary>
    /// The time (left, or taken without a limit) and the answered questions in the top row's centre; amber in the last
    /// minute (Mac: ExamToolbarStatus).
    /// </summary>
    Control SheetStatus()
    {
        _clockIcon = new Border { VerticalAlignment = VerticalAlignment.Center };
        _clockWarns = null;
        _clock = Ui.Text("", 15, FontWeight.SemiBold);
        _clock.FontFeatures = FontFeatureCollection.Parse("tnum");
        var clock = Ui.H(7, _clockIcon, _clock);
        _clockView = clock;
        ToolTip.SetTip(clock, _settings.Minutes > 0 ? "Verbleibende Zeit" : "Ohne Zeitlimit: so lange läuft die Prüfung schon");
        _answeredTop = Ui.Text("", 14, FontWeight.Medium, P.TextSecondary);
        _answeredTop.FontFeatures = FontFeatureCollection.Parse("tnum");
        _answeredTopView = _answeredTop;
        var cap = Ui.Glass(Ui.H(14, clock, _answeredTop), 999, new Thickness(18, 0), strong: true, shadow: false);
        cap.Height = 40;
        UpdateClock();
        UpdateAnswered();
        return cap;
    }

    void UpdateClock()
    {
        if (_clock is null || _clockView is null) return;
        bool limited = _settings.Minutes > 0;
        int seconds = limited
            ? Math.Max(0, (int)Math.Ceiling(RemainingMs / 1000))
            : Math.Max(0, (int)((TimeUtil.NowMs() - _startedAt) / 1000));
        bool lastMinute = limited && seconds <= 60;
        _clock.Text = ExamTime.Clock(seconds);
        if (_clockWarns != lastMinute)
        {
            _clockWarns = lastMinute;
            var color = lastMinute ? P.Warning.Text : P.Text;
            _clock.Foreground = WsTheme.B(color);
            _clockIcon.Child = Icons.Icon(IconName.Clock, 17, color, 2);
        }
        AutomationProperties.SetName(_clockView, $"{(limited ? "Verbleibende Zeit" : "Verstrichene Zeit")}: {ExamTime.Spoken(seconds)}");
    }

    /// <summary>The answered questions: "5/20" on top, the pill in the bar, the filled number circles.</summary>
    void UpdateAnswered()
    {
        int answered = AnsweredCount, total = _questions.Count;
        if (_answeredTop is not null)
        {
            _answeredTop.Text = $"{answered}/{total}";
            if (_answeredTopView is not null) ToolTip.SetTip(_answeredTopView, $"{answered} von {total} Fragen beantwortet");
            AutomationProperties.SetName(_answeredTop, $"{answered} von {total} Fragen beantwortet");
        }
        if (_answeredPill is not null) _answeredPill.Text = $"{answered} von {total} beantwortet";
        _answeredLine?.SetValue(total == 0 ? 0 : (double)answered / total, Motion.Snappy);
        foreach (var q in _questions) UpdateRow(q.Number);
    }

    // MARK: Sheet

    /// <summary>
    /// Every question on one page, numbered, each with its answer field, in one panel (Mac: ExamSheetView). Enter moves
    /// to the next question, Ctrl+Enter hands the exam in.
    /// </summary>
    Control SheetView()
    {
        var set = Set;
        var list = new StackPanel();
        _rows.Clear();
        foreach (var q in _questions)
        {
            if (q.Number > 1) list.Children.Add(new Border { Height = 1, Background = WsTheme.B(P.Hairline), Margin = new Thickness(20 + 34 + 12, 0, 0, 0) });
            list.Children.Add(QuestionRow(q, set));
        }
        // The focused row's band follows the panel's corners.
        var panel = Ui.Glass(list, 22, new Thickness(0), shadow: false);
        panel.ClipToBounds = true;

        // "20 Fragen · Antworten auf Französisch" and the keys (Mac: ExamSheetView.intro).
        var introLabel = Ui.H(8, Icons.Icon(IconName.Stack, 15, P.TextSecondary), Ui.Text(IntroText(set), 14, FontWeight.Medium, P.TextSecondary));
        var keys = Ui.H(6, Ui.KeyCap("↵"), Ui.Text("nächste Frage", 12, color: P.TextTertiary), new Border { Width = 4 }, Ui.KeyCap("Ctrl ↵"), Ui.Text("abgeben", 12, color: P.TextTertiary));
        AutomationProperties.SetAccessibilityView(keys, AccessibilityView.Raw);
        keys.IsVisible = AppDevice.ShowsKeyHints;
        var intro = Ui.Row(introLabel, keys, 12);
        intro.Margin = new Thickness(4, 0);

        var stack = Ui.V(14, intro, panel);
        stack.MaxWidth = 820;
        stack.Margin = PageMargin(18);
        // Prompt and answer side by side from 640 points, else one under the other (Mac: isWide).
        stack.SizeChanged += (_, e) =>
        {
            bool wide = e.NewSize.Width >= 640;
            if (wide == _wide) return;
            _wide = wide;
            foreach (var row in _rows.Values) ApplyLayout(row);
        };
        return stack;
    }

    string IntroText(VocabSet? set)
    {
        var count = Labels.Plural(_questions.Count, "Frage", "Fragen");
        var langs = _questions.Select(q => q.AnswerLang).Distinct().ToList();
        if (set is null || langs.Count != 1 || langs[0] == Lang.Other || set.TermLang == set.DefLang) return count;
        return $"{count} · Antworten auf {Labels.LangName(langs[0])}";
    }

    /// <summary>"Französisch", or "Begriff"/"Definition" when both sides share a language (Mac: promptLabel).</summary>
    static string PromptLabel(ExamQuestion q, VocabSet? set)
    {
        if (set is null || set.TermLang == set.DefLang || q.PromptLang == Lang.Other) return q.Ask == AskSide.Term ? "Definition" : "Begriff";
        return Labels.LangName(q.PromptLang);
    }

    static string Placeholder(ExamQuestion q, VocabSet? set) =>
        set is null || set.TermLang == set.DefLang || q.AnswerLang == Lang.Other ? "Antwort" : $"Auf {Labels.LangName(q.AnswerLang)} …";

    /// <summary>One question: its number in a circle, the language above the prompt, the answer field (Mac: ExamQuestionRow).</summary>
    Control QuestionRow(ExamQuestion q, VocabSet? set)
    {
        int number = q.Number;
        var label = PromptLabel(q, set);
        if (!_fields.TryGetValue(number, out var field))
        {
            field = Ui.Field(Placeholder(q, set), "", 16, 44);
            if (q.AnswerLang.IsRTL()) field.FlowDirection = FlowDirection.RightToLeft;
            Study.StudyAnswerBox.ForAnswers(field, q.AnswerLang);
            AutomationProperties.SetName(field, $"Antwort zu Frage {number}");
            field.KeyDown += (_, e) =>
            {
                if (e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.None)
                {
                    // Enter moves to the next question (the last one keeps the focus; Ctrl+Enter hands in).
                    if (_fields.TryGetValue(number + 1, out var next))
                    {
                        next.Focus();
                        next.BringIntoView();
                    }
                    e.Handled = true;
                }
            };
            field.TextChanged += (_, _) => UpdateAnswered();
            field.GotFocus += (_, _) =>
            {
                if (_accents.TryGetValue(number, out var a)) a.IsVisible = true;
                UpdateRow(number);
            };
            field.LostFocus += (_, _) =>
            {
                if (_accents.TryGetValue(number, out var a)) a.IsVisible = false;
                UpdateRow(number);
            };
            _fields[number] = field;
        }
        else if (field.Parent is Panel old) old.Children.Remove(field);
        Control answer = field;
        if (SpecialCharacterBar.Create(q.AnswerLang, field) is { } accents)
        {
            accents.IsVisible = field.IsFocused;
            _accents[number] = accents;
            answer = Ui.V(8, field, accents);
        }

        var eyebrow = Ui.Eyebrow(label);
        AutomationProperties.SetAccessibilityView(eyebrow, AccessibilityView.Raw);
        var prompt = StudyText.InLang(q.Prompt, q.PromptLang, 19, FontWeight.SemiBold, font: WsTheme.Prompt);
        prompt.TextWrapping = TextWrapping.Wrap;
        prompt.TextTrimming = TextTrimming.None;
        AutomationProperties.SetName(prompt, $"Frage {number}, {label}: {q.Prompt}");
        var promptStack = Ui.V(4, eyebrow, prompt);

        var badgeText = Ui.Text($"{number}", 13, FontWeight.Bold, font: WsTheme.Prompt);
        badgeText.HorizontalAlignment = HorizontalAlignment.Center;
        var badge = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(17), Child = badgeText, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
        AutomationProperties.SetAccessibilityView(badge, AccessibilityView.Raw);

        var layout = new Grid();
        layout.Children.Add(promptStack);
        layout.Children.Add(answer);
        var content = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 12 };
        content.Children.Add(badge);
        Grid.SetColumn(layout, 1);
        content.Children.Add(layout);
        var band = new Border { Child = content, Padding = new Thickness(20, 12) };
        var row = new SheetRow(band, badge, badgeText, layout, promptStack, answer);
        _rows[number] = row;
        ApplyLayout(row);
        UpdateRow(number);
        return band;
    }

    /// <summary>Side by side in wide windows (the field 290 wide), one under the other in narrow ones.</summary>
    void ApplyLayout(SheetRow row)
    {
        var g = row.Layout;
        g.ColumnDefinitions.Clear();
        g.RowDefinitions.Clear();
        if (_wide)
        {
            g.ColumnDefinitions = new ColumnDefinitions("*,290");
            g.ColumnSpacing = 20;
            g.RowSpacing = 0;
            Grid.SetRow(row.Answer, 0);
            Grid.SetColumn(row.Answer, 1);
        }
        else
        {
            g.RowDefinitions = new RowDefinitions("Auto,Auto");
            g.ColumnSpacing = 0;
            g.RowSpacing = 8;
            Grid.SetRow(row.Answer, 1);
            Grid.SetColumn(row.Answer, 0);
        }
        row.Answer.VerticalAlignment = VerticalAlignment.Top;
    }

    /// <summary>The number circle fills once the question is answered; the focused row gets a soft accent band.</summary>
    void UpdateRow(int number)
    {
        if (!_rows.TryGetValue(number, out var row)) return;
        bool focused = _fields.TryGetValue(number, out var field) && field.IsFocused;
        bool answered = field is not null && HasText(field.Text);
        row.Band.Background = focused ? new SolidColorBrush(P.AccentSoft, 0.5) : Brushes.Transparent;
        row.Badge.Background = answered ? ProgressLine.Gradient(P.Accent) : new SolidColorBrush(P.AccentSoft, focused ? 1 : 0.6);
        row.BadgeText.Foreground = WsTheme.B(answered ? Colors.White : focused ? P.AccentText : P.TextSecondary);
    }

    /// <summary>For the snapshot tool: starts the exam and fills the answers (null: left open).</summary>
    public void FillForSnapshot(Func<ExamQuestion, string?> answer)
    {
        Start();
        foreach (var q in _questions)
            if (answer(q) is { } text && _fields.TryGetValue(q.Number, out var field)) field.Text = text;
    }

    /// <summary>For the snapshot tool: starts the exam (unless running), fills the answers and hands it in.</summary>
    public void RunForSnapshot(Func<ExamQuestion, string> answer)
    {
        FillForSnapshot(answer);
        HandIn();
    }

    void HandIn(bool timedOut = false)
    {
        if (_stage != Stage.Sheet || Set is not { } set) return;
        _timer?.Stop();
        var answers = _fields.ToDictionary(f => f.Key, f => f.Value.Text ?? "");
        _result = Core.Exam.Evaluate(_questions, answers, set.Cards, _settings.Tolerance, TimeUtil.NowMs() - _startedAt, timedOut);
        _stage = Stage.Results;
        // Mac: KeyActionGate – a key pressed for the next question must not end the results unseen.
        _keysBlockedUntil = TimeUtil.NowMs() + (timedOut ? 1200 : 280);
        _resultAppeared = true;
        if (Core.Exam.Passes(_result.Grade)) Services.Haptics.Success();
        else Services.Haptics.Failure();
        Model.Sounds.Play(Core.Exam.Passes(_result.Grade) ? Services.SoundEffects.Sound.Finished : Services.SoundEffects.Sound.RoundDone);
        if (timedOut) Model.ShowToast(new ToastMessage("Die Zeit ist um. Deine Prüfung wurde abgegeben.", ToastTone.Warning));
        Announcer.Announce($"Note {Core.Exam.GradeText(_result.Grade)}. {ExamCopy.ScoreLine(_result)}.");
        base.Refresh();
        _resultAppeared = false;
    }

    // MARK: Results

    Control ResultsView()
    {
        var r = _result!;
        var stack = Ui.V(32, GradeHero(r), ResultTiles(r), AnswerList(r));
        stack.MaxWidth = 820;
        stack.Margin = PageMargin(24);
        if (r.Grade < 5.5) return stack;
        // Confetti for a grade of 5.5 or more (Mac: ExamCelebration), only when the results appear.
        var layer = new Grid();
        layer.Children.Add(stack);
        layer.Children.Add(new CelebrationView { Origin = new Point(0.5, 0.1), PlaysOnAttach = _resultAppeared });
        return layer;
    }

    /// <summary>The grade in a large circle that settles in, the verdict, the points and the time (Mac: ExamGradeHero).</summary>
    Control GradeHero(ExamResult r)
    {
        double grade = r.Grade;
        // Green from 5, the accent from 4, amber below (Mac: ExamGradeStyle).
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
        AutomationProperties.SetName(circle, $"Note {Core.Exam.GradeText(grade)}");
        if (_resultAppeared) Effects.Of(circle).Enter(new Placement(Scale: 0.86, Opacity: 0), Motion.Arrive(0.6).Delayed(0.1));
        int seconds = (int)Math.Round(r.ElapsedMs / 1000);
        var verdict = Ui.Text(Core.Exam.Verdict(grade), 34, FontWeight.Bold, wrap: TextWrapping.Wrap, font: WsTheme.Prompt, align: TextAlignment.Center);
        AutomationProperties.SetHeadingLevel(verdict, 1);
        var subtitle = Ui.Text($"{ExamCopy.ScoreLine(r)} in {ExamTime.Clock(seconds)}", 18, color: P.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        verdict.HorizontalAlignment = subtitle.HorizontalAlignment = HorizontalAlignment.Center;
        var hero = Ui.V(10, circle, verdict, subtitle);
        circle.Margin = new Thickness(0, 0, 0, 8);
        if (r.TimedOut)
        {
            var late = Ui.H(8, Icons.Icon(IconName.Clock, 16, P.Warning.Text, 2), Ui.Text("Die Zeit war um, die Prüfung wurde abgegeben.", 14, FontWeight.Medium, P.Warning.Text));
            late.HorizontalAlignment = HorizontalAlignment.Center;
            hero.Children.Add(late);
        }
        return hero;
    }

    /// <summary>Richtig · Kleine Fehler · Falsch · Ohne Antwort (only when there are any), with what each is worth (Mac: ExamResultTiles).</summary>
    Control ResultTiles(ExamResult r)
    {
        var minorCaption = r.Tolerance switch
        {
            ExamTolerance.Strict => "kein Punkt",
            ExamTolerance.Half => "je ½ Punkt",
            _ => "ganzer Punkt",
        };
        var tiles = new List<Control>
        {
            StatTile.Create("Richtig", $"{r.Count(ExamMark.Correct)}", IconName.Check, P.Success.Fill, caption: "ganzer Punkt"),
            StatTile.Create("Kleine Fehler", $"{r.Count(ExamMark.Minor)}", IconName.CheckCircle, P.Info.Fill, caption: minorCaption),
            StatTile.Create("Falsch", $"{r.Count(ExamMark.Wrong)}", IconName.X, P.Failure.Fill, caption: "kein Punkt"),
        };
        int blank = r.Count(ExamMark.Blank);
        if (blank > 0) tiles.Add(StatTile.Create("Ohne Antwort", $"{blank}", IconName.Minimize, P.New.Fill, caption: "kein Punkt"));
        return StatTile.Row(12, tiles.ToArray());
    }

    /// <summary>"Deine Antworten" with what a small mistake cost, then every answer in the order of the sheet (Mac: ExamAnswerList).</summary>
    Control AnswerList(ExamResult r)
    {
        var set = Set;
        var title = Ui.Text("Deine Antworten", 22, FontWeight.SemiBold, font: WsTheme.Prompt);
        AutomationProperties.SetHeadingLevel(title, 2);
        var tolerance = Ui.Text(ExamCopy.ToleranceText(r.Tolerance), 14, color: P.TextSecondary);
        ToolTip.SetTip(tolerance, ExamCopy.SmallMistakesText);
        var head = Ui.Row(title, tolerance, 8);
        head.Margin = new Thickness(4, 0);
        var list = new StackPanel();
        foreach (var item in r.Items)
        {
            if (item.Question.Number > 1) list.Children.Add(new Border { Height = 1, Background = WsTheme.B(P.Hairline), Margin = new Thickness(20 + 28 + 12, 0, 0, 0) });
            list.Children.Add(AnswerRow(item, PromptLabel(item.Question, set)));
        }
        var panel = Ui.Glass(list, 22, new Thickness(0), shadow: false);
        panel.ClipToBounds = true;
        return Ui.V(10, head, panel);
    }

    /// <summary>One answer: the mark, the question, what was typed (mistakes marked) and the right answer, the note and the points (Mac: ExamAnswerRow).</summary>
    Control AnswerRow(ExamItemResult item, string promptLabel)
    {
        var q = item.Question;
        const double answerSize = 17;
        var number = Ui.Text($"{q.Number}.", 14, FontWeight.SemiBold, P.TextTertiary);
        number.FontFeatures = FontFeatureCollection.Parse("tnum");
        var prompt = StudyText.InLang(q.Prompt, q.PromptLang, 14, color: P.TextSecondary);
        prompt.TextWrapping = TextWrapping.Wrap;
        prompt.TextTrimming = TextTrimming.None;
        var promptLine = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 6 };
        promptLine.Children.Add(number);
        Grid.SetColumn(prompt, 1);
        promptLine.Children.Add(prompt);

        var middle = Ui.V(6, promptLine);
        Control Wrapped(TextBlock t)
        {
            t.TextWrapping = TextWrapping.Wrap;
            t.TextTrimming = TextTrimming.None;
            t.HorizontalAlignment = HorizontalAlignment.Left;
            return t;
        }
        bool expected = true;
        string spokenAnswer;
        switch (item.Mark)
        {
            case ExamMark.Correct:
                middle.Children.Add(Wrapped(StudyText.InLang(item.Given, q.AnswerLang, answerSize, FontWeight.Medium, P.Success.Text)));
                expected = item.Synonym;
                spokenAnswer = item.Given;
                break;
            case ExamMark.Minor or ExamMark.Wrong:
                // A synonym is compared with its own word, not with the one that was asked.
                middle.Children.Add(Wrapped(StudyText.Diff(item.Given, item.Matched ?? q.Expected, q.AnswerLang, answerSize)));
                spokenAnswer = item.Given;
                break;
            default:
                middle.Children.Add(Ui.Text("Keine Antwort", answerSize, color: P.TextTertiary));
                spokenAnswer = "Keine Antwort";
                break;
        }
        // "Richtig: la maison", or "Gesucht war:" when the answer was right (a synonym) or matched another card.
        var expectedLabel = item.Mark == ExamMark.Correct || item.Matched is not null ? "Gesucht war:" : "Richtig:";
        if (expected)
        {
            var value = Wrapped(StudyText.InLang(q.Expected, q.AnswerLang, 14, FontWeight.SemiBold, P.Success.Text));
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 6 };
            line.Children.Add(Ui.Text(expectedLabel, 14, color: P.TextSecondary));
            Grid.SetColumn(value, 1);
            line.Children.Add(value);
            middle.Children.Add(line);
        }
        if (item.Note is { } note)
        {
            bool info = item.Mark is ExamMark.Correct or ExamMark.Minor;
            middle.Children.Add(Ui.Chip(note, info ? P.Info : P.Warning, info ? IconName.Info : IconName.Lightbulb));
        }

        var (pointsText, pointsLabel) = item.Points switch
        {
            1 => ("1", "1 Punkt"),
            0.5 => ("½", "ein halber Punkt"),
            _ => ("0", "kein Punkt"),
        };
        var points = Ui.Text(pointsText, 17, FontWeight.Bold, item.Points > 0 ? P.Text : P.TextTertiary, font: WsTheme.Prompt, align: TextAlignment.Right);
        points.MinWidth = 28;
        points.VerticalAlignment = VerticalAlignment.Top;

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 12 };
        grid.Children.Add(MarkBadge(item));
        Grid.SetColumn(middle, 1);
        grid.Children.Add(middle);
        Grid.SetColumn(points, 2);
        grid.Children.Add(points);
        var row = new Border { Child = grid, Padding = new Thickness(20, 12) };
        // One element for the screen reader (Mac: accessibilityElement(children: .combine)).
        var spoken = new List<string> { $"{q.Number}. {promptLabel}: {q.Prompt}", spokenAnswer };
        if (expected) spoken.Add($"{expectedLabel} {q.Expected}");
        if (item.Note is { } n) spoken.Add(n);
        spoken.Add($"{ExamCopy.MarkLabel(item)}, {pointsLabel}");
        AutomationProperties.SetName(row, string.Join(". ", spoken));
        return row;
    }

    /// <summary>✓, ½, ✗ or – in a coloured circle (Mac: ExamMarkBadge).</summary>
    Control MarkBadge(ExamItemResult item)
    {
        // A small mistake worth half a point gets "½" on blue; worth a whole point or none, it looks right or wrong.
        StatusPalette palette = P.New;
        IconName? icon = IconName.Minimize;
        switch (item.Mark)
        {
            case ExamMark.Correct:
            case ExamMark.Minor when item.Points >= 1:
                (palette, icon) = (P.Success, IconName.Check);
                break;
            case ExamMark.Minor when item.Points > 0:
                (palette, icon) = (P.Info, null);
                break;
            case ExamMark.Minor:
            case ExamMark.Wrong:
                (palette, icon) = (P.Failure, IconName.X);
                break;
        }
        Control symbol = icon is { } i ? Icons.Icon(i, 13, palette.Text, 2.6) : Ui.Text("½", 14, FontWeight.Bold, palette.Text, font: WsTheme.Prompt);
        symbol.HorizontalAlignment = HorizontalAlignment.Center;
        symbol.VerticalAlignment = VerticalAlignment.Center;
        var badge = new Border
        {
            Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Background = WsTheme.B(palette.Soft), Child = symbol,
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 0, 0),
        };
        AutomationProperties.SetName(badge, ExamCopy.MarkLabel(item));
        return badge;
    }

    // MARK: Actions and keys

    Control ActionBar()
    {
        switch (_stage)
        {
            case Stage.Setup:
            {
                var pill = BarPill(Ui.H(8, Icons.Icon(IconName.Stack, 15, P.TextSecondary), Ui.Text(SetupSummary(), 14, FontWeight.Medium, P.TextSecondary)));
                return StudyActionBarView.Create(pill, [
                    Ui.Secondary("Zurück zum Lernset", Exit, keyHint: "Esc", height: 44),
                    Ui.Primary("Prüfung starten", Start, "↵", IconName.Exam, height: 44),
                ]);
            }
            case Stage.Sheet:
            {
                // "5 von 20 beantwortet" with its line (Mac: ExamSheetView's ExamBarPill).
                _answeredPill = Ui.Text("", 14, FontWeight.Medium, P.TextSecondary);
                _answeredPill.FontFeatures = FontFeatureCollection.Parse("tnum");
                _answeredLine = new ProgressLine(0, P.Accent, 80);
                var pill = BarPill(Ui.H(10, _answeredPill, _answeredLine));
                UpdateAnswered();
                return StudyActionBarView.Create(pill, [Ui.Primary("Abgeben", RequestHandIn, "Ctrl ↵", IconName.Check, height: 44)], 820);
            }
            default:
                return new ViewThatFits(ResultsBar);
        }
    }

    /// <summary>
    /// "Neue Prüfung" on the left; "Falsche lernen", "Falsche prüfen" (when something went wrong) and "Fertig ↵" on the
    /// right; short labels when the bar does not fit (Mac: ExamResultsView.bar).
    /// </summary>
    Control ResultsBar(bool compact)
    {
        var r = _result!;
        int toPractise = r.CardIdsToPractise.Count;
        var again = StudyChrome.Floating(Ui.Secondary(compact ? "Neu" : "Neue Prüfung", RequestNewExam, IconName.RotateCcw, "Ctrl ⇧ R", 44));
        again.Focusable = false;
        ToolTip.SetTip(again, "Eine neue Prüfung mit diesem Lernset einrichten (Ctrl+Shift+R)");
        var items = new List<Control?>();
        if (toPractise > 0)
        {
            var questions = Labels.Plural(toPractise, "Frage", "Fragen");
            var learn = Ui.Secondary(compact ? "Lernen" : "Falsche lernen", LearnMistakes, IconName.Sparkles, height: 44);
            ToolTip.SetTip(learn, $"Die {questions} mit Fehlern in Lernen üben");
            var retake = Ui.Secondary(compact ? "Prüfen" : "Falsche prüfen", RetakeMistakes, IconName.Exam, height: 44);
            ToolTip.SetTip(retake, $"Eine neue Prüfung nur mit den {questions} mit Fehlern");
            items.Add(learn);
            items.Add(retake);
        }
        var done = Ui.Primary("Fertig", Exit, "↵", height: 44);
        if (AppDevice.IsPhone)
        {
            // Phone: «Neue Prüfung» as a round button beside «Fertig» – as a line of its own the bar took three lines
            // (a fifth of the screen) under the results.
            var renew = StudyChrome.FloatingIconButton(IconName.RotateCcw, "Neue Prüfung", RequestNewExam);
            AutomationProperties.SetName(renew, "Neue Prüfung");
            var last = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 8 };
            last.Children.Add(renew);
            StudyChrome.Floating(done);
            done.Focusable = false;
            done.HorizontalAlignment = HorizontalAlignment.Stretch;
            if (done.Chrome.Child is { } inner) inner.HorizontalAlignment = HorizontalAlignment.Center;
            Grid.SetColumn(done, 1);
            last.Children.Add(done);
            items.Add(last);
            return StudyActionBarView.Create(null, items);
        }
        items.Add(done);
        return StudyActionBarView.Create(again, items, 820);
    }

    /// <summary>A quiet glass pill on the left of the bar (Mac: ExamBarPill).</summary>
    static Control BarPill(Control content)
    {
        var pill = Ui.Glass(content, 999, new Thickness(16, 0), strong: true, shadow: false);
        pill.Height = 44;
        pill.VerticalAlignment = VerticalAlignment.Center;
        return pill;
    }

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        if (isRepeat) return false;
        if (TimeUtil.NowMs() < _keysBlockedUntil) return true;
        bool enter = e.Key is Key.Enter or Key.Return;
        if (e.Key == Key.R && e.KeyModifiers == (KeyModifiers.Control | KeyModifiers.Shift) && _stage != Stage.Setup)
        {
            RequestNewExam();
            return true;
        }
        switch (_stage)
        {
            case Stage.Setup when enter && e.KeyModifiers == KeyModifiers.None:
                if (IsEmpty) AddCards();
                else Start();
                return true;
            case Stage.Sheet when enter && e.KeyModifiers == KeyModifiers.Control:
                RequestHandIn();
                return true;
            case Stage.Results when enter && e.KeyModifiers == KeyModifiers.None:
                Exit();
                return true;
        }
        if (e.Key == Key.Escape && e.KeyModifiers == KeyModifiers.None)
        {
            // During the exam the leave guard asks first.
            Exit();
            return true;
        }
        return false;
    }
}

/// <summary>Times of the exam (Mac: ExamTime in ExamScreen.swift).</summary>
public static class ExamTime
{
    /// <summary>"8:05", "1:02:05".</summary>
    public static string Clock(int seconds)
    {
        int s = Math.Max(0, seconds);
        int h = s / 3600, m = s % 3600 / 60, sec = s % 60;
        return h > 0 ? $"{h}:{m:00}:{sec:00}" : $"{m}:{sec:00}";
    }

    /// <summary>"8 Minuten 5 Sekunden" (screen reader).</summary>
    public static string Spoken(int seconds)
    {
        int m = Math.Max(0, seconds) / 60, s = Math.Max(0, seconds) % 60;
        if (m == 0) return Labels.Plural(s, "Sekunde", "Sekunden");
        return s == 0 ? Labels.Plural(m, "Minute", "Minuten") : $"{Labels.Plural(m, "Minute", "Minuten")} {Labels.Plural(s, "Sekunde", "Sekunden")}";
    }
}
