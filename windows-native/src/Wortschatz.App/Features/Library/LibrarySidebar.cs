using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features;

/// <summary>
/// The floating glass sidebar (Mac: LibrarySidebar.swift): search, "Übersicht", the sets with a mastery ring (a ▶ for
/// a running session, the matching card under the title while searching, a context menu with the set's actions), and
/// the study streak and "Einstellungen" at the bottom (after an update «Aktualisiert auf …» above them,
/// <see cref="UpdateNoticeCard"/>). Keys: ↑↓ move the selection through "Übersicht" and the
/// sets (the list has the keyboard focus from the start, and keeps it when the selection opens another page); Enter then
/// runs the page's main action (Lernen); Enter in the search field opens the first match.
/// </summary>
public sealed class LibrarySidebar
{
    readonly AppModel _model;
    readonly MainView _window;
    public Control View { get; }

    /// <summary>The sidebar on screen (it is made anew after every change).</summary>
    static LibrarySidebar? s_current;
    /// <summary>The keyboard focus is in the list: the next sidebar puts it on its selected row.</summary>
    static bool s_listFocused;
    /// <summary>
    /// The list got the focus by keyboard (↑↓, Tab): the next sidebar shows the focus ring on its row. After a click it
    /// does not – until 26.11.2026 a clicked row («Übersicht», a set) kept a blue frame, as if it stayed pressed.
    /// </summary>
    static bool s_focusVisible;
    static bool s_startFocusGiven;
    static MainView? s_hookedWindow;
    /// <summary>The streak shown last (the flame bounces when it changes).</summary>
    static int s_lastStreak = -1;

    readonly List<(Control Row, Action Open)> _items = [];
    int _selected = -1;

    public LibrarySidebar(AppModel model, MainView window)
    {
        _model = model;
        _window = window;
        View = Build();
        s_current = this;
        HookFocus(window);
        View.AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(RestoreFocus, DispatcherPriority.Background);
    }

    /// <summary>Follows the keyboard focus: inside the list (not the search field) or elsewhere.</summary>
    static void HookFocus(MainView window)
    {
        if (s_hookedWindow == window) return;
        s_hookedWindow = window;
        window.AddHandler(InputElement.GotFocusEvent, (_, e) =>
        {
            s_listFocused = e.Source is Visual v && v is not TextBox && s_current?.View.IsVisualAncestorOf(v) == true;
            s_focusVisible = e.NavigationMethod is NavigationMethod.Tab or NavigationMethod.Directional;
        }, RoutingStrategies.Bubble, handledEventsToo: true);
    }

    /// <summary>
    /// At the start, and after the selection opened another page, the selected row takes the keyboard focus (Mac: the
    /// List keeps its focus) – unless the new page put the focus somewhere itself (the editor's title).
    /// </summary>
    void RestoreFocus()
    {
        if (s_current != this || TopLevel.GetTopLevel(View) is null) return;
        bool start = !s_startFocusGiven;
        s_startFocusGiven = true;
        if (!start && !s_listFocused) return;
        var focused = _window.FocusManager?.GetFocusedElement() as Visual;
        if (focused is not null && focused is not TopLevel && TopLevel.GetTopLevel(focused) is not null && !View.IsVisualAncestorOf(focused)) return;
        var row = _selected >= 0 && _selected < _items.Count ? _items[_selected].Row : _items.FirstOrDefault().Row;
        row?.Focus(!start && s_focusVisible ? NavigationMethod.Directional : NavigationMethod.Unspecified);
    }

    Control Build()
    {
        var p = WsTheme.P;
        var route = _model.Route;

        var search = Ui.Field(L("Lernsets durchsuchen"), _model.Search, 13, 34);
        search.Padding = new Thickness(30, 6, 10, 6);
        search.CornerRadius = new CornerRadius(10);
        AutomationProperties.SetName(search, L("Lernsets durchsuchen"));
        var searchIcon = Icons.Icon(IconName.Search, 15, p.TextTertiary);
        searchIcon.Margin = new Thickness(10, 0, 0, 0);
        searchIcon.HorizontalAlignment = HorizontalAlignment.Left;
        searchIcon.IsHitTestVisible = false;
        var searchBox = new Grid();
        searchBox.Children.Add(search);
        searchBox.Children.Add(searchIcon);

        var overview = NavRow(IconName.Home, L("Übersicht"), route is Route.Overview, _model.ShowOverview);
        var headerText = Ui.Text(L("Lernsets"), 12, FontWeight.SemiBold, p.TextTertiary);
        AutomationProperties.SetHeadingLevel(headerText, 2);
        var header = Ui.Row(headerText, Ui.IconButton(IconName.Plus, L("Neues Lernset (Ctrl+N)"), () => _model.OpenEditor(), 24, ButtonKind.Glass));
        header.Margin = new Thickness(10, 4, 4, 0);

        var list = new StackPanel { Spacing = 2 };
        void FillList()
        {
            list.Children.Clear();
            _items.Clear();
            _items.Add((overview, _model.ShowOverview));
            _selected = route is Route.Overview ? 0 : -1;
            var query = JSCompat.Trim(_model.Search);
            headerText.Text = query.Length > 0 ? ResultsHeader : L("Lernsets");
            foreach (var summary in _model.FilteredSets)
            {
                var row = SetRow(summary, route.RouteSetId == summary.Id, query);
                list.Children.Add(row);
                var id = summary.Id;
                if (route.RouteSetId == id) _selected = _items.Count;
                _items.Add((row, () => _model.OpenSet(id)));
            }
            if (list.Children.Count == 0) list.Children.Add(query.Length > 0 ? NoResults(query) : Empty());
        }
        FillList();
        search.TextChanged += (_, _) =>
        {
            if ((search.Text ?? "") == _model.Search) return;
            _model.Search = search.Text ?? "";
            FillList();
        };
        // Enter in the search field opens the first match (Mac: onSubmit(of: .search)).
        search.KeyDown += (_, e) =>
        {
            if (e.Key is not (Key.Enter or Key.Return) || e.KeyModifiers != KeyModifiers.None) return;
            e.Handled = true;
            if (_model.FilteredSets.FirstOrDefault() is { } first) _model.OpenSet(first.Id);
        };

        // "Einstellungen" as an entry of its own with text, below the streak (it used to be a small symbol inside the
        // streak box, which made it look like part of the streak).
        var settings = NavRow(IconName.Gear, L("Einstellungen"), route is Route.Settings, () => _model.Navigate(new Route.Settings()));
        ToolTip.SetTip(settings, L("Einstellungen (Ctrl+,)"));

        var grid = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,*,Auto,Auto"), RowSpacing = 12 };
        grid.Children.Add(searchBox);
        Place(grid, overview, 1);
        Place(grid, header, 2);
        Place(grid, Ui.Scroll(list), 3);
        // After an update: «Aktualisiert auf …» above the streak (Mac: UpdateNoticeCard in the sidebar's bottom inset).
        Place(grid, Services.AppUpdater.Shared.Notice is { } notice
            ? Ui.V(8, UpdateNoticeCard.Build(_model, notice, Services.AppUpdater.Shared.DismissNotice), Footer())
            : Footer(), 4);
        settings.Margin = new Thickness(0, -6, 0, 0);
        Place(grid, settings, 5);
        var root = Ui.Glass(grid, 20, new Thickness(12, 14), shadow: true);
        root.AddHandler(InputElement.KeyDownEvent, OnKeyDown, RoutingStrategies.Bubble);
        return root;
    }

    /// <summary>↑↓ move the selection (Mac: the List's selection): the page follows, the focus stays in the list.</summary>
    void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Handled || e.KeyModifiers != KeyModifiers.None || e.Key is not (Key.Up or Key.Down) || e.Source is TextBox || _items.Count == 0) return;
        e.Handled = true;
        int target = _selected < 0 ? (e.Key == Key.Down ? 0 : _items.Count - 1) : Math.Clamp(_selected + (e.Key == Key.Down ? 1 : -1), 0, _items.Count - 1);
        if (target == _selected) return;
        s_listFocused = true;
        _items[target].Row.Focus(NavigationMethod.Directional);
        _items[target].Open();
    }

    /// <summary>
    /// "Treffer" above the search results. The Mac's key is «Treffer (Suche)» with the default «Treffer»: the plain
    /// «Treffer» is the accuracy statistic ("Accuracy"), the search results are "Results".
    /// </summary>
    static string ResultsHeader => CoreText.Table?.Lookup("Treffer (Suche)", null) ?? "Treffer";

    /// <summary>"Keine Ergebnisse für «…»" (Mac: ContentUnavailableView.search).</summary>
    static Control NoResults(string query)
    {
        var p = WsTheme.P;
        var icon = Icons.Icon(IconName.Search, 26, p.TextTertiary, 2);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        var title = Ui.Text(L($"Keine Ergebnisse für «{query}»"), 14, FontWeight.SemiBold, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        var note = Ui.Text(L("Prüfe die Schreibweise oder versuche eine neue Suche."), 12.5, color: p.TextTertiary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        title.HorizontalAlignment = note.HorizontalAlignment = HorizontalAlignment.Center;
        var box = Ui.V(6, icon, title, note);
        box.Margin = new Thickness(10, 40, 10, 0);
        return box;
    }

    static Control Empty()
    {
        var empty = Ui.Text(L("Noch keine Lernsets"), 13, color: WsTheme.P.TextTertiary);
        empty.Margin = new Thickness(10, 4);
        return empty;
    }

    /// <summary>The Lernserie with its caption, tinted while a streak runs (Mac: SidebarStreakFooter).</summary>
    Control Footer()
    {
        var p = WsTheme.P;
        var streak = _model.Streak;
        bool running = streak.Current > 0;
        var title = running ? L($"{Labels.Plural(streak.Current, "Tag", "Tage")} Lernserie") : L("Noch keine Lernserie");
        var text = Ui.V(0, Ui.Text(title, 13, FontWeight.SemiBold), Ui.Text(StreakCaption(streak), 11.5, color: p.TextTertiary));
        var flame = Icons.Icon(IconName.Flame, 16, running ? p.Flame : p.TextTertiary);
        flame.RenderTransformOrigin = RelativePoint.Center;
        var footer = Ui.H(8, flame, text);
        var box = new Border
        {
            Child = footer,
            Padding = new Thickness(10, 7, 10, 7),
            CornerRadius = new CornerRadius(14),
            Background = WsTheme.B(running ? Palette.Hex(Ui.Rgb(p.Flame), streak.Today > 0 ? 0.12 : 0.07) : p.Glass),
        };
        if (AppDevice.IsPhone && running)
        {
            // Phone (drawer on the dark glass): the orange wash looked brown, like a warning (06.11.2026) – glass with an
            // orange edge, the flame keeps its colour.
            box.Background = WsTheme.B(p.Glass);
            box.BorderBrush = WsTheme.B(Palette.Hex(Ui.Rgb(p.Flame), streak.Today > 0 ? 0.55 : 0.3));
            box.BorderThickness = new Thickness(1);
        }
        if (streak.Longest > 0) ToolTip.SetTip(box, L($"Längste Serie: {Labels.Plural(streak.Longest, "Tag", "Tage")}"));
        AutomationProperties.SetName(text, $"{title}, {StreakCaption(streak)}");
        // The flame bounces when the streak changes (Mac: symbolEffect(.bounce, value: streak.current)).
        if (s_lastStreak >= 0 && s_lastStreak != streak.Current)
            flame.AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(() => Effects.Pop(flame, 1.3), DispatcherPriority.Background);
        s_lastStreak = streak.Current;
        return box;
    }

    /// <summary>"Heute geschafft", "Heute noch lernen", "Rekord: 9 Tage", … (Mac: StudyStreak.caption).</summary>
    public static string StreakCaption(StudyStreak streak)
    {
        if (streak.Today > 0) return L("Heute geschafft");
        if (streak.Current > 0) return L("Heute noch lernen");
        if (streak.Longest > 0) return L($"Rekord: {Labels.Plural(streak.Longest, "Tag", "Tage")}");
        return L("Lerne heute, um zu starten");
    }

    static void Place(Grid g, Control c, int row)
    {
        Grid.SetRow(c, row);
        g.Children.Add(c);
    }

    WsButton NavRow(IconName icon, string label, bool selected, Action onClick)
    {
        var p = WsTheme.P;
        var content = Ui.H(10, Icons.Icon(icon, 17, selected ? p.AccentText : p.TextSecondary), Ui.Text(label, 14, FontWeight.SemiBold, selected ? p.AccentText : p.Text));
        content.Margin = new Thickness(10, 0);
        var b = Ui.Clickable(content, onClick, label, 10, selected ? p.AccentSoft : null, selected ? p.AccentSoft : null);
        b.Chrome.Height = 36;
        if (selected) AutomationProperties.SetItemStatus(b, L("Ausgewählt"));
        return b;
    }

    Control SetRow(SetSummary summary, bool selected, string query)
    {
        var p = WsTheme.P;
        var set = summary.Set;
        var gauge = new MasteryGauge(summary.Stats);
        var match = Match(summary, query);
        var titles = Ui.V(0, Ui.Text(set.Title, 13.5, FontWeight.SemiBold), Ui.Text(match ?? StudyCopy.Terms(summary.Stats.Total), 12, color: p.TextTertiary));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 10, Margin = new Thickness(10, 7) };
        row.Children.Add(gauge);
        Grid.SetColumn(titles, 1);
        row.Children.Add(titles);
        string? running = summary.Learn is { } l ? L($"Lernen läuft: {l.Detail}") : summary.Write is { } w ? L($"Schreiben läuft: {w.Detail}") : null;
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
        SetActions.AttachMenu(button, _model, _window, summary, includesStudy: true);
        // The screen reader hears the count, the mastery, a running session and the match (Mac: accessibilityValue).
        var parts = new List<string> { StudyCopy.Terms(summary.Stats.Total), L($"{summary.Stats.Percent} Prozent gemeistert") };
        if (running is not null) parts.Add(running);
        if (match is not null) parts.Add(L($"Treffer: {match}"));
        AutomationProperties.SetHelpText(button, string.Join(", ", parts));
        if (selected) AutomationProperties.SetItemStatus(button, L("Ausgewählt"));
        return button;
    }

    /// <summary>While searching, the first matching card when the title does not match (Mac: subtitle, LibrarySearch.match).</summary>
    static string? Match(SetSummary summary, string query)
    {
        if (query.Length == 0) return null;
        var needle = StudyCopy.Fold(query);
        if (StudyCopy.Fold(summary.Set.Title).Contains(needle, StringComparison.Ordinal)) return null;
        var matches = summary.Set.Cards.Where(c => StudyCopy.Fold(c.Term + "\n" + c.Definition).Contains(needle, StringComparison.Ordinal)).ToList();
        if (matches.Count == 0) return null;
        var text = $"{matches[0].Term} – {matches[0].Definition}";
        return matches.Count > 1 ? $"{text} (+{matches.Count - 1})" : text;
    }
}
