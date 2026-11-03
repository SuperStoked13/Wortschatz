using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Overview;

/// <summary>
/// The overview (Mac: OverviewScreen.swift, OverviewHero.swift, OverviewSetGrid.swift): date, greeting and a line
/// about today, the three statistics tiles, the "Weiterlernen" hero (Enter), then "Deine Lernsets" with a sort control
/// and the grid of set cards behind the dashed "Neues Lernset" card. Without sets: the empty state.
/// </summary>
public sealed class OverviewScreen(AppModel model, MainWindow window) : Screen(model, window)
{
    static readonly CultureInfo DeCh = CultureInfo.GetCultureInfo("de-CH");

    protected override Control Build()
    {
        var library = Model.Library;
        var now = DateTime.Now;
        var content = new StackPanel { Spacing = 26, Margin = new Thickness(34, 14, 34, 34), MaxWidth = 1180 };
        if (library.IsEmpty)
        {
            content.Children.Add(Header(now, "Bereit für ein paar Wörter? Lege dein erstes Lernset an."));
            content.Children.Add(EmptyLibrary());
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
        var greeting = now.Hour switch { >= 5 and < 11 => "Guten Morgen", >= 11 and < 18 => "Guten Tag", _ => "Guten Abend" };
        return Ui.V(4, Ui.Eyebrow(now.ToString("dddd, d. MMMM", DeCh)), Ui.Title(greeting, 34), Ui.Text(lead, 17, color: p.TextSecondary, wrap: TextWrapping.Wrap));
    }

    /// <summary><c>leadText</c> of dashboard.js.</summary>
    static string LeadText(LibrarySnapshot library)
    {
        var streak = library.Stats.Streak;
        if (streak.Today > 0) return $"Heute schon {Labels.Plural(streak.Today, "Antwort", "Antworten")} – weiter so!";
        if (streak.Current > 0) return $"Lerne heute, damit deine Serie von {Labels.Plural(streak.Current, "Tag", "Tagen")} weiterläuft.";
        if (library.Resume is not null) return "Mach dort weiter, wo du aufgehört hast.";
        return "Bereit für ein paar Wörter? Wähle ein Lernset und leg los.";
    }

    Control EmptyLibrary()
    {
        var p = WsTheme.P;
        var body = Ui.V(14,
            Icons.Icon(IconName.Stack, 40, p.Accent),
            Ui.Text("Noch keine Lernsets", 24, FontWeight.Bold),
            Ui.Text("Lege dein erstes Lernset an: tippe die Begriffe ein oder füge eine Wörterliste ein – Wortschatz erkennt Begriff und Übersetzung selbst.", 15, color: p.TextSecondary, wrap: TextWrapping.Wrap),
            Ui.H(10,
                Ui.Primary("Erstes Lernset erstellen", () => Model.OpenEditor(), icon: IconName.Plus),
                Ui.Secondary("Liste einfügen", () => Model.OpenEditor(startWithImport: true), IconName.Copy),
                Ui.Secondary("Backup laden", () => _ = Settings.SettingsScreen.ImportBackup(Model, Window), IconName.Upload)));
        body.MaxWidth = 620;
        body.HorizontalAlignment = HorizontalAlignment.Left;
        return Ui.Hero(body, new Thickness(34, 30));
    }

    // MARK: Statistics

    static Control Stats(OverviewStats stats)
    {
        var p = WsTheme.P;
        var streak = stats.Streak;
        var tiles = StatTile.Row(12,
            StatTile.Create("Lernserie", $"{streak.Current}", IconName.Flame, streak.Current > 0 ? p.Flame : p.New.Fill, streak.Current == 1 ? "Tag" : "Tage",
                LibrarySidebar.StreakCaption(streak)),
            StatTile.Create("Heute beantwortet", $"{streak.Today}", IconName.CheckCircle, streak.Today > 0 ? p.Accent : p.New.Fill, caption: $"Letzte 7 Tage: {stats.Week}"),
            StatTile.Create("Begriffe gemeistert", $"{stats.Mastered}", IconName.Trophy, stats.Mastered > 0 ? p.Mastered.Fill : p.New.Fill,
                caption: $"von {Labels.Plural(stats.Total, "Begriff", "Begriffen")}"));
        if (streak.Longest > 0) ToolTip.SetTip(tiles.Children[0], $"Längste Serie: {Labels.Plural(streak.Longest, "Tag", "Tage")}");
        ToolTip.SetTip(tiles.Children[2], "Ein Begriff gilt als gemeistert, wenn du ihn zweimal in Folge richtig beantwortest.");
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
        if (library.Resume is { } resume)
        {
            summary = resume.Summary;
            if (resume.Mode == StudyMode.Learn && summary.Learn is { } learn)
            {
                counts = new SetProgress(learn.Counts.Total, learn.Counts.Mastered, learn.Counts.Learning, learn.Counts.Fresh, 0);
                eyebrow = "Weiterlernen · Lernen";
                eyebrowIcon = IconName.Sparkles;
                meta = StudyCopy.Join(StudyCopy.SubsetLabel(learn.Subset, "Ausgewählte Begriffe"), learn.RoundText, learn.MasteredText);
                progress = learn.ProgressValue;
                action = "Weiterlernen";
            }
            else
            {
                var write = summary.Write!;
                counts = summary.Stats;
                eyebrow = "Weiterlernen · Schreiben";
                eyebrowIcon = IconName.Keyboard;
                meta = StudyCopy.Join(write.RoundText, write.Counters.Total > 0 ? $"{write.Counters.Correct} von {write.Counters.Total} richtig" : null);
                progress = write.ProgressValue;
                action = "Fortsetzen";
            }
            actionIcon = IconName.Play;
        }
        else if (library.Sets.Count > 0)
        {
            summary = library.Sets[0];
            counts = summary.Stats;
            eyebrow = summary.Set.LastStudiedAt is not null ? "Zuletzt gelernt" : "Zuletzt bearbeitet";
            eyebrowIcon = IconName.Clock;
            meta = StudyCopy.Terms(summary.Stats.Total) + " · " + (summary.Set.LastStudiedAt is { } last
                ? TimeUtil.RelativeTime(last, library.Now, Model.Store.TimeZone) : "noch nicht gelernt");
            action = "Öffnen";
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
            var bar = new ProgressLine(value, p.Accent, 320) { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 0) };
            text.Children.Add(bar);
        }
        text.VerticalAlignment = VerticalAlignment.Center;
        var button = Ui.Primary(action, ResumeOrOpen, "↵", actionIcon, 48);
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 24 };
        row.Children.Add(gauge);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        Grid.SetColumn(button, 2);
        row.Children.Add(button);
        return Ui.Hero(row, new Thickness(28, 24));
    }

    /// <summary>The hero's action (Enter): resume the running session, else open the most recent set.</summary>
    void ResumeOrOpen()
    {
        var library = Model.Library;
        if (library.Resume is { } resume) Model.Study(resume.Summary.Id, resume.Mode);
        else if (library.Sets.Count > 0) Model.OpenSet(library.Sets[0].Id);
    }

    // MARK: Sets

    static readonly (string Key, string Label)[] Sorts = [("recent", "Zuletzt gelernt"), ("name", "Name"), ("newest", "Neueste")];

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
        ToolTip.SetTip(sort, "Sortieren nach");
        var grid = new AdaptiveGrid { MinItemWidth = 270, MaxItemWidth = 420, Spacing = 12 };
        void Fill()
        {
            grid.Children.Clear();
            grid.Children.Add(NewSetCard());
            foreach (var summary in Sorted(library.Sets, Model.Preferences.OverviewSort)) grid.Children.Add(SetCard(summary, library.Now));
        }
        sort.SelectionChanged += i =>
        {
            Model.Preferences.OverviewSort = Sorts[i].Key;
            Fill();
        };
        Fill();
        var heading = Ui.Row(Ui.H(8, Ui.Text("Deine Lernsets", 20, FontWeight.Bold, font: WsTheme.Prompt), count), sort);
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
    Control NewSetCard()
    {
        var p = WsTheme.P;
        var plus = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(22), Background = WsTheme.B(p.AccentSoft), Child = Icons.Icon(IconName.Plus, 20, p.AccentText, 2.4) };
        plus.Child.HorizontalAlignment = HorizontalAlignment.Center;
        plus.Child.VerticalAlignment = VerticalAlignment.Center;
        plus.HorizontalAlignment = HorizontalAlignment.Center;
        var title = Ui.Text("Neues Lernset", 15.5, FontWeight.Bold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var note = Ui.Text("Liste einfügen oder Text- und CSV-Datei importieren", 13, color: p.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
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
        var button = Ui.Clickable(dashed, () => Model.OpenEditor(), "Neues Lernset", 20, Colors.Transparent, Palette.Hex(Ui.Rgb(p.Accent), 0.08));
        button.VerticalAlignment = VerticalAlignment.Stretch;
        button.VerticalContentAlignment = VerticalAlignment.Stretch;
        dashed.VerticalAlignment = VerticalAlignment.Stretch;
        ToolTip.SetTip(button, "Neues Lernset (Ctrl+N)");
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
        ToolTip.SetTip(open, "Öffnet das Lernset");

        WsButton quick = summary.Learn is not null
            ? Ui.Primary("Weiterlernen", () => Model.Study(set.Id, StudyMode.Learn), null, IconName.Play, 34)
            : Ui.Secondary("Lernen", () => Model.Study(set.Id, StudyMode.Learn), IconName.Sparkles, height: 34);
        quick.Chrome.Padding = new Thickness(14, 0);
        quick.IsEnabled = !summary.IsEmpty;
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
            ContextMenu = SetActions.Menu(Model, Window, summary, includesStudy: true),
        };
        card.PointerEntered += (_, _) => card.BorderBrush = WsTheme.B(Palette.Hex(Ui.Rgb(p.Accent), 0.45));
        card.PointerExited += (_, _) => card.BorderBrush = WsTheme.B(p.Hairline);
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
        if (summary.Learn is { } learn) return Line(Dot(), learn.ShortDetail, p.AccentText, FontWeight.Medium, $"Lernen: {learn.Detail}");
        if (summary.Write is { } write) return Line(Dot(), $"Schreiben · {write.ShortDetail}", p.AccentText, FontWeight.Medium, $"Schreiben: {write.RoundText}");
        if (summary.IsAllMastered) return Line(Icons.Icon(IconName.CheckCircle, 15, p.Mastered.Text, 2), "Alles gemeistert", p.Mastered.Text, FontWeight.Normal);
        if (summary.Set.LastStudiedAt is { } last)
        {
            var when = TimeUtil.RelativeTime(last, now, Model.Store.TimeZone);
            return Line(Icons.Icon(IconName.Clock, 15, p.TextSecondary, 2), StudyCopy.Capitalized(when), p.TextSecondary, FontWeight.Normal, $"Zuletzt gelernt {when}");
        }
        return Line(Icons.Icon(IconName.Sparkles, 15, p.TextSecondary, 2), "Noch nicht gelernt", p.TextSecondary, FontWeight.Normal);
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
