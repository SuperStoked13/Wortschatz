using System.Globalization;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Services;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Overview;

/// <summary>
/// The overview (Mac: OverviewScreen.swift, OverviewHero.swift, OverviewSetGrid.swift): date, greeting and a line
/// about today, the three statistics tiles, the "Weiterlernen" hero (Enter), then "Deine Lernsets" with a sort control
/// and the grid of set cards behind the dashed "Neues Lernset" card. Without sets: the empty state.
/// </summary>
public sealed class OverviewScreen(AppModel model, MainView window) : Screen(model, window)
{
    /// <summary>Sorting by name stays Swiss German (the date follows the app's language, <see cref="DayLabel"/>).</summary>
    static readonly CultureInfo DeCh = CultureInfo.GetCultureInfo("de-CH");

    protected override Control Build()
    {
        var library = Model.Library;
        var now = DateTime.Now;
        _shownClock = ClockText(now, library.Now, library);
        var content = new StackPanel { Spacing = AppDevice.IsPhone ? 18 : 26, Margin = AppDevice.IsPhone ? new Thickness(8, 4, 8, 24) : new Thickness(34, 14, 34, 34), MaxWidth = 1180 };
        if (library.IsEmpty)
        {
            content.Children.Add(Header(now, L("Schön, dass du da bist. Leg dein erstes Lernset an und starte direkt.")));
            content.Children.Add(EmptyLibrary());
            content.Children.Add(Steps());
            return Ui.Scroll(content);
        }
        content.Children.Add(Header(now, LeadText(library)));
        content.Children.Add(Stats(library.Stats));
        if (Hero(library) is { } hero) content.Children.Add(hero);
        content.Children.Add(SetGrid(library));
        return Ui.Scroll(content);
    }

    // MARK: Header

    static Control Header(DateTime now, string lead)
    {
        var p = WsTheme.P;
        return Ui.V(4, Ui.Eyebrow(DayLabel(now)), Ui.Title(Greeting(now), 34), Ui.Text(lead, 17, color: p.TextSecondary, wrap: TextWrapping.Wrap));
    }

    static string Greeting(DateTime now) => now.Hour switch { >= 5 and < 11 => L("Guten Morgen"), >= 11 and < 18 => L("Guten Tag"), _ => L("Guten Abend") };

    /// <summary>
    /// What of the page follows the clock: the greeting, the date and when each set was last studied («vor 5 Minuten»,
    /// on the cards and in the hero), worked out for the time <paramref name="nowMs"/>.
    /// </summary>
    string ClockText(DateTime now, double nowMs, LibrarySnapshot library)
    {
        var text = new System.Text.StringBuilder(Greeting(now)).Append('\n').Append(DayLabel(now));
        foreach (var summary in library.Sets)
            if (summary.Set.LastStudiedAt is { } last) text.Append('\n').Append(TimeUtil.RelativeTime(last, nowMs, Model.Store.TimeZone));
        return text.ToString();
    }

    string? _shownClock;

    /// <summary>
    /// "Montag, 12. Oktober"; in English the weekday and the system's order of day and month ("Monday, October 12" or
    /// "Monday, 12 October"; Mac: OverviewHeader.dayLabel with AppLanguage.formattingLocale).
    /// </summary>
    static string DayLabel(DateTime now)
    {
        var culture = AppLanguage.FormattingCulture;
        string pattern = AppLanguage.Current == "en" ? "dddd, " + culture.DateTimeFormat.MonthDayPattern : "dddd, d. MMMM";
        return now.ToString(pattern, culture);
    }

    /// <summary><c>leadText</c> of dashboard.js.</summary>
    static string LeadText(LibrarySnapshot library)
    {
        var streak = library.Stats.Streak;
        if (streak.Today > 0) return L($"Heute schon {Labels.Plural(streak.Today, "Antwort", "Antworten")} – weiter so!");
        if (streak.Current > 0) return L($"Lerne heute, damit deine Serie von {Labels.Plural(streak.Current, "Tag", "Tagen")} weiterläuft.");
        if (library.Resume is not null) return L("Mach dort weiter, wo du aufgehört hast.");
        return L("Bereit für ein paar Wörter? Wähle ein Lernset und leg los.");
    }

    Control EmptyLibrary()
    {
        var p = WsTheme.P;
        WsButton[] actions =
        [
            Ui.Primary(L("Erstes Lernset erstellen"), () => Model.OpenEditor(), icon: IconName.Plus),
            Ui.Secondary(L("Liste einfügen"), () => Model.OpenEditor(startWithImport: true), IconName.Copy),
            Ui.Secondary(L("Backup laden"), () => _ = Settings.SettingsScreen.ImportBackup(Model, Window), IconName.Upload),
        ];
        // Phone: the actions one under the other, across the card.
        if (AppDevice.IsPhone)
            foreach (var a in actions)
            {
                a.HorizontalAlignment = HorizontalAlignment.Stretch;
                if (a.Chrome.Child is { } inner) inner.HorizontalAlignment = HorizontalAlignment.Center;
            }
        var body = Ui.V(14,
            Icons.Icon(IconName.Stack, 40, p.Accent),
            Ui.Text(L("Noch keine Lernsets"), 24, FontWeight.Bold),
            Ui.Text(L("Erstelle dein erstes Lernset aus einer Vokabelliste – in wenigen Sekunden kannst du mit Lernen loslegen."), 15, color: p.TextSecondary, wrap: TextWrapping.Wrap),
            AppDevice.IsPhone ? Ui.V(8, actions) : Ui.H(10, actions));
        body.MaxWidth = 620;
        body.HorizontalAlignment = HorizontalAlignment.Left;
        return Ui.Hero(body, AppDevice.IsPhone ? new Thickness(20, 20) : new Thickness(34, 30));
    }

    static (IconName Icon, string Title, string Text)[] StepTexts =>
    [
        (IconName.Copy, L("Liste einfügen"), AppDevice.ReadsPhotos ? L("Wortschatz erkennt Begriffe und Übersetzungen automatisch – auch aus Fotos und PDFs.")
            : L("Wortschatz erkennt Begriffe und Übersetzungen automatisch – auch aus PDFs.")),
        (IconName.Sparkles, L("Lernen"), L("Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst – bis alles sitzt.")),
        (IconName.Trophy, L("Fortschritt sehen"), L("Zweimal in Folge richtig – und ein Begriff gilt als gemeistert.")),
    ];

    /// <summary>The three "how it works" steps below the empty state, equally high (Mac: OverviewEmptyState's StepTile).</summary>
    static Control Steps()
    {
        var p = WsTheme.P;
        // Phone: the steps one under the other.
        bool phone = AppDevice.IsPhone;
        var grid = phone
            ? new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto"), RowSpacing = 10 }
            : new Grid { ColumnDefinitions = new ColumnDefinitions("*,*,*"), ColumnSpacing = 12 };
        for (int i = 0; i < StepTexts.Length; i++)
        {
            var (icon, title, text) = StepTexts[i];
            var symbol = new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(10), Background = WsTheme.B(p.AccentSoft), Child = Icons.Icon(icon, 18, p.AccentText, 2), HorizontalAlignment = HorizontalAlignment.Left };
            symbol.Child!.HorizontalAlignment = HorizontalAlignment.Center;
            var heading = Ui.Text($"{i + 1}. {title}", 15.5, FontWeight.Bold);
            var tile = new Border
            {
                Child = Ui.V(8, symbol, heading, Ui.Text(text, 13.5, color: p.TextSecondary, wrap: TextWrapping.Wrap)),
                Padding = new Thickness(16),
                CornerRadius = new CornerRadius(18),
                Background = WsTheme.B(p.Dark ? Palette.Hex(0x1C1E2A, 0.55) : Palette.Hex(0xFFFFFF, 0.55)),
                BorderBrush = WsTheme.B(p.Hairline),
                BorderThickness = new Thickness(1),
            };
            AutomationProperties.SetName(tile, $"{i + 1}. {title}: {text}");
            if (phone) Grid.SetRow(tile, i);
            else Grid.SetColumn(tile, i);
            grid.Children.Add(tile);
        }
        return grid;
    }

    // MARK: Clock

    DispatcherTimer? _minuteTimer;

    /// <summary>
    /// Greeting, date and relative times stay current while the window stays open (Mac: TimelineView(.everyMinute)).
    /// Until 25.11.2026 the minute rebuilt the page with the snapshot's old time: «vor 5 Minuten» stayed until the
    /// library changed.
    /// </summary>
    public override void Activate()
    {
        // Back on the overview after a while (the snapshot is from the last change of the library): the times as of now.
        var library = Model.Library;
        if (ClockText(DateTime.Now, TimeUtil.NowMs(), library) != ClockText(DateTime.Now, library.Now, library)) Model.RefreshLibraryTime();
        base.Activate();
        _minuteTimer?.Stop();
        var now = DateTime.Now;
        // First at the next full minute, then every minute.
        _minuteTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60 - now.Second + 0.2) };
        _minuteTimer.Tick += (_, _) =>
        {
            _minuteTimer!.Interval = TimeSpan.FromMinutes(1);
            // Only when a text that follows the clock changed (not every minute when everything was studied days ago):
            // then with a snapshot of the time now. Not while the keyboard is on the page (a rebuild would drop the focus).
            if (Model.Prompt is not null || View.IsKeyboardFocusWithin) return;
            if (ClockText(DateTime.Now, TimeUtil.NowMs(), Model.Library) == _shownClock) return;
            Model.RefreshLibraryTime();
            Refresh();
        };
        _minuteTimer.Start();
    }

    public override void Deactivate()
    {
        _minuteTimer?.Stop();
        _minuteTimer = null;
    }

    // MARK: Statistics

    static Control Stats(OverviewStats stats)
    {
        var p = WsTheme.P;
        var streak = stats.Streak;
        // Phone: three tiles side by side are narrow – short labels keep each on one line (and the tiles low). Not
        // IsWide: the overview is built before the first size arrives (ViewWidth still the PC default then).
        bool phone = AppDevice.IsPhone;
        var tiles = StatTile.Row(phone ? 8 : 12,
            StatTile.Create(L("Lernserie"), $"{streak.Current}", IconName.Flame, streak.Current > 0 ? p.Flame : p.New.Fill, streak.Current == 1 ? L("Tag") : L("Tage"),
                LibrarySidebar.StreakCaption(streak)),
            StatTile.Create(phone ? L("Heute") : L("Heute beantwortet"), $"{streak.Today}", IconName.CheckCircle, streak.Today > 0 ? p.Accent : p.New.Fill,
                caption: phone ? L($"7 Tage: {stats.Week}") : L($"Letzte 7 Tage: {stats.Week}")),
            StatTile.Create(phone ? L("Gemeistert") : L("Begriffe gemeistert"), $"{stats.Mastered}", IconName.Trophy, stats.Mastered > 0 ? p.Mastered.Fill : p.New.Fill,
                caption: L($"von {Labels.Plural(stats.Total, "Begriff", "Begriffen")}")));
        if (streak.Longest > 0) ToolTip.SetTip(tiles.Children[0], L($"Längste Serie: {Labels.Plural(streak.Longest, "Tag", "Tage")}"));
        ToolTip.SetTip(tiles.Children[2], L("Ein Begriff gilt als gemeistert, wenn du ihn zweimal in Folge richtig beantwortest."));
        return tiles;
    }

    // MARK: Hero

    /// <summary>
    /// "Weiterlernen" for the latest unfinished Learn session (else Write session, "Fortsetzen"), otherwise the most
    /// recent set ("Öffnen") (Mac: OverviewHero).
    /// </summary>
    Control? Hero(LibrarySnapshot library)
    {
        var p = WsTheme.P;
        SetSummary summary;
        SetProgress counts;
        string eyebrow, meta, action;
        IconName eyebrowIcon, actionIcon;
        double? progress = null;
        // A resume item always carries its session; the checks keep a half-written library from crashing the page.
        if (library.Resume is { } resume && (resume.Mode == StudyMode.Learn ? resume.Summary.Learn is not null : resume.Summary.Write is not null))
        {
            summary = resume.Summary;
            if (resume.Mode == StudyMode.Learn && summary.Learn is { } learn)
            {
                counts = new SetProgress(learn.Counts.Total, learn.Counts.Mastered, learn.Counts.Learning, learn.Counts.Fresh, 0);
                eyebrow = L("Weiterlernen · Lernen");
                eyebrowIcon = IconName.Sparkles;
                meta = StudyCopy.Join(StudyCopy.SubsetLabel(learn.Subset, L("Ausgewählte Begriffe")), learn.RoundText, learn.MasteredText);
                progress = learn.ProgressValue;
                action = L("Weiterlernen");
            }
            else
            {
                var write = summary.Write!;
                counts = summary.Stats;
                eyebrow = L("Weiterlernen · Schreiben");
                eyebrowIcon = IconName.Keyboard;
                meta = StudyCopy.Join(write.RoundText, write.Counters.Total > 0 ? L($"{write.Counters.Correct} von {write.Counters.Total} richtig") : null);
                progress = write.ProgressValue;
                action = L("Fortsetzen");
            }
            actionIcon = IconName.Play;
        }
        else if (library.Sets.Count > 0)
        {
            summary = library.Sets[0];
            counts = summary.Stats;
            eyebrow = summary.Set.LastStudiedAt is not null ? L("Zuletzt gelernt") : L("Zuletzt bearbeitet");
            eyebrowIcon = IconName.Clock;
            meta = StudyCopy.Terms(summary.Stats.Total) + " · " + (summary.Set.LastStudiedAt is { } last
                ? TimeUtil.RelativeTime(last, library.Now, Model.Store.TimeZone) : L("noch nicht gelernt"));
            action = L("Öffnen");
            actionIcon = IconName.ChevronRight;
        }
        else return null;

        var gauge = new MasteryGauge(counts, MasteryGauge.Size.Medium, 1.25) { VerticalAlignment = VerticalAlignment.Center };
        var text = Ui.V(6,
            Ui.H(6, Icons.Icon(eyebrowIcon, 13, p.AccentText, 2.2), Ui.Eyebrow(eyebrow, p.AccentText)),
            Ui.Text(summary.Set.Title, 24, FontWeight.Bold, font: WsTheme.Prompt),
            Ui.H(8, Ui.Chip(Labels.LangPair(summary.Set.TermLang, summary.Set.DefLang)), Ui.Text(meta, 14, color: p.TextSecondary)));
        if (progress is { } value)
        {
            var bar = new ProgressLine(value, p.Accent, AppDevice.IsPhone ? 200 : 320) { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 0) };
            AutomationProperties.SetName(bar, L("Fortschritt"));
            AutomationProperties.SetHelpText(bar, L($"{(int)Math.Round(value * 100)} Prozent"));
            text.Children.Add(bar);
        }
        text.VerticalAlignment = VerticalAlignment.Center;
        var button = Ui.Primary(action, ResumeOrOpen, "↵", actionIcon, 48);
        if (AppDevice.IsPhone)
        {
            // Phone: ring and text side by side, the button under them across the card.
            var top = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 16 };
            top.Children.Add(gauge);
            Grid.SetColumn(text, 1);
            top.Children.Add(text);
            if (text.Children[1] is TextBlock titleBlock)
            {
                titleBlock.FontSize = 20;
                titleBlock.TextWrapping = TextWrapping.Wrap;
            }
            if (text.Children[2] is StackPanel metaRow && metaRow.Children.Count > 1 && metaRow.Children[1] is TextBlock metaText)
            {
                metaRow.Children.RemoveAt(1);
                metaText.TextWrapping = TextWrapping.Wrap;
                text.Children.Insert(3, metaText);
            }
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            if (button.Chrome.Child is { } inner) inner.HorizontalAlignment = HorizontalAlignment.Center;
            var phoneHero = Ui.Hero(Ui.V(16, top, button), new Thickness(18, 18), 26);
            AutomationProperties.SetName(phoneHero, eyebrow);
            AutomationProperties.SetHelpText(phoneHero, $"{summary.Set.Title}, {meta}");
            return phoneHero;
        }
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 24 };
        row.Children.Add(gauge);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        Grid.SetColumn(button, 2);
        row.Children.Add(button);
        var hero = Ui.Hero(row, new Thickness(28, 24));
        AutomationProperties.SetName(hero, eyebrow);
        AutomationProperties.SetHelpText(hero, $"{summary.Set.Title}, {meta}");
        return hero;
    }

    /// <summary>The hero's action (Enter): resume the running session, else open the most recent set.</summary>
    void ResumeOrOpen()
    {
        var library = Model.Library;
        if (library.Resume is { } resume) Model.Study(resume.Summary.Id, resume.Mode);
        else if (library.Sets.Count > 0) Model.OpenSet(library.Sets[0].Id);
    }

    // MARK: Sets

    /// <summary>The sort choices (computed: the labels follow the app's language).</summary>
    static (string Key, string Label)[] Sorts => [("recent", L("Zuletzt gelernt")), ("name", L("Name")), ("newest", L("Neueste"))];

    Control SetGrid(LibrarySnapshot library)
    {
        var p = WsTheme.P;
        var count = new Border
        {
            Child = Ui.Text($"{library.Sets.Count}", 13, FontWeight.SemiBold, p.TextSecondary),
            Background = WsTheme.B(p.KeyCap),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 2),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var sortKey = Model.Preferences.OverviewSort;
        int sortIndex = Math.Max(0, Array.FindIndex(Sorts, s => s.Key == sortKey));
        var sort = new WsSegmented(Sorts.Select(s => s.Label).ToList(), sortIndex, 118);
        ToolTip.SetTip(sort, L("Sortieren nach"));
        var grid = new AdaptiveGrid { MinItemWidth = 270, MaxItemWidth = 420, Spacing = 12 };
        void Fill()
        {
            grid.Children.Clear();
            // Phone: the big dashed card stood before one's own sets, as big as one of them (the + is in the bar
            // already, 06.11.2026) – there it comes last, a slim row (with no sets yet it stays first and big).
            bool slim = AppDevice.IsPhone && library.Sets.Count > 0;
            if (!slim) grid.Children.Add(NewSetCard());
            foreach (var summary in Sorted(library.Sets, Model.Preferences.OverviewSort)) grid.Children.Add(SetCard(summary, library.Now));
            if (slim) grid.Children.Add(NewSetCard(slim: true));
        }
        sort.SelectionChanged += i =>
        {
            Model.Preferences.OverviewSort = Sorts[i].Key;
            Fill();
        };
        Fill();
        var title = Ui.H(8, Ui.Text(L("Deine Lernsets"), 20, FontWeight.Bold, font: WsTheme.Prompt), count);
        if (AppDevice.IsPhone)
        {
            // Phone: the sort choice under the heading, across the width.
            sort.HorizontalAlignment = HorizontalAlignment.Stretch;
            return Ui.V(12, title, sort, grid);
        }
        var heading = Ui.Row(title, sort);
        return Ui.V(12, heading, grid);
    }

    /// <summary><c>sortItems</c> of dashboard.js ("recent" keeps the store order).</summary>
    static IEnumerable<SetSummary> Sorted(IReadOnlyList<SetSummary> sets, string key)
    {
        var compare = DeCh.CompareInfo;
        var options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.NumericOrdering;
        return key switch
        {
            "name" => sets.Select((s, i) => (s, i)).OrderBy(x => x.s.Set.Title, Comparer<string>.Create((a, b) => compare.Compare(a, b, options))).ThenBy(x => x.i).Select(x => x.s),
            "newest" => sets.Select((s, i) => (s, i)).OrderByDescending(x => x.s.Set.CreatedAt).ThenBy(x => x.i).Select(x => x.s),
            _ => sets,
        };
    }

    /// <summary>The dashed "Neues Lernset" card at the start of the grid (Mac: NewSetCard).</summary>
    Control NewSetCard(bool slim = false)
    {
        var p = WsTheme.P;
        if (slim)
        {
            var row = Ui.H(10, Icons.Icon(IconName.Plus, 18, p.AccentText, 2.4), Ui.Text(L("Neues Lernset"), 15, FontWeight.SemiBold, p.AccentText));
            row.HorizontalAlignment = HorizontalAlignment.Center;
            row.VerticalAlignment = VerticalAlignment.Center;
            var frame = new Grid { MinHeight = 52 };
            frame.Children.Add(new Avalonia.Controls.Shapes.Rectangle
            {
                RadiusX = 16,
                RadiusY = 16,
                StrokeThickness = 1.5,
                Stroke = new SolidColorBrush(p.Accent, 0.5),
                StrokeDashArray = [4, 3.3],
                Fill = new SolidColorBrush(p.Accent, 0.04),
            });
            frame.Children.Add(row);
            return Ui.Clickable(frame, () => Model.OpenEditor(), L("Neues Lernset"), 16, Colors.Transparent, Palette.Hex(Ui.Rgb(p.Accent), 0.08));
        }
        var plus = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(22), Background = WsTheme.B(p.AccentSoft), Child = Icons.Icon(IconName.Plus, 20, p.AccentText, 2.4) };
        plus.Child.HorizontalAlignment = HorizontalAlignment.Center;
        plus.Child.VerticalAlignment = VerticalAlignment.Center;
        plus.HorizontalAlignment = HorizontalAlignment.Center;
        var title = Ui.Text(L("Neues Lernset"), 15.5, FontWeight.Bold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var note = Ui.Text(AppDevice.ReadsPhotos ? L("Liste einfügen oder Datei, PDF oder Foto importieren") : L("Liste einfügen oder Datei oder PDF importieren"), 13, color: p.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        note.HorizontalAlignment = HorizontalAlignment.Center;
        var body = Ui.V(10, plus, Ui.V(2, title, note));
        body.VerticalAlignment = VerticalAlignment.Center;
        body.HorizontalAlignment = HorizontalAlignment.Center;
        var dashed = new Grid { MinHeight = 150 };
        dashed.Children.Add(new Avalonia.Controls.Shapes.Rectangle
        {
            RadiusX = 20,
            RadiusY = 20,
            StrokeThickness = 1.5,
            Stroke = new SolidColorBrush(p.Accent, 0.5),
            StrokeDashArray = [4, 3.3],
            Fill = new SolidColorBrush(p.Accent, 0.04),
        });
        body.Margin = new Thickness(18);
        dashed.Children.Add(body);
        var button = Ui.Clickable(dashed, () => Model.OpenEditor(), L("Neues Lernset"), 20, Colors.Transparent, Palette.Hex(Ui.Rgb(p.Accent), 0.08));
        button.VerticalAlignment = VerticalAlignment.Stretch;
        button.VerticalContentAlignment = VerticalAlignment.Stretch;
        dashed.VerticalAlignment = VerticalAlignment.Stretch;
        ToolTip.SetTip(button, L("Neues Lernset (Ctrl+N)"));
        return button;
    }

    /// <summary>
    /// A set card: language pair, title, count and ring, the status bar, then the status line and a quick
    /// "Lernen" / "Weiterlernen" (Mac: OverviewSetCard). The card opens the set; right click shows its actions.
    /// </summary>
    Control SetCard(SetSummary summary, double now)
    {
        var p = WsTheme.P;
        var set = summary.Set;
        var title = Ui.Text(set.Title, 16, FontWeight.Bold, wrap: TextWrapping.Wrap);
        title.MaxLines = 2;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        title.MinHeight = 42;
        title.VerticalAlignment = VerticalAlignment.Top;
        var left = Ui.V(6, Ui.Chip(Labels.LangPair(set.TermLang, set.DefLang)), title, Ui.Text(StudyCopy.Terms(summary.Stats.Total), 13.5, color: p.TextSecondary));
        var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10 };
        top.Children.Add(left);
        var gauge = new MasteryGauge(summary.Stats, MasteryGauge.Size.Medium) { VerticalAlignment = VerticalAlignment.Top };
        Grid.SetColumn(gauge, 1);
        top.Children.Add(gauge);
        var upper = Ui.V(10, top, Ui.StatusBar(summary.Stats.Mastered, summary.Stats.Learning, summary.Stats.Total, 6, null, p.Dark ? p.Track : Palette.Hex(0xDDE0E8)));
        var open = Ui.Clickable(upper, () => Model.OpenSet(set.Id), set.Title, 12, Colors.Transparent, Colors.Transparent);
        ToolTip.SetTip(open, L("Öffnet das Lernset"));
        var counts = summary.Stats;
        // Mac: the value "52 Begriffe, 3 gemeistert, 2 am Lernen, 47 neu" and the hint "Öffnet das Lernset".
        AutomationProperties.SetHelpText(open, $"{StudyCopy.Terms(counts.Total)}, {L($"{counts.Mastered} gemeistert, {counts.Learning} am Lernen, {counts.Fresh} neu")}. {L("Öffnet das Lernset")}");

        WsButton quick = summary.Learn is not null
            ? Ui.Primary(L("Weiterlernen"), () => Model.Study(set.Id, StudyMode.Learn), null, IconName.Play, 34)
            : Ui.Secondary(L("Lernen"), () => Model.Study(set.Id, StudyMode.Learn), IconName.Sparkles, height: 34);
        quick.Chrome.Padding = new Thickness(14, 0);
        quick.IsEnabled = !summary.IsEmpty;
        AutomationProperties.SetHelpText(quick, summary.Learn is not null ? L($"{set.Title} weiterlernen") : L($"{set.Title} lernen"));
        var bottom = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 8 };
        var status = StatusLabel(summary, now);
        status.VerticalAlignment = VerticalAlignment.Center;
        bottom.Children.Add(status);
        Grid.SetColumn(quick, 1);
        bottom.Children.Add(quick);

        var card = new Border
        {
            Child = Ui.V(10, open, bottom),
            CornerRadius = new CornerRadius(20),
            Padding = new Thickness(16),
            Background = WsTheme.B(p.Card),
            BorderBrush = WsTheme.B(p.Hairline),
            BorderThickness = new Thickness(1),
        };
        card.PointerEntered += (_, _) => card.BorderBrush = WsTheme.B(Palette.Hex(Ui.Rgb(p.Accent), 0.45));
        card.PointerExited += (_, _) => card.BorderBrush = WsTheme.B(p.Hairline);
        SetActions.AttachMenu(card, Model, Window, summary, includesStudy: true);
        return card;
    }

    /// <summary>The status line of a set card (Mac: CardStatusLabel, <c>cardStatus</c> in dashboard.js).</summary>
    Control StatusLabel(SetSummary summary, double now)
    {
        var p = WsTheme.P;
        // One line that shortens with "…" next to the quick action (Mac: lineLimit(1)).
        static Control Line(Control icon, string text, Color color, FontWeight weight, string? tip = null)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 6 };
            icon.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(icon);
            var t = Ui.Text(text, 13.5, weight, color);
            Grid.SetColumn(t, 1);
            row.Children.Add(t);
            if (tip is not null) ToolTip.SetTip(row, tip);
            return row;
        }
        Control Dot() => new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = WsTheme.B(p.Accent) };
        if (summary.Learn is { } learn) return Line(Dot(), learn.ShortDetail, p.AccentText, FontWeight.Medium, L($"Lernen: {learn.Detail}"));
        if (summary.Write is { } write) return Line(Dot(), L($"Schreiben · {write.ShortDetail}"), p.AccentText, FontWeight.Medium, L($"Schreiben: {write.RoundText}"));
        if (summary.IsAllMastered) return Line(Icons.Icon(IconName.CheckCircle, 15, p.Mastered.Text, 2), L("Alles gemeistert"), p.Mastered.Text, FontWeight.Normal);
        if (summary.Set.LastStudiedAt is { } last)
        {
            var when = TimeUtil.RelativeTime(last, now, Model.Store.TimeZone);
            return Line(Icons.Icon(IconName.Clock, 15, p.TextSecondary, 2), StudyCopy.Capitalized(when), p.TextSecondary, FontWeight.Normal, L($"Zuletzt gelernt {when}"));
        }
        return Line(Icons.Icon(IconName.Sparkles, 15, p.TextSecondary, 2), L("Noch nicht gelernt"), p.TextSecondary, FontWeight.Normal);
    }

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        if (isRepeat || Window.TextFieldFocused || e.Key is not (Key.Enter or Key.Return) || e.KeyModifiers != KeyModifiers.None) return false;
        if (Model.Library.IsEmpty)
        {
            Model.OpenEditor();
            return true;
        }
        ResumeOrOpen();
        return true;
    }
}
