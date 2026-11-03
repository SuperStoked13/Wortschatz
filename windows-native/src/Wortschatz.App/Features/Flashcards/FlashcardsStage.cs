using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.LogicalTree;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using DeckPhase = Wortschatz.Core.FlashcardDeck.DeckPhase;

namespace Wortschatz.App.Features.Flashcards;

/// <summary>
/// The flashcards screen's content (Mac: FlashcardsStage.swift): the card on its stack (or the round summary, with the
/// last card still gliding off over it), and the floating action bar; an empty set gets a message instead. Built once
/// and updated on every change of the controller, so cards keep moving across steps.
/// </summary>
public sealed class FlashcardsStage : Grid
{
    static Palette P => WsTheme.P;

    readonly FlashcardsController _c;
    readonly Action _onEditCard;
    readonly Grid _column = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly Grid _summaryHost = new();
    readonly Grid _deckHost = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly Border _barHost = new();
    readonly ScrollViewer _scroll;
    readonly Border _emptyHost = new();
    FlashcardDeckView? _deck;
    Size _size = new(1000, 748);
    bool _deckShown;
    DeckPhase? _summaryPhase;
    Control? _summary;
    (int Learning, int Known) _counts = (-1, -1);

    public FlashcardsStage(FlashcardsController controller, Action onEditCard)
    {
        _c = controller;
        _onEditCard = onEditCard;
        RowDefinitions = new RowDefinitions("*,Auto");
        _column.Children.Add(_summaryHost);
        _column.Children.Add(_deckHost);
        _column.HorizontalAlignment = HorizontalAlignment.Center;
        _scroll = new ScrollViewer
        {
            Content = _column,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        };
        Children.Add(_scroll);
        Children.Add(_emptyHost);
        Grid.SetRow(_barHost, 1);
        Children.Add(_barHost);
        SizeChanged += (_, e) =>
        {
            // The stage's size in 16-point steps, so a live resize does not rebuild it on every frame.
            var stepped = new Size(Math.Round(e.NewSize.Width / 16) * 16, Math.Round(e.NewSize.Height / 16) * 16);
            if (stepped == _size) return;
            _size = stepped;
            Layout();
        };
        Layout();
    }

    DeckPhase Phase => _c.Phase;

    // MARK: Layout

    double ColumnWidth => Math.Min(760, _size.Width - 2 * 32);

    /// <summary>The card sits a little below the top row in tall windows and close to it in short ones.</summary>
    double TopInset => Math.Max(20, Math.Min(112, (_size.Height - 560) / 2)) * 0.75;

    /// <summary>The card's height: what is left above the action bar, in an index-card shape.</summary>
    double CardHeight
    {
        get
        {
            const double actionBar = 84;
            double available = _size.Height - TopInset - actionBar - FlashcardMetrics.StackDepth - 24;
            return FlashcardMetrics.CardHeight(ColumnWidth, available);
        }
    }

    /// <summary>A new size: the deck is rebuilt for the new card size (no animation).</summary>
    void Layout()
    {
        _column.Width = ColumnWidth;
        _column.Margin = new Thickness(0, TopInset, 0, 24);
        _deck?.Detach();
        _deckHost.Children.Clear();
        _deck = new FlashcardDeckView(_c, ColumnWidth, CardHeight);
        _deck.EditRequested += _onEditCard;
        _deckHost.Children.Add(_deck);
        Update(animated: false);
    }

    // MARK: Updates

    /// <summary>The controller changed: the deck, the summary and the action bar follow.</summary>
    public void Update(bool animated = true)
    {
        bool empty = Phase == DeckPhase.Empty;
        _scroll.IsVisible = !empty;
        _emptyHost.IsVisible = empty;
        if (empty)
        {
            _emptyHost.Child ??= EmptyView();
            _barHost.Child = null;
            return;
        }
        _emptyHost.Child = null;
        UpdateDeck(animated);
        UpdateSummary(animated);
        _barHost.Child = ActionBar();
    }

    /// <summary>The deck, also after the round while its last card is still leaving.</summary>
    void UpdateDeck(bool animated)
    {
        bool show = Phase == DeckPhase.Card || _c.Departures.Count > 0;
        _deck?.Update(animated);
        if (show == _deckShown)
        {
            _deckHost.IsVisible = show;
            return;
        }
        _deckShown = show;
        var motion = Effects.Of(_deckHost);
        if (show)
        {
            _deckHost.IsVisible = true;
            if (animated) motion.Enter(Motion.ReduceMotion ? new Placement(Opacity: 0) : new Placement(Y: FlashcardMotion.RiseDistance, Opacity: 0),
                Motion.ReduceMotion ? Curve.EaseOut(0.2) : FlashcardMotion.Arrive);
            else motion.Place(Placement.Identity);
        }
        else if (animated) motion.Place(new Placement(Opacity: 0), Curve.EaseOut(0.12), () =>
        {
            if (!_deckShown) _deckHost.IsVisible = false;
        });
        else _deckHost.IsVisible = false;
    }

    void UpdateSummary(bool animated)
    {
        DeckPhase? phase = Phase is DeckPhase.RoundDone or DeckPhase.Finished ? Phase : null;
        if (phase == _summaryPhase) return;
        _summaryPhase = phase;
        if (_summary is { } old)
        {
            _summary = null;
            if (animated) Effects.Of(old).Place(new Placement(Opacity: 0), Curve.EaseOut(0.12), () => _summaryHost.Children.Remove(old));
            else _summaryHost.Children.Remove(old);
        }
        if (phase is null) return;
        var summary = SummaryView(phase == DeckPhase.Finished);
        _summary = summary;
        _summaryHost.Children.Add(summary);
        // After the last card has started to glide off.
        if (animated) Effects.Of(summary).Enter(new Placement(Opacity: 0), Motion.Soft(0.42).Delayed(0.22));
    }

    /// <summary>The first card rises like every later one (the screen's entrance).</summary>
    public void Entrance() => Effects.EntranceShift(_deckHost, y: StudyEntrance.TileShift);

    // MARK: Action bar

    /// <summary>
    /// The floating bar (Mac: FlashcardsActionBar): ↶ Zurück on the left; on a card ← "Lerne ich noch", → "Weiss ich"
    /// (with this round's counts) and "Umdrehen ↵"; after a round "Weiter mit N Karten ↵"; at the end "Lernen" and
    /// "Nochmal von vorne ↵". It always ends with the Enter action.
    /// </summary>
    Control ActionBar()
    {
        var deck = _c.Deck;
        var undo = StudyChrome.FloatingIconButton(IconName.Undo, "Letzte Karte zurückholen (Rücktaste)", _c.Undo);
        undo.IsEnabled = deck.CanUndo;
        var trailing = new List<Control?>();
        switch (Phase)
        {
            case DeckPhase.Card:
                var learning = SortButton(FlashcardVerdict.StillLearning, deck.LearningCount, _counts.Learning);
                var known = SortButton(FlashcardVerdict.Know, deck.KnownInRound, _counts.Known);
                _counts = (deck.LearningCount, deck.KnownInRound);
                trailing.Add(learning);
                trailing.Add(known);
                trailing.Add(StudyChrome.Floating(Ui.Primary("Umdrehen", _c.Flip, "↵", height: 44)));
                break;
            case DeckPhase.RoundDone:
                _counts = (-1, -1);
                trailing.Add(StudyChrome.Floating(Ui.Secondary("Zurück zum Lernset", _c.Exit, keyHint: "Esc", height: 44)));
                trailing.Add(StudyChrome.Floating(Ui.Primary(FlashcardCopy.NextRoundAction(deck), _c.NextRound, "↵", height: 44)));
                break;
            case DeckPhase.Finished:
                _counts = (-1, -1);
                var learn = StudyChrome.Floating(Ui.Secondary("Lernen", _c.OpenLearn, IconName.Sparkles, height: 44));
                ToolTip.SetTip(learn, "Die Begriffe jetzt abfragen, damit sie als gemeistert zählen");
                trailing.Add(learn);
                trailing.Add(StudyChrome.Floating(Ui.Primary("Nochmal von vorne", () => _c.Restart(), "↵", height: 44)));
                break;
        }
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Width = ColumnWidth, Margin = new Thickness(0, 12, 0, 20) };
        bar.HorizontalAlignment = HorizontalAlignment.Center;
        bar.Children.Add(undo);
        var right = Ui.H(12, trailing.ToArray());
        Grid.SetColumn(right, 2);
        bar.Children.Add(right);
        foreach (var b in bar.GetLogicalDescendants().OfType<Button>()) b.Focusable = false;
        return bar;
    }

    /// <summary>
    /// "← ↺ Lerne ich noch 3" and "✓ Weiss ich 5 →": glass buttons with the verdict's colour on the symbol and the count,
    /// the arrow key on the side the card goes to (Mac: FlashcardSortButton). The count pops when it grows.
    /// </summary>
    Control SortButton(FlashcardVerdict verdict, int count, int previous)
    {
        var palette = verdict.Palette();
        var badge = new Border
        {
            Child = Ui.Text($"{count}", 14, FontWeight.Bold, palette.Text),
            Background = WsTheme.B(palette.Soft),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 1),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var row = Ui.H(8,
            verdict == FlashcardVerdict.StillLearning ? Ui.KeyCap("←") : null,
            Icons.Icon(verdict.Icon(), 17, palette.Fill, 2.6),
            Ui.Text(verdict.Title(), 14.5, FontWeight.Medium),
            badge,
            verdict == FlashcardVerdict.Know ? Ui.KeyCap("→") : null);
        row.VerticalAlignment = VerticalAlignment.Center;
        var button = new WsButton(row, ButtonKind.Glass, 44, padding: new Thickness(14, 0));
        button.Click += (_, _) => _c.Sort(verdict);
        ToolTip.SetTip(button, $"{verdict.Title()} ({(verdict == FlashcardVerdict.Know ? "→" : "←")})");
        AutomationProperties.SetName(button, $"{verdict.Title()}: {FlashcardCopy.Cards(count)}");
        if (previous >= 0 && count > previous) Effects.Pop(badge, 1.12);
        return StudyChrome.Floating(button);
    }

    // MARK: Round summary

    /// <summary>
    /// After a round ("Du machst Fortschritte!") and once every card is known ("Super, du kennst alle 12 Karten!", with
    /// confetti): what was sorted, as glass tiles on the backdrop (Mac: FlashcardsSummaryView).
    /// </summary>
    Control SummaryView(bool finished)
    {
        var deck = _c.Deck;
        var accent = finished ? P.Success.Fill : P.Accent;
        var circle = new Border
        {
            Width = 88,
            Height = 88,
            CornerRadius = new CornerRadius(44),
            Background = ProgressLine.Gradient(accent),
            BoxShadow = BoxShadows.Parse($"0 6 32 0 {WsButton.Hex(accent, 0.35)}"),
        };
        var symbol = Icons.Icon(finished ? IconName.PartyPopper : IconName.Cards, 38, Colors.White, 2);
        symbol.HorizontalAlignment = HorizontalAlignment.Center;
        symbol.VerticalAlignment = VerticalAlignment.Center;
        circle.Child = symbol;
        circle.HorizontalAlignment = HorizontalAlignment.Center;
        circle.Margin = new Thickness(0, 0, 0, 8);
        Effects.Pop(symbol, 1.22);

        var eyebrow = Ui.Eyebrow(finished ? "Karteikarten" : $"Runde {deck.Round} geschafft", P.TextSecondary);
        eyebrow.HorizontalAlignment = HorizontalAlignment.Center;
        var title = Ui.Text(finished ? FlashcardCopy.FinishedTitle(deck) : FlashcardCopy.RoundDoneTitle(deck), 34, FontWeight.Bold,
            wrap: TextWrapping.Wrap, font: WsTheme.Prompt, align: TextAlignment.Center);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetHeadingLevel(title, 1);
        var text = Ui.Text(finished ? FlashcardCopy.FinishedText(deck) : FlashcardCopy.RoundDoneText(deck), 19, color: P.TextSecondary,
            wrap: TextWrapping.Wrap, align: TextAlignment.Center);
        text.MaxWidth = 560;
        text.HorizontalAlignment = HorizontalAlignment.Center;
        var head = Ui.V(12, circle, eyebrow, title, text);

        var tiles = new List<Control> { StatTile.Create("Weiss ich", $"{deck.KnownCount}", IconName.Check, P.Success.Fill) };
        if (!finished) tiles.Add(StatTile.Create("Lerne ich noch", $"{deck.LearningCount}", IconName.Repeat, P.Learning.Fill));
        tiles.Add(StatTile.Create(deck.Round == 1 ? "Runde" : "Runden", $"{deck.Round}", IconName.Repeat, P.Info.Fill));
        var row = StatTile.Row(12, tiles.ToArray());
        row.MaxWidth = 620;

        var stack = Ui.V(24, head, row);
        stack.Margin = new Thickness(0, 20, 0, 0);
        if (!finished) return stack;
        var layer = new Grid();
        layer.Children.Add(stack);
        layer.Children.Add(new CelebrationView { Origin = new Point(0.5, 0.1) });
        return layer;
    }

    // MARK: Empty set

    /// <summary>No card with text in the set: back to the set, or add terms (Enter). Mac: FlashcardsEmptyView.</summary>
    Control EmptyView()
    {
        var view = EmptyStateView.Create(IconName.Cards, "Keine Karten zum Umdrehen", "Dieses Lernset hat noch keine Begriffe. Füge welche hinzu, dann geht es los.",
            Ui.Secondary("Zurück zum Lernset", _c.Exit, keyHint: "Esc", height: 44),
            Ui.Primary("Begriffe hinzufügen", _c.AddCards, "↵", IconName.Plus));
        view.MaxWidth = 760;
        return view;
    }
}
