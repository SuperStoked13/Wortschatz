using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features;

/// <summary>
/// The floating glass sidebar (Mac: LibrarySidebar.swift): search, "Übersicht", the sets with a mastery ring (a ▶ for
/// a running session, the matching card under the title while searching, a context menu with the set's actions), and
/// the study streak with the settings button at the bottom.
/// </summary>
public sealed class LibrarySidebar
{
    readonly AppModel _model;
    readonly Window _window;
    public Control View { get; }

    public LibrarySidebar(AppModel model, Window window)
    {
        _model = model;
        _window = window;
        View = Build();
    }

    Control Build()
    {
        var p = WsTheme.P;
        var route = _model.Route;

        var search = Ui.Field("Suchen", _model.Search, 13, 34);
        search.Padding = new Thickness(30, 6, 10, 6);
        search.CornerRadius = new CornerRadius(10);
        var searchIcon = Icons.Icon(IconName.Search, 15, p.TextTertiary);
        searchIcon.Margin = new Thickness(10, 0, 0, 0);
        searchIcon.HorizontalAlignment = HorizontalAlignment.Left;
        searchIcon.IsHitTestVisible = false;
        var searchBox = new Grid();
        searchBox.Children.Add(search);
        searchBox.Children.Add(searchIcon);

        var list = new StackPanel { Spacing = 2 };
        void FillList()
        {
            list.Children.Clear();
            var query = JSCompat.Trim(_model.Search);
            foreach (var summary in _model.FilteredSets) list.Children.Add(SetRow(summary, route.RouteSetId == summary.Id, query));
            if (list.Children.Count == 0)
            {
                var empty = Ui.Text(_model.Search.Length > 0 ? "Keine Treffer" : "Noch keine Lernsets", 13, color: p.TextTertiary);
                empty.Margin = new Thickness(10, 4);
                list.Children.Add(empty);
            }
        }
        FillList();
        search.TextChanged += (_, _) =>
        {
            _model.Search = search.Text ?? "";
            FillList();
        };

        var overview = NavRow(IconName.Home, "Übersicht", route is Route.Overview, _model.ShowOverview);
        var header = Ui.Row(Ui.Text("Lernsets", 12, FontWeight.SemiBold, p.TextTertiary),
            Ui.IconButton(IconName.Plus, "Neues Lernset (Ctrl+N)", () => _model.OpenEditor(), 24, ButtonKind.Glass));
        header.Margin = new Thickness(10, 4, 4, 0);

        var grid = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,*,Auto"), RowSpacing = 12 };
        grid.Children.Add(searchBox);
        Place(grid, overview, 1);
        Place(grid, header, 2);
        Place(grid, Ui.Scroll(list), 3);
        Place(grid, Footer(), 4);
        return Ui.Glass(grid, 20, new Thickness(12, 14), shadow: true);
    }

    /// <summary>The Lernserie with its caption, tinted while a streak runs, and the settings button (Mac: SidebarStreakFooter).</summary>
    Control Footer()
    {
        var p = WsTheme.P;
        var streak = _model.Streak;
        bool running = streak.Current > 0;
        var title = running ? $"{Labels.Plural(streak.Current, "Tag", "Tage")} Lernserie" : "Noch keine Lernserie";
        var text = Ui.V(0, Ui.Text(title, 13, FontWeight.SemiBold), Ui.Text(StreakCaption(streak), 11.5, color: p.TextTertiary));
        var footer = Ui.Row(
            Ui.H(8, Icons.Icon(IconName.Flame, 16, running ? p.Flame : p.TextTertiary), text),
            Ui.IconButton(IconName.Gear, "Einstellungen (Ctrl+,)", () => _model.Navigate(new Route.Settings()), 30, ButtonKind.Plain,
                _model.Route is Route.Settings ? p.Accent : p.TextSecondary));
        var box = new Border
        {
            Child = footer,
            Padding = new Thickness(10, 6, 6, 6),
            CornerRadius = new CornerRadius(14),
            Background = WsTheme.B(running ? Palette.Hex(Ui.Rgb(p.Flame), streak.Today > 0 ? 0.12 : 0.07) : p.Glass),
        };
        if (streak.Longest > 0) ToolTip.SetTip(box, $"Längste Serie: {Labels.Plural(streak.Longest, "Tag", "Tage")}");
        return box;
    }

    /// <summary>"Heute geschafft", "Heute noch lernen", "Rekord: 9 Tage", … (Mac: StudyStreak.caption).</summary>
    public static string StreakCaption(StudyStreak streak)
    {
        if (streak.Today > 0) return "Heute geschafft";
        if (streak.Current > 0) return "Heute noch lernen";
        if (streak.Longest > 0) return $"Rekord: {Labels.Plural(streak.Longest, "Tag", "Tage")}";
        return "Lerne heute, um zu starten";
    }

    static void Place(Grid g, Control c, int row)
    {
        Grid.SetRow(c, row);
        g.Children.Add(c);
    }

    Control NavRow(IconName icon, string label, bool selected, Action onClick)
    {
        var p = WsTheme.P;
        var content = Ui.H(10, Icons.Icon(icon, 17, selected ? p.AccentText : p.TextSecondary), Ui.Text(label, 14, FontWeight.SemiBold, selected ? p.AccentText : p.Text));
        content.Margin = new Thickness(10, 0);
        var b = Ui.Clickable(content, onClick, label, 10, selected ? p.AccentSoft : null, selected ? p.AccentSoft : null);
        b.Chrome.Height = 36;
        return b;
    }

    Control SetRow(SetSummary summary, bool selected, string query)
    {
        var p = WsTheme.P;
        var set = summary.Set;
        var gauge = new MasteryGauge(summary.Stats);
        var titles = Ui.V(0, Ui.Text(set.Title, 13.5, FontWeight.SemiBold), Ui.Text(Subtitle(summary, query), 12, color: p.TextTertiary));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 10, Margin = new Thickness(10, 7) };
        row.Children.Add(gauge);
        Grid.SetColumn(titles, 1);
        row.Children.Add(titles);
        string? running = summary.Learn is { } l ? $"Lernen läuft: {l.Detail}" : summary.Write is { } w ? $"Schreiben läuft: {w.Detail}" : null;
        if (running is not null)
        {
            var play = new Border
            {
                Width = 16,
                Height = 16,
                CornerRadius = new CornerRadius(8),
                Background = WsTheme.B(p.Accent),
                Child = Icons.Icon(IconName.Play, 8, Colors.White),
                VerticalAlignment = VerticalAlignment.Center,
            };
            play.Child.HorizontalAlignment = HorizontalAlignment.Center;
            play.Child.VerticalAlignment = VerticalAlignment.Center;
            play.Child.Margin = new Thickness(1, 0, 0, 0);
            Grid.SetColumn(play, 2);
            row.Children.Add(play);
            ToolTip.SetTip(play, running);
        }
        var button = Ui.Clickable(row, () => _model.OpenSet(set.Id), set.Title, 10, selected ? p.AccentSoft : null, selected ? p.AccentSoft : null);
        button.ContextMenu = SetActions.Menu(_model, _window, summary, includesStudy: true);
        return button;
    }

    /// <summary>The term count, or while searching the first matching card when the title does not match (Mac: subtitle).</summary>
    static string Subtitle(SetSummary summary, string query)
    {
        if (query.Length == 0) return StudyCopy.Terms(summary.Stats.Total);
        var needle = Fold(query);
        if (Fold(summary.Set.Title).Contains(needle, StringComparison.Ordinal)) return StudyCopy.Terms(summary.Stats.Total);
        var matches = summary.Set.Cards.Where(c => Fold(c.Term + "\n" + c.Definition).Contains(needle, StringComparison.Ordinal)).ToList();
        if (matches.Count == 0) return StudyCopy.Terms(summary.Stats.Total);
        var text = $"{matches[0].Term} – {matches[0].Definition}";
        return matches.Count > 1 ? $"{text} (+{matches.Count - 1})" : text;
    }

    static string Fold(string s) => string.Join(' ', JSCompat.Lower(TextNormalizer.StripDiacritics(s)).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
