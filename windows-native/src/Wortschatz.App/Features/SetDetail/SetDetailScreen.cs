using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App.Features.SetDetail;

/// <summary>
/// A set (Mac: SetDetailScreen.swift + SetTermsSection.swift + SetDetailCopy.swift): languages, title, description and
/// facts with the mastery panel beside them (ring, legend that filters the terms, caption); the study buttons (Lernen ↵ /
/// Weiterlernen, Schreiben, Karteikarten, Prüfung, Nur markierte, Nur schwierige, Bearbeiten, "…") in one row when they
/// fit; the running sessions and what Lernen asks; then the terms with a filter, a search and a context menu per row.
/// Narrow windows get a compact mastery panel, short ones also drop the explanations.
/// </summary>
public sealed class SetDetailScreen : Screen
{
    /// <summary>The term filter (Mac: TermFilter).</summary>
    enum Filter { All, New, Learning, Mastered, Starred, Difficult }

    static readonly Dictionary<Filter, string> FilterKeys = new()
    {
        [Filter.All] = "all", [Filter.New] = "new", [Filter.Learning] = "learning", [Filter.Mastered] = "mastered",
        [Filter.Starred] = "starred", [Filter.Difficult] = "difficult",
    };

    readonly string _setId;
    Filter _filter;
    string _search = "";
    ItemsControl? _terms;
    (bool Narrow, bool Short) _layout = (false, false);

    public SetDetailScreen(AppModel model, MainWindow window, string setId) : base(model, window)
    {
        _setId = setId;
        var key = model.Preferences.TermFilter(setId);
        _filter = FilterKeys.FirstOrDefault(p => p.Value == key, new(Filter.All, "all")).Key;
        View.SizeChanged += (_, e) =>
        {
            var layout = (e.NewSize.Width < 880, e.NewSize.Height < 700);
            if (layout == _layout) return;
            _layout = layout;
            Refresh();
        };
    }

    Palette P => WsTheme.P;

    protected override Control Build()
    {
        if (Model.Summary(_setId) is not { } summary)
            return EmptyStateView.Create(IconName.Magnifier, "Lernset nicht gefunden", "Dieses Lernset gibt es nicht mehr – vielleicht wurde es gelöscht.",
                Ui.Primary("Zur Übersicht", Model.ShowOverview, null, IconName.ChevronLeft));
        var content = new StackPanel { Spacing = _layout.Short ? 12 : 20, Margin = new Thickness(34, _layout.Short ? 8 : 14, 34, 28) };
        content.Children.Add(Header(summary));
        if (summary.IsEmpty)
        {
            content.Children.Add(Ui.Hero(Ui.V(12,
                Ui.Text("Noch keine Begriffe", 22, FontWeight.Bold),
                Ui.Text("Tippe Begriffe ein oder importiere eine Vokabelliste.", 14, color: P.TextSecondary),
                Ui.H(10, Ui.Primary("Begriffe hinzufügen", () => Model.OpenEditor(_setId), icon: IconName.Plus),
                    Ui.Secondary("Liste einfügen", () => Model.OpenEditor(_setId, startWithImport: true), IconName.Copy)))));
            return Ui.Scroll(content);
        }
        content.Children.Add(StudyActions(summary));
        content.Children.Add(TermsSection(summary));
        return Ui.Scroll(content);
    }

    // MARK: Header

    Control Header(SetSummary summary)
    {
        var set = summary.Set;
        var title = Ui.Title(set.Title, 32);
        title.MaxLines = 2;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        var left = Ui.V(6, LanguageCapsule(set.TermLang, set.DefLang), title);
        if (set.Description.Length > 0)
        {
            var description = Ui.Text(set.Description, 17, color: P.TextSecondary, wrap: TextWrapping.Wrap);
            description.MaxLines = _layout.Short ? 1 : 3;
            description.TextTrimming = TextTrimming.CharacterEllipsis;
            left.Children.Add(description);
        }
        left.Children.Add(Ui.Text(Facts(set), 14, color: P.TextSecondary));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = _layout.Narrow ? 18 : 30 };
        row.Children.Add(left);
        if (!summary.IsEmpty)
        {
            var panel = MasteryPanel(summary);
            Grid.SetColumn(panel, 1);
            row.Children.Add(panel);
        }
        return row;
    }

    /// <summary>"Französisch → Deutsch" on an accent capsule (Mac: LanguageCapsule, style .full).</summary>
    public static Control LanguageCapsule(Lang termLang, Lang defLang)
    {
        var p = WsTheme.P;
        var row = Ui.H(6, Ui.Text(Labels.LangName(termLang), 13.5, FontWeight.Medium, p.AccentText), Ui.Text("→", 13.5, FontWeight.SemiBold, p.AccentText),
            Ui.Text(Labels.LangName(defLang), 13.5, FontWeight.Medium, p.AccentText));
        return new Border
        {
            Child = row,
            Background = WsTheme.B(p.AccentSoft),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(10, 4),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
    }

    /// <summary>"52 Begriffe · Zuletzt gelernt vor 2 Tagen" (Mac: SetDetailCopy.facts).</summary>
    string Facts(VocabSet set)
    {
        var studied = set.LastStudiedAt is { } last ? $"Zuletzt gelernt {TimeUtil.RelativeTime(last, TimeUtil.NowMs(), Model.Store.TimeZone)}" : "Noch nicht gelernt";
        return $"{StudyCopy.Terms(set.Cards.Count)} · {studied}";
    }

    /// <summary>The ring, the clickable legend (shows that status in the table) and the caption (Mac: MasteryPanel).</summary>
    Control MasteryPanel(SetSummary summary)
    {
        bool compact = _layout.Narrow || _layout.Short;
        var gauge = compact ? new MasteryGauge(summary.Stats, MasteryGauge.Size.Medium, 1.3) : new MasteryGauge(summary.Stats, MasteryGauge.Size.Large);
        var legend = Ui.V(compact ? 0 : 2,
            LegendRow(CardStatus.Mastered, summary.Stats.Mastered, Filter.Mastered, compact),
            LegendRow(CardStatus.Learning, summary.Stats.Learning, Filter.Learning, compact),
            LegendRow(CardStatus.New, summary.Stats.Fresh, Filter.New, compact));
        legend.VerticalAlignment = VerticalAlignment.Center;
        var top = Ui.H(compact ? 12 : 18, gauge, legend);
        var body = Ui.V(10, top);
        if (!compact)
        {
            var caption = Ui.Text(ProgressCaption(summary.Stats), 12, color: P.TextSecondary, wrap: TextWrapping.Wrap);
            caption.Width = MasteryGauge.Diameter(MasteryGauge.Size.Large) + 18 + 176;
            body.Children.Add(caption);
        }
        var panel = new Border
        {
            Child = body,
            Padding = new Thickness(compact ? 12 : 18),
            CornerRadius = new CornerRadius(20),
            Background = WsTheme.B(P.Dark ? Palette.Hex(0xFFFFFF, 0.05) : Palette.Hex(0xFFFFFF, 0.6)),
            BorderBrush = WsTheme.B(P.Hairline),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Top,
        };
        ToolTip.SetTip(panel, ProgressCaption(summary.Stats));
        return panel;
    }

    Control LegendRow(CardStatus status, int count, Filter target, bool compact)
    {
        var pal = P.Status(status);
        var dot = new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(5), Background = WsTheme.B(pal.Fill) };
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto"), ColumnSpacing = 8, Margin = new Thickness(8, compact ? 3 : 5) };
        row.Children.Add(dot);
        var label = Ui.Text(Labels.STATUS[status], 14, color: P.TextSecondary);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        var number = Ui.Text($"{count}", 14, FontWeight.SemiBold);
        Grid.SetColumn(number, 2);
        row.Children.Add(number);
        var chevron = Icons.Icon(IconName.ChevronRight, 11, P.TextTertiary, 2.6);
        Grid.SetColumn(chevron, 3);
        row.Children.Add(chevron);
        var b = Ui.Clickable(row, () => SetFilter(target), $"{Labels.STATUS[status]}: {StudyCopy.Terms(count)} anzeigen", 7,
            _filter == target ? pal.Soft : null, pal.Soft);
        b.Width = 176;
        return b;
    }

    /// <summary>The caption under the ring (Mac: SetDetailCopy.progressCaption).</summary>
    static string ProgressCaption(SetProgress stats)
    {
        if (stats.Total == 0) return "Füge Begriffe hinzu, um loszulegen.";
        if (stats.Mastered == stats.Total) return "Alles gemeistert – grossartig! Wiederhole ab und zu, damit es sitzt.";
        if (stats.Mastered == 0 && stats.Learning == 0) return "Ein Begriff gilt als gemeistert, wenn du ihn zweimal hintereinander richtig beantwortest.";
        return $"{stats.Mastered} von {Labels.Plural(stats.Total, "Begriff", "Begriffen")} gemeistert. Zweimal hintereinander richtig zählt als gemeistert.";
    }

    // MARK: Study actions

    Control StudyActions(SetSummary summary)
    {
        var id = summary.Id;
        var buttons = new AdaptiveRow(mode =>
        {
            double h = mode == AdaptiveRow.Mode.Large ? 44 : 36;
            var list = new List<Control>();
            var learn = Ui.Primary(summary.Learn is not null ? "Weiterlernen" : "Lernen", () => Model.Study(id, StudyMode.Learn), "↵",
                summary.Learn is not null ? IconName.Play : IconName.Sparkles, h);
            ToolTip.SetTip(learn, summary.Learn?.Detail ?? LearnTagline(summary.Options) + " (Ctrl+L)");
            list.Add(learn);
            list.Add(Tip(Ui.Secondary(summary.Write is not null ? "Schreiben fortsetzen" : "Schreiben", () => Model.Study(id, StudyMode.Write), IconName.Keyboard, height: h),
                summary.Write?.Detail ?? $"Jede Karte schriftlich · {WriteAnswerLabel(summary.Set, summary.Options)} (Ctrl+Shift+L)"));
            list.Add(Tip(Ui.Secondary("Karteikarten", () => Model.Study(id, StudyMode.Flashcards), IconName.Cards, height: h),
                Model.Preferences.Deck(id) is { IsResumable: true } deck ? FlashcardCopy.RunningDetail(deck) : "Karten umdrehen und sortieren: Weiss ich oder Lerne ich noch (Ctrl+Alt+L)"));
            list.Add(Tip(Ui.Secondary("Prüfung", () => Model.Study(id, StudyMode.Exam), IconName.Exam, height: h),
                "Alle Fragen auf einer Seite, mit Zeitlimit und einer Note wie in der Schule (Ctrl+Alt+Shift+L)"));
            if (summary.Starred > 0)
                list.Add(Tip(Ui.Secondary($"Nur markierte ({summary.Starred})", () => Model.Study(id, StudyMode.Learn, StudySubset.Starred), IconName.StarFilled, height: h),
                    "Nur die markierten Begriffe lernen"));
            if (summary.DifficultCardIds.Count > 0)
                list.Add(Tip(Ui.Secondary($"Nur schwierige ({summary.DifficultCardIds.Count})", () => Model.Study(id, StudyMode.Learn, StudySubset.CardIds(summary.DifficultCardIds)), IconName.Flame, height: h),
                    $"Nur die Begriffe lernen, die du mindestens {SetSummary.DifficultMistakes}× falsch beantwortet hast"));
            list.Add(Tip(Ui.Secondary("Bearbeiten", () => Model.OpenEditor(id), IconName.Pencil, height: h), "Begriffe hinzufügen oder bearbeiten (Ctrl+E)"));
            list.Add(MoreButton(summary, h));
            return list;
        });

        var lines = new StackPanel { Spacing = 6 };
        if (summary.Learn is { } l) lines.Children.Add(Running(IconName.Sparkles, $"Lernen läuft: {l.Detail}", l.ProgressValue));
        if (summary.Write is { } w) lines.Children.Add(Running(IconName.Keyboard, $"Schreiben läuft: {w.Detail}", w.ProgressValue));
        if (Model.Preferences.Deck(id) is { IsResumable: true } d) lines.Children.Add(Running(IconName.Cards, $"Karteikarten: {FlashcardCopy.RunningDetail(d)}", d.KnownShare));
        if (!_layout.Short)
        {
            lines.Children.Add(Note(IconName.Info, StudyNote(summary.Set, summary.Options)));
            if (summary.Starred == 0 && summary.Learn is null)
                lines.Children.Add(Note(IconName.Lightbulb, "Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben."));
        }
        return Ui.V(12, buttons, lines);
    }

    static Control Tip(Control c, string tip)
    {
        ToolTip.SetTip(c, tip);
        return c;
    }

    Control Note(IconName icon, string text)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 8 };
        var i = Icons.Icon(icon, 15, P.TextTertiary);
        i.VerticalAlignment = VerticalAlignment.Top;
        i.Margin = new Thickness(0, 2, 0, 0);
        row.Children.Add(i);
        var t = Ui.Text(text, 13.5, color: P.TextSecondary, wrap: TextWrapping.Wrap);
        Grid.SetColumn(t, 1);
        row.Children.Add(t);
        return row;
    }

    Control MoreButton(SetSummary summary, double size)
    {
        var button = Ui.IconButton(IconName.More, "Weitere Aktionen", () => { }, size);
        // The dots need a heavier stroke to read at this size (Mac: SF Symbol "ellipsis").
        if (button.Chrome.Child is Border { Child: Viewbox { Child: Canvas canvas } }) foreach (var path in canvas.Children.OfType<Avalonia.Controls.Shapes.Path>()) path.StrokeThickness = 3.2;
        button.Click += (_, _) =>
        {
            var menu = SetActions.Menu(Model, Window, summary, includesStudy: false);
            menu.Placement = PlacementMode.BottomEdgeAlignedRight;
            menu.Open(button);
        };
        return button;
    }

    Control Running(IconName icon, string text, double progress)
    {
        var bar = new ProgressLine(progress, P.Accent, 120, 5) { VerticalAlignment = VerticalAlignment.Center };
        return Ui.H(10, Icons.Icon(icon, 15, P.AccentText), Ui.Text(text, 13.5, FontWeight.Medium, P.AccentText), bar);
    }

    // MARK: Copy (Mac: SetDetailCopy)

    static (string Seen, string Answered) SideName(Lang lang, bool term, bool same)
    {
        if (same) return term ? ("den Begriff", "mit dem Begriff") : ("die Definition", "mit der Definition");
        if (lang != Lang.Other) return (Labels.LangName(lang), $"auf {Labels.LangName(lang)}");
        return term ? ("den Begriff in der Lernsprache", "in der Lernsprache") : ("die Übersetzung", "mit der Übersetzung");
    }

    /// <summary>The Learn explanation under the study buttons (<c>studyNote</c>).</summary>
    static string StudyNote(VocabSet set, StudyOptions options)
    {
        string direction;
        if (options.AnswerWith == AnswerWith.Both) direction = "Die Richtung wechselt zufällig von Frage zu Frage.";
        else
        {
            bool same = set.TermLang != Lang.Other && set.TermLang == set.DefLang;
            var termName = SideName(set.TermLang, true, same);
            var defName = SideName(set.DefLang, false, same);
            var (shown, typed) = options.AnswerWith == AnswerWith.Definition ? (termName, defName) : (defName, termName);
            direction = $"Du siehst {shown.Seen} und antwortest {typed.Answered}.";
        }
        bool mc = options.Learn.Mc || !options.Learn.Written, written = options.Learn.Written || !options.Learn.Mc;
        var how = !written ? "Alle Fragen als Multiple Choice." : !mc ? "Alle Fragen schriftlich." : "Neue Begriffe zuerst als Multiple Choice, danach schriftlich.";
        return $"{direction} {how} Zweimal richtig = gemeistert.";
    }

    static string LearnTagline(StudyOptions options)
    {
        bool mc = options.Learn.Mc || !options.Learn.Written, written = options.Learn.Written || !options.Learn.Mc;
        if (mc && written) return "Multiple Choice & schriftlich – bis alles sitzt";
        return mc ? "Multiple Choice – bis alles sitzt" : "Schriftlich – bis alles sitzt";
    }

    static string WriteAnswerLabel(VocabSet set, StudyOptions options)
    {
        if (options.AnswerWith == AnswerWith.Both) return "Antworten in beide Richtungen";
        var lang = options.AnswerWith == AnswerWith.Definition ? set.DefLang : set.TermLang;
        if (lang == Lang.Other || set.TermLang == set.DefLang)
            return options.AnswerWith == AnswerWith.Definition ? "Antworten mit der Definition" : "Antworten mit dem Begriff";
        return $"Antworten auf {Labels.LangName(lang)}";
    }

    // MARK: Terms

    static string FilterLabel(Filter f) => f switch
    {
        Filter.All => "Alle",
        Filter.New => Labels.STATUS[CardStatus.New],
        Filter.Learning => Labels.STATUS[CardStatus.Learning],
        Filter.Mastered => Labels.STATUS[CardStatus.Mastered],
        Filter.Starred => "Markiert",
        _ => "Schwierig",
    };

    static int FilterCount(Filter f, SetSummary s) => f switch
    {
        Filter.All => s.Stats.Total,
        Filter.New => s.Stats.Fresh,
        Filter.Learning => s.Stats.Learning,
        Filter.Mastered => s.Stats.Mastered,
        Filter.Starred => s.Starred,
        _ => s.DifficultCardIds.Count,
    };

    void SetFilter(Filter filter)
    {
        _filter = filter;
        Model.Preferences.SaveTermFilter(_setId, FilterKeys[filter]);
        Refresh();
    }

    Control TermsSection(SetSummary summary)
    {
        var count = new Border
        {
            Child = Ui.Text($"{summary.Stats.Total}", 13, FontWeight.SemiBold, P.TextSecondary),
            Background = WsTheme.B(P.KeyCap),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 2),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var filters = Enum.GetValues<Filter>();
        int selected = Array.IndexOf(filters, _filter);
        // The filter gets shorter (then a menu) in narrow windows (Mac: toolbarRow with ViewThatFits).
        var filterRow = new AdaptiveRow(mode =>
        {
            if (mode == AdaptiveRow.Mode.Wrapped)
            {
                var box = new ComboBox { MinWidth = 190 };
                foreach (var f in filters) box.Items.Add(new ComboBoxItem { Content = $"{FilterLabel(f)} ({FilterCount(f, summary)})" });
                box.SelectedIndex = selected;
                box.SelectionChanged += (_, _) =>
                {
                    if (box.SelectedIndex >= 0 && filters[box.SelectedIndex] != _filter) SetFilter(filters[box.SelectedIndex]);
                };
                return [box];
            }
            bool withCounts = mode == AdaptiveRow.Mode.Large;
            var labels = filters.Select(f => withCounts ? $"{FilterLabel(f)} {FilterCount(f, summary)}" : FilterLabel(f)).ToList();
            var seg = new WsSegmented(labels, selected, withCounts ? 112 : 84);
            seg.SelectionChanged += i => SetFilter(filters[i]);
            ToolTip.SetTip(seg, "Begriffe filtern");
            return [seg];
        });

        var search = Ui.Field("Begriffe durchsuchen", _search, 13.5, 36);
        search.Width = 200;
        search.TextChanged += (_, _) =>
        {
            _search = search.Text ?? "";
            FillTerms(summary);
        };
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 14 };
        header.Children.Add(Ui.H(10, Ui.Text("Begriffe", 20, FontWeight.Bold, font: WsTheme.Prompt), count));
        filterRow.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(filterRow, 1);
        header.Children.Add(filterRow);
        Grid.SetColumn(search, 2);
        header.Children.Add(search);
        // Only the rows on screen are built (a virtualizing panel inside the page's scroller): a set of 300 terms opens
        // as fast as one of ten.
        _terms = new ItemsControl
        {
            ItemsPanel = new FuncTemplate<Panel?>(() => new VirtualizingStackPanel()),
            ItemTemplate = new FuncDataTemplate<TermItem>((item, _) => item is null ? new Border() : TermRow(item.Summary, item.Card, item.Status), supportsRecycling: false),
        };
        _emptyTerms = new Border();
        FillTerms(summary);
        return Ui.V(12, header, Ui.Glass(Ui.V(0, _terms, _emptyTerms), 20, new Thickness(8), shadow: false));
    }

    sealed record TermItem(SetSummary Summary, Card Card, CardStatus Status);

    Border? _emptyTerms;

    bool Matches(Card card, CardStatus status, int mistakes) => _filter switch
    {
        Filter.New => status == CardStatus.New,
        Filter.Learning => status == CardStatus.Learning,
        Filter.Mastered => status == CardStatus.Mastered,
        Filter.Starred => card.Starred,
        Filter.Difficult => mistakes >= SetSummary.DifficultMistakes,
        _ => true,
    };

    void FillTerms(SetSummary summary)
    {
        if (_terms is null) return;
        var set = summary.Set;
        var q = JSCompat.Lower(JSCompat.Trim(_search));
        var items = new List<TermItem>();
        IEnumerable<Card> cards = set.Cards;
        // Schwierig: most mistakes first (Mac: rows sorted by difficulty).
        if (_filter == Filter.Difficult)
        {
            var order = summary.DifficultCardIds.Select((id, i) => (id, i)).ToDictionary(x => x.id, x => x.i);
            cards = cards.Where(c => order.ContainsKey(c.Id)).OrderBy(c => order[c.Id]);
        }
        foreach (var card in cards)
        {
            var status = summary.StatusOf(card);
            if (!Matches(card, status, summary.MistakesOf(card))) continue;
            if (q.Length > 0 && !JSCompat.Lower(card.Term).Contains(q) && !JSCompat.Lower(card.Definition).Contains(q)) continue;
            items.Add(new TermItem(summary, card, status));
        }
        _terms.ItemsSource = items;
        if (_emptyTerms is not null) _emptyTerms.Child = items.Count == 0 ? EmptyTerms(q.Length > 0) : null;
    }

    Control EmptyTerms(bool searching)
    {
        Control body;
        if (searching)
            body = Ui.V(8, Ui.H(8, Icons.Icon(IconName.Magnifier, 18, P.TextSecondary), Ui.Text($"Keine Treffer für «{_search}»", 16, FontWeight.SemiBold)),
                Ui.Text(_filter == Filter.All ? "Gesucht wird in Begriffen und Definitionen." : "Gesucht wird in den Begriffen dieses Filters.", 13.5, color: P.TextSecondary),
                Ui.Secondary("Suche zurücksetzen", () =>
                {
                    _search = "";
                    Refresh();
                }));
        else
        {
            var (icon, title, text) = _filter switch
            {
                Filter.Learning => (IconName.Book, "Gerade nichts am Lernen", "Hier erscheinen Begriffe, die du schon geübt, aber noch nicht gemeistert hast."),
                Filter.Mastered => (IconName.Trophy, "Noch nichts gemeistert", "Ein Begriff gilt als gemeistert, wenn du ihn zweimal hintereinander richtig beantwortest."),
                Filter.Starred => (IconName.Star, "Keine markierten Begriffe", "Klicke bei einem Begriff auf den Stern, um ihn später gezielt zu üben."),
                Filter.Difficult => (IconName.Flame, "Keine schwierigen Begriffe", $"Hier erscheinen Begriffe, die du mindestens {SetSummary.DifficultMistakes}× falsch beantwortet hast."),
                _ => (IconName.Sparkles, "Keine neuen Begriffe", "Du hast jeden Begriff schon mindestens einmal geübt."),
            };
            body = Ui.V(8, Ui.H(8, Icons.Icon(icon, 18, P.TextSecondary), Ui.Text(title, 16, FontWeight.SemiBold)),
                Ui.Text(text, 13.5, color: P.TextSecondary, wrap: TextWrapping.Wrap),
                Ui.Secondary("Alle Begriffe anzeigen", () => SetFilter(Filter.All)));
        }
        foreach (var c in ((StackPanel)body).Children) c.HorizontalAlignment = HorizontalAlignment.Center;
        return new Border { Padding = new Thickness(20, 26), Child = body };
    }

    Control TermRow(SetSummary summary, Card card, CardStatus status)
    {
        var set = summary.Set;
        var star = Ui.IconButton(card.Starred ? IconName.StarFilled : IconName.Star, card.Starred ? "Markierung entfernen" : "Markieren",
            () => Model.ToggleStar(set.Id, card.Id), 30, ButtonKind.Plain, card.Starred ? P.Star : P.TextTertiary);
        var term = CellText(card.Term, set.TermLang, FontWeight.SemiBold, P.Text);
        var def = CellText(card.Definition, set.DefLang, FontWeight.Normal, P.TextSecondary);
        var chip = Ui.Chip(Labels.STATUS[status], P.Status(status));
        ToolTip.SetTip(chip, ProgressTitle(summary.Progress.GetValueOrDefault(card.Id)));
        var speak = Ui.IconButton(IconName.Speaker, $"{card.Term} vorlesen", () => Model.Speech.Speak(card.Term, set.TermLang), 30, ButtonKind.Plain);
        speak.IsVisible = set.TermLang != Lang.Other && card.Term.Length > 0;
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,2*,2*,Auto,30"), ColumnSpacing = 14, Margin = new Thickness(6, 7, 10, 7) };
        grid.Children.Add(star);
        Grid.SetColumn(term, 1);
        grid.Children.Add(term);
        Grid.SetColumn(def, 2);
        grid.Children.Add(def);
        Grid.SetColumn(chip, 3);
        grid.Children.Add(chip);
        Grid.SetColumn(speak, 4);
        grid.Children.Add(speak);
        var row = new Border { Child = grid, CornerRadius = new CornerRadius(12), Background = Brushes.Transparent };
        row.PointerEntered += (_, _) => row.Background = WsTheme.B(P.Hairline);
        row.PointerExited += (_, _) => row.Background = Brushes.Transparent;
        // The menu is made when it is asked for (a list of 300 rows does not build 300 menus).
        row.ContextRequested += (_, e) =>
        {
            row.ContextMenu ??= TermMenu(set, card);
            row.ContextMenu.Open(row);
            e.Handled = true;
        };
        return row;
    }

    /// <summary>A cell in its language's direction; an empty side shows "–" (Mac: CellText).</summary>
    static TextBlock CellText(string text, Lang lang, FontWeight weight, Color color)
    {
        var t = Ui.Text(text.Length > 0 ? text : "–", 15, weight, text.Length > 0 ? color : WsTheme.P.TextTertiary, TextWrapping.Wrap);
        if (lang.IsRTL())
        {
            t.FlowDirection = FlowDirection.RightToLeft;
            t.TextAlignment = TextAlignment.Start;
        }
        return t;
    }

    /// <summary>"3× richtig · 1× falsch" (Mac: SetDetailCopy.progressTitle).</summary>
    static string ProgressTitle(CardProgress? p) =>
        p is null || p.Correct + p.Incorrect == 0 ? "Noch nicht geübt" : $"{p.Correct}× richtig · {p.Incorrect}× falsch";

    ContextMenu TermMenu(VocabSet set, Card card)
    {
        var menu = new ContextMenu();
        void Item(string header, IconName icon, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = header, Icon = Icons.Icon(icon, 15, P.TextSecondary, 1.9), IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Item(card.Starred ? "Markierung entfernen" : "Markieren", card.Starred ? IconName.Star : IconName.StarFilled, () => Model.ToggleStar(set.Id, card.Id));
        Item("Begriff vorlesen", IconName.Speaker, () => Model.Speech.Speak(card.Term, set.TermLang), set.TermLang != Lang.Other && card.Term.Length > 0);
        Item("Definition vorlesen", IconName.Speaker, () => Model.Speech.Speak(card.Definition, set.DefLang), set.DefLang != Lang.Other && card.Definition.Length > 0);
        menu.Items.Add(new Separator());
        Item("Bearbeiten", IconName.Pencil, () => Model.OpenEditor(set.Id));
        return menu;
    }

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        if (isRepeat || Window.TextFieldFocused) return false;
        if (e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.None && Model.Summary(_setId) is { IsEmpty: false })
        {
            Model.Study(_setId, StudyMode.Learn);
            return true;
        }
        return false;
    }
}
