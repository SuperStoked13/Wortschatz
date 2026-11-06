using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Editor;

// The card list of the editor (Mac: SetEditorCardList.swift, SetEditorRow.swift and the row logic of
// SetEditorModel.swift): "Karten 52" with the issue chips, the pinned column header, the rows with their notes, and
// "Karte hinzufügen" with the key hints.
public sealed partial class SetEditorScreen
{
    /// <summary>One card row (Mac: SetEditorRow).</summary>
    sealed class Draft
    {
        /// <summary>The values needed to rebuild a row (undo).</summary>
        public sealed record Snapshot(Guid Key, string? Id, string Term, string Definition, bool Starred, IReadOnlyList<ParseFlag> Flags);

        /// <summary>The row's identity in the list (not the card id: new rows have none yet).</summary>
        public Guid Key = Guid.NewGuid();
        /// <summary>The stored card's id; kept on save so the learning progress stays with the card.</summary>
        public string? Id;
        public string Term = "";
        public string Definition = "";
        public bool Starred;
        /// <summary>Parser flags of an imported card ("bitte prüfen"); cleared by the first edit.</summary>
        public IReadOnlyList<ParseFlag> Flags = [];
        /// <summary>Marked by the last save attempt: filled but incomplete, until fixed.</summary>
        public bool IsInvalid;
        /// <summary>Its term appears in another row too.</summary>
        public bool IsDuplicate;
        /// <summary>Probable typos (Mac: termSpelling / definitionSpelling).</summary>
        public IReadOnlyList<SpellingIssue> TermSpelling = [], DefSpelling = [];
        /// <summary>The row's controls while it is on screen.</summary>
        public RowView? View;

        public string TrimmedTerm => JSCompat.Trim(Term);
        public string TrimmedDefinition => JSCompat.Trim(Definition);
        public bool IsFilled => TrimmedTerm.Length > 0 || TrimmedDefinition.Length > 0;
        public bool IsComplete => TrimmedTerm.Length > 0 && TrimmedDefinition.Length > 0;
        public bool IsFlagged => SetEditorCopy.HasMarker(Flags);
        public bool HasSpellingIssues => TermSpelling.Count > 0 || DefSpelling.Count > 0;

        public static Draft FromCard(Card c) => new() { Id = c.Id, Term = c.Term, Definition = c.Definition, Starred = c.Starred };
        public static Draft FromParsed(ParsedCard c) => new() { Term = c.Term, Definition = c.Definition, Flags = c.Flags };
        public static Draft FromSnapshot(Snapshot s) => new() { Key = s.Key, Id = s.Id, Term = s.Term, Definition = s.Definition, Starred = s.Starred, Flags = s.Flags };
        public Snapshot Snap() => new(Key, Id, Term, Definition, Starred, Flags);
    }

    /// <summary>The controls of a row on screen.</summary>
    sealed class RowView(Border card, TextBox term, TextBox definition, StackPanel numberColumn, WrapPanel notes)
    {
        public Border Card { get; } = card;
        public TextBox Term { get; } = term;
        public TextBox Definition { get; } = definition;
        public StackPanel NumberColumn { get; } = numberColumn;
        public WrapPanel Notes { get; } = notes;
    }

    /// <summary>Counts for the header, the issue chips and the save bar (Mac: SetEditorModel.Stats).</summary>
    readonly record struct Stats(int Rows, int Filled, int Complete, int Invalid, int Flagged, int Duplicates, int Typos);

    readonly List<Draft> _drafts = [];
    int _duplicateTerms;
    IDisposable? _duplicateTimer;
    readonly ItemsControl _cardList = new() { ItemsPanel = new FuncTemplate<Panel?>(() => new VirtualizingStackPanel()) };
    readonly TextBlock _countLabel = Ui.Text("", 20, FontWeight.SemiBold);
    readonly WrapPanel _issueChips = new() { ItemSpacing = 6, LineSpacing = 6, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    TextBlock _emptyLead = null!;
    Control _cardsError = null!;
    Grid? _columnHeaderInFlow, _pinnedColumns, _pinnedHeader;
    Control? _cardsHeader;
    /// <summary>The row field that had the keyboard focus last (the trash button keeps the place).</summary>
    (Draft Row, bool IsTerm)? _focusedField;

    Stats ComputeStats()
    {
        int filled = 0, complete = 0, invalid = 0, flagged = 0, typos = 0;
        foreach (var d in _drafts)
        {
            if (d.IsFilled) filled++;
            if (d.IsComplete) complete++;
            if (d.IsInvalid) invalid++;
            if (d.IsFlagged) flagged++;
            typos += d.TermSpelling.Count + d.DefSpelling.Count;
        }
        return new Stats(_drafts.Count, filled, complete, invalid, flagged, _duplicateTerms, typos);
    }

    // MARK: Header and footer

    /// <summary>"Karten 52" with the issue chips, the lead for an empty list and the error after a save attempt (Mac: SetEditorCardsHeader).</summary>
    Control CardsHeader()
    {
        var p = WsTheme.P;
        var title = Ui.Text("Karten", 22, FontWeight.Bold, font: WsTheme.Prompt);
        AutomationProperties.SetHeadingLevel(title, 2);
        Detach(_countLabel);
        Detach(_issueChips);
        _countLabel.Foreground = WsTheme.B(p.TextSecondary);
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 12 };
        row.Children.Add(Ui.H(8, title, _countLabel));
        Grid.SetColumn(_issueChips, 1);
        row.Children.Add(_issueChips);
        _emptyLead = Ui.Text(SetEditorCopy.EmptyLead, 14, color: p.TextSecondary, wrap: TextWrapping.Wrap);
        _cardsError = ErrorLabel("");
        _cardsHeader = Ui.V(8, row, _emptyLead, _cardsError);
        return _cardsHeader;
    }

    /// <summary>Counts, chips, errors and the save bar after any change.</summary>
    void UpdateStats()
    {
        if (_emptyLead is null) return;
        var p = WsTheme.P;
        var stats = ComputeStats();
        _countLabel.Text = $"{stats.Filled}";
        AutomationProperties.SetName(_countLabel, Labels.Plural(stats.Filled, "Karte", "Karten"));
        _issueChips.Children.Clear();
        if (stats.Duplicates > 0) _issueChips.Children.Add(Ui.Chip($"{Labels.Plural(stats.Duplicates, "Begriff", "Begriffe")} doppelt", p.Warning, IconName.Copy));
        if (stats.Flagged > 0) _issueChips.Children.Add(Ui.Chip($"{stats.Flagged} bitte prüfen", p.Warning, IconName.Warning));
        if (stats.Typos > 0)
        {
            var chip = Ui.Chip(SetEditorCopy.TypoCount(stats.Typos), p.Warning, IconName.Pencil);
            ToolTip.SetTip(chip, "Klicke in einer Karte auf den markierten Begriff, um ihn zu korrigieren oder zu ignorieren.");
            _issueChips.Children.Add(chip);
        }
        if (stats.Invalid > 0) _issueChips.Children.Add(Ui.Chip($"{stats.Invalid} unvollständig", p.Failure, IconName.Info));
        _emptyLead.IsVisible = stats.Filled == 0;
        SetErrorText(_cardsError, _attempted ? SetEditorCopy.CardsMessage(stats.Complete, stats.Invalid) : null);
        UpdateActionBar(stats);
    }

    const double NumberWidth = 28, ActionsWidth = 74, ColumnSpacing = 10;

    /// <summary>"# · BEGRIFF · FRANZÖSISCH · DEFINITION · DEUTSCH" (Mac: SetEditorColumnHeader).</summary>
    Grid ColumnHeader(bool pinned)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions($"{NumberWidth},*,*,{ActionsWidth}"),
            ColumnSpacing = ColumnSpacing,
            Margin = new Thickness(11, 0, 11, 0),
        };
        FillColumnHeader(grid);
        AutomationProperties.SetAccessibilityView(grid, AccessibilityView.Raw);
        if (pinned) _pinnedColumns = grid;
        else _columnHeaderInFlow = grid;
        return grid;
    }

    void FillColumnHeader(Grid grid)
    {
        grid.Children.Clear();
        var number = Ui.Eyebrow("#");
        number.TextAlignment = TextAlignment.Right;
        number.HorizontalAlignment = HorizontalAlignment.Right;
        grid.Children.Add(number);
        var term = Ui.Eyebrow($"Begriff · {Labels.LangName(_termLang)}");
        Grid.SetColumn(term, 1);
        grid.Children.Add(term);
        var def = Ui.Eyebrow($"Definition · {Labels.LangName(_defLang)}");
        Grid.SetColumn(def, 2);
        grid.Children.Add(def);
    }

    /// <summary>The column header pinned to the top of the page while the rows scroll under it (Mac: pinnedViews).</summary>
    Grid PinnedHeader()
    {
        var p = WsTheme.P;
        var inner = ColumnHeader(pinned: true);
        inner.Margin = new Thickness(11, 7, 11, 7);
        var holder = new Grid
        {
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(34, 0, 34, 0),
            MaxWidth = ContentWidth,
            IsVisible = false,
            IsHitTestVisible = false,
        };
        holder.Children.Add(new Border
        {
            Background = WsTheme.B(p.Dark ? Palette.Hex(0x20222E, 0.98) : Palette.Hex(0xF6F6FB, 0.98)),
            CornerRadius = new CornerRadius(0, 0, 12, 12),
            BorderBrush = WsTheme.B(p.Hairline),
            BorderThickness = new Thickness(0, 0, 0, 1),
        });
        holder.Children.Add(inner);
        return holder;
    }

    void UpdatePinnedHeader()
    {
        if (_pinnedHeader is null || _columnHeaderInFlow is null || _scroll is null) return;
        if (AppDevice.IsPhone) return;
        var top = _columnHeaderInFlow.TranslatePoint(new Point(0, 0), _scroll);
        var bottom = _cardList.TranslatePoint(new Point(0, _cardList.Bounds.Height), _scroll);
        _pinnedHeader.IsVisible = top is { } t && t.Y < 0 && bottom is { } b && b.Y > 40;
    }

    /// <summary>"Karte hinzufügen" and the key hints below the rows (Mac: SetEditorCardsFooter).</summary>
    Control CardsFooter()
    {
        var p = WsTheme.P;
        var label = Ui.H(8, Icons.Icon(IconName.Plus, 16, p.AccentText, 2.2), Ui.Text("Karte hinzufügen", 14.5, FontWeight.Medium, p.AccentText));
        label.HorizontalAlignment = HorizontalAlignment.Center;
        label.Margin = new Thickness(0, 10);
        var dashed = new Grid();
        dashed.Children.Add(new Avalonia.Controls.Shapes.Rectangle
        {
            RadiusX = 12, RadiusY = 12, StrokeThickness = 1.5,
            Stroke = new SolidColorBrush(p.Accent, 0.4), StrokeDashArray = [4, 3.3],
        });
        dashed.Children.Add(label);
        var add = Ui.Clickable(dashed, () => AddRow(focus: true), "Karte hinzufügen", 12, Colors.Transparent, Palette.Hex(Ui.Rgb(p.Accent), 0.08));

        var hints = new WrapPanel { ItemSpacing = 18, LineSpacing = 6 };
        foreach (var (key, text) in new[] { ("↵", "nächstes Feld"), ("Alt ↵", "Zeilenumbruch"), ("Tab", "in der letzten Karte: neue Karte"), ("Ctrl ↵", SaveLabel) })
            hints.Children.Add(Ui.H(6, Ui.KeyCap(key), Ui.Text(text, 13, color: p.TextSecondary)));
        AutomationProperties.SetAccessibilityView(hints, AccessibilityView.Raw);
        // Phone: keyboard shortcuts mean nothing without a keyboard.
        hints.IsVisible = AppDevice.ShowsKeyHints;
        return Ui.V(14, add, hints);
    }

    // MARK: Rows

    /// <summary>
    /// Shows the rows. The list virtualizes (only the rows on screen exist), so showing it again after a change is cheap
    /// even for 300 cards; the row numbers come from the draft's position when a row is made.
    /// </summary>
    void FillCards()
    {
        foreach (var d in _drafts) d.View = null;
        _cardList.ItemTemplate ??= new FuncDataTemplate<Draft>((d, _) => d is null ? new Border() : CardRow(d), supportsRecycling: false);
        _cardList.ItemsSource = _drafts.ToList();
        UpdateStats();
    }

    /// <summary>Scrolls the row of <paramref name="d"/> into view and focuses its term (or definition) field.</summary>
    void FocusRow(Draft d, bool definition = false)
    {
        Dispatcher.UIThread.Post(() =>
        {
            int index = _drafts.IndexOf(d);
            if (index < 0) return;
            _cardList.ScrollIntoView(index);
            Dispatcher.UIThread.Post(() =>
            {
                if (d.View is not { } view) return;
                var field = definition ? view.Definition : view.Term;
                field.BringIntoView();
                field.Focus();
                field.CaretIndex = field.Text?.Length ?? 0;
            }, DispatcherPriority.Loaded);
        }, DispatcherPriority.Loaded);
    }

    /// <summary>Brings the row of <paramref name="d"/> to the middle of the page (after an import was appended).</summary>
    void ScrollToRow(Draft d)
    {
        Dispatcher.UIThread.Post(() =>
        {
            int index = _drafts.IndexOf(d);
            if (index < 0) return;
            _cardList.ScrollIntoView(index);
            Dispatcher.UIThread.Post(() => ScrollTo(d.View?.Card, center: true), DispatcherPriority.Loaded);
        }, DispatcherPriority.Loaded);
    }

    /// <summary>
    /// One card: number (with the parser's review marker), term and definition fields, ★ and delete, plus the notes
    /// ("Begriff fehlt", "Doppelter Begriff", typos) (Mac: SetEditorRowView). Keys: Enter in the term goes to the
    /// definition, Enter in the definition to the next card's term (a new card after the last filled one); Tab in the
    /// last definition adds a card; Backspace in an empty card's term removes it; Alt+Enter breaks a line.
    /// </summary>
    Control CardRow(Draft d)
    {
        var p = WsTheme.P;
        int number = _drafts.IndexOf(d) + 1;
        var term = RowField(d, isTerm: true, number);
        var def = RowField(d, isTerm: false, number);

        WsButton? star = null;
        star = Ui.IconButton(d.Starred ? IconName.StarFilled : IconName.Star, d.Starred ? "Markierung entfernen" : "Markieren", () =>
        {
            d.Starred = !d.Starred;
            Announcer.Announce(d.Starred ? "Markiert" : "Markierung entfernt");
            if (star?.Chrome.Child is Border holder)
            {
                holder.Child = Icons.Icon(d.Starred ? IconName.StarFilled : IconName.Star, 18, d.Starred ? p.Star : p.TextTertiary);
                ToolTip.SetTip(star, d.Starred ? "Markierung entfernen" : "Markieren");
            }
            AutomationProperties.SetName(star!, d.Starred ? $"Karte {number}: Markierung entfernen" : $"Karte {number} markieren");
        }, 32, ButtonKind.Plain, d.Starred ? p.Star : p.TextTertiary);
        AutomationProperties.SetName(star, d.Starred ? $"Karte {number}: Markierung entfernen" : $"Karte {number} markieren");
        var delete = Ui.IconButton(IconName.Trash, "Karte löschen", () => DeleteRow(d), 32, ButtonKind.Plain, p.TextTertiary);
        AutomationProperties.SetName(delete, $"Karte {number} löschen");

        var numberColumn = new StackPanel { Spacing = 6, Margin = new Thickness(0, 11, 0, 0) };
        numberColumn.Children.Add(Ui.Text($"{number}", 13, FontWeight.SemiBold, p.TextTertiary, align: TextAlignment.Right));
        AutomationProperties.SetAccessibilityView(numberColumn.Children[0], AccessibilityView.Raw);

        if (AppDevice.IsPhone)
        {
            // Phone: term over definition (side by side each field would be a word wide), star and delete beside them.
            var phone = new Grid { ColumnDefinitions = new ColumnDefinitions("22,*,Auto"), RowDefinitions = new RowDefinitions("Auto,Auto"), ColumnSpacing = 8, RowSpacing = 6 };
            phone.Children.Add(numberColumn);
            Grid.SetRowSpan(numberColumn, 2);
            Grid.SetColumn(term, 1);
            phone.Children.Add(term);
            Grid.SetColumn(def, 1);
            Grid.SetRow(def, 1);
            phone.Children.Add(def);
            var actions = Ui.V(2, star, delete);
            actions.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(actions, 2);
            Grid.SetRowSpan(actions, 2);
            phone.Children.Add(actions);
            var phoneNotes = new WrapPanel { ItemSpacing = 6, LineSpacing = 6, Margin = new Thickness(30, 0, 0, 0) };
            var phoneCard = Ui.Glass(Ui.V(6, phone, phoneNotes), 14, new Thickness(8, 8), shadow: false);
            phoneCard.Margin = new Thickness(0, 0, 0, 6);
            d.View = new RowView(phoneCard, term, def, numberColumn, phoneNotes);
            UpdateRow(d);
            return phoneCard;
        }
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions($"{NumberWidth},*,*,Auto,Auto"), ColumnSpacing = ColumnSpacing };
        grid.Children.Add(numberColumn);
        Grid.SetColumn(term, 1);
        grid.Children.Add(term);
        Grid.SetColumn(def, 2);
        grid.Children.Add(def);
        star.VerticalAlignment = delete.VerticalAlignment = VerticalAlignment.Top;
        star.Margin = delete.Margin = new Thickness(0, 5, 0, 0);
        Grid.SetColumn(star, 3);
        grid.Children.Add(star);
        Grid.SetColumn(delete, 4);
        grid.Children.Add(delete);
        var notes = new WrapPanel { ItemSpacing = 6, LineSpacing = 6, Margin = new Thickness(NumberWidth + ColumnSpacing, 0, 0, 0) };
        var card = Ui.Glass(Ui.V(6, grid, notes), 14, new Thickness(10, 7), shadow: false);
        card.Margin = new Thickness(0, 0, 0, 6);
        d.View = new RowView(card, term, def, numberColumn, notes);
        UpdateRow(d);
        return card;
    }

    TextBox RowField(Draft d, bool isTerm, int number)
    {
        var lang = isTerm ? _termLang : _defLang;
        var box = Ui.Field(isTerm ? SetEditorCopy.TermPlaceholder : SetEditorCopy.DefinitionPlaceholder, isTerm ? d.Term : d.Definition, 15, 40);
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.Wrap;
        box.MaxLines = 6;
        box.Padding = new Thickness(12, 8);
        if (lang.IsRTL()) box.FlowDirection = FlowDirection.RightToLeft;
        AutomationProperties.SetName(box, $"Karte {number}: {(isTerm ? "Begriff" : "Definition")} ({Labels.LangName(lang)})");
        box.TextChanged += (_, _) => UpdateField(d, isTerm, box.Text ?? "");
        box.GotFocus += (_, _) => _focusedField = (d, isTerm);
        OnKeys(box, e =>
        {
            if (e.Key is Key.Enter or Key.Return)
            {
                if (e.KeyModifiers == KeyModifiers.Alt) return InsertLineBreak(box);
                if (e.KeyModifiers != KeyModifiers.None) return false;
                SubmitRow(d, isTerm);
                return true;
            }
            if (e.Key == Key.Tab && e.KeyModifiers == KeyModifiers.None && !isTerm) return TabFromDefinition(d);
            if (e.Key == Key.Back && e.KeyModifiers == KeyModifiers.None && isTerm && box.SelectionStart == box.SelectionEnd)
                return DeleteBackwardInEmptyTerm(d);
            return false;
        });
        return box;
    }

    /// <summary>Border, review marker and notes of a row on screen (Mac: SetEditorRowView's notes and borderColor).</summary>
    void UpdateRow(Draft d)
    {
        if (d.View is not { } view) return;
        var p = WsTheme.P;
        view.Card.BorderBrush = WsTheme.B(d.IsInvalid ? Palette.Hex(Ui.Rgb(p.Failure.Fill), 0.55)
            : d.IsDuplicate || d.IsFlagged || d.HasSpellingIssues ? Palette.Hex(Ui.Rgb(p.Warning.Fill), 0.5) : p.GlassBorder);
        bool termMissing = d.IsInvalid && d.TrimmedTerm.Length == 0, defMissing = d.IsInvalid && d.TrimmedDefinition.Length == 0;
        view.Term.BorderBrush = WsTheme.B(termMissing ? p.Failure.Fill : p.Hairline);
        view.Definition.BorderBrush = WsTheme.B(defMissing ? p.Failure.Fill : p.Hairline);
        view.Term.BorderThickness = new Thickness(termMissing ? 2 : 1);
        view.Definition.BorderThickness = new Thickness(defMissing ? 2 : 1);

        int number = _drafts.IndexOf(d) + 1;
        while (view.NumberColumn.Children.Count > 1) view.NumberColumn.Children.RemoveAt(1);
        if (SetEditorCopy.FlagTooltip(d.Flags) is { } tooltip)
        {
            var marker = Icons.Icon(IconName.Warning, 13, p.Warning.Fill, 2.2);
            marker.HorizontalAlignment = HorizontalAlignment.Right;
            marker.IsHitTestVisible = true;
            var holder = new Border { Background = Brushes.Transparent, Child = marker, HorizontalAlignment = HorizontalAlignment.Right };
            ToolTip.SetTip(holder, tooltip);
            AutomationProperties.SetName(holder, $"Karte {number}: {tooltip}");
            view.NumberColumn.Children.Add(holder);
        }

        var notes = view.Notes;
        notes.Children.Clear();
        if (d.IsInvalid) notes.Children.Add(Ui.Chip(d.TrimmedTerm.Length == 0 ? "Begriff fehlt" : "Definition fehlt", p.Failure, IconName.Info));
        if (d.IsDuplicate) notes.Children.Add(Ui.Chip("Doppelter Begriff", p.Warning, IconName.Copy));
        var spelling = d.TermSpelling.Select(i => (Issue: i, IsTerm: true)).Concat(d.DefSpelling.Select(i => (Issue: i, IsTerm: false))).ToList();
        foreach (var (issue, isTerm) in spelling.Take(3)) notes.Children.Add(SpellingChip(d, issue, isTerm));
        if (spelling.Count > 3) notes.Children.Add(Ui.Text($"+{spelling.Count - 3}", 12, FontWeight.Medium, p.Warning.Text));
        notes.IsVisible = notes.Children.Count > 0;
    }

    /// <summary>A change typed or pasted in a row field (Mac: SetEditorModel.update(_:term:to:)).</summary>
    void UpdateField(Draft d, bool isTerm, string value)
    {
        var old = isTerm ? d.Term : d.Definition;
        if (value == old) return;
        if (SetEditorCopy.PasteShapeOf(SetEditorCopy.InsertedText(old, value), rowIsEmpty: !d.IsFilled) is { } shape)
        {
            // The field gets its old text back; a pair fills the row, a list goes to the import box.
            Dispatcher.UIThread.Post(() =>
            {
                if (d.View is { } view) (isTerm ? view.Term : view.Definition).Text = old;
                switch (shape)
                {
                    case SetEditorCopy.PasteShape.Pair pair: Fill(d, pair.Term, pair.Definition); break;
                    case SetEditorCopy.PasteShape.List list: DivertList(list.Text); break;
                }
            });
            return;
        }
        if (isTerm) d.Term = value;
        else d.Definition = value;
        bool changed = false;
        if (d.Flags.Count > 0)
        {
            d.Flags = [];
            changed = true;
        }
        if (d.IsInvalid && (d.IsComplete || !d.IsFilled))
        {
            d.IsInvalid = false;
            changed = true;
        }
        if (changed) UpdateRow(d);
        if (isTerm) ScheduleDuplicates();
        ScheduleSpelling(400);
        UpdateStats();
    }

    /// <summary>"Begriff⇥Definition" pasted into an empty card fills both fields.</summary>
    void Fill(Draft d, string term, string definition)
    {
        d.Term = term;
        d.Definition = definition;
        d.Flags = [];
        d.IsInvalid = false;
        if (d.View is { } view)
        {
            view.Term.Text = term;
            view.Definition.Text = definition;
        }
        UpdateRow(d);
        FocusRow(d, definition: true);
        ScheduleDuplicates();
        ScheduleSpelling(400);
        UpdateStats();
    }

    /// <summary>A whole list pasted into a field goes to the import box (Mac: divertList).</summary>
    void DivertList(string text)
    {
        ImportSetText(text, append: true);
        Model.ShowToast(new ToastMessage(SetEditorCopy.ListDiverted));
        ScrollTo(_importPanel, center: false);
    }

    /// <summary>Enter in a card field: term → definition; definition → next term, or a new card after a filled last one.</summary>
    void SubmitRow(Draft d, bool isTerm)
    {
        if (isTerm)
        {
            FocusRow(d, definition: true);
            return;
        }
        int index = _drafts.IndexOf(d);
        if (index < 0) return;
        if (index < _drafts.Count - 1) FocusRow(_drafts[index + 1]);
        else if (d.IsFilled) AddRow(focus: true);
    }

    /// <summary>Tab in the last card's definition adds a card (only after a filled row).</summary>
    bool TabFromDefinition(Draft d)
    {
        if (_drafts.Count == 0 || _drafts[^1] != d || !d.IsFilled) return false;
        AddRow(focus: true);
        return true;
    }

    /// <summary>Backspace in an empty card's term removes the card and continues in the previous definition.</summary>
    bool DeleteBackwardInEmptyTerm(Draft d)
    {
        int index = _drafts.IndexOf(d);
        if (_drafts.Count <= 1 || d.IsFilled || index < 0) return false;
        var previous = index > 0 ? _drafts[index - 1] : null;
        _drafts.RemoveAt(index);
        FillCards();
        ScheduleDuplicates();
        if (previous is not null) FocusRow(previous, definition: true);
        else if (_drafts.Count > 0) FocusRow(_drafts[0]);
        return true;
    }

    /// <summary>"Karte hinzufügen" (and Enter / Tab at the end of the list).</summary>
    void AddRow(bool focus)
    {
        var d = new Draft();
        _drafts.Add(d);
        FillCards();
        if (focus) FocusRow(d);
    }

    /// <summary>
    /// The row's trash button: filled rows can be brought back (toast, Ctrl+Z). The list never becomes empty: the last row
    /// is replaced by a fresh one, so a new word typed there does not inherit the deleted card's id or its star.
    /// </summary>
    void DeleteRow(Draft d)
    {
        int index = _drafts.IndexOf(d);
        if (index < 0) return;
        // The focus is still in this row (its field, or its trash button after a click).
        bool keyboardInRow = d.View is { } view && Window.FocusManager?.GetFocusedElement() is Visual focusedVisual
            && (view.Card == focusedVisual || view.Card.IsVisualAncestorOf(focusedVisual));
        void Change()
        {
            _drafts.RemoveAt(index);
            if (_drafts.Count == 0) _drafts.Add(new Draft());
        }
        if (d.IsFilled) Undoable("Karte löschen", "Karte gelöscht", ToastTone.Neutral, includesImport: false, Change);
        else
        {
            Change();
            Announcer.Announce("Karte gelöscht");
        }
        FillCards();
        ScheduleDuplicates();
        // Keyboard users keep working at the same position.
        if (_focusedField is { } focused && focused.Row == d && keyboardInRow)
        {
            var neighbour = _drafts[Math.Min(index, _drafts.Count - 1)];
            FocusRow(neighbour, definition: !focused.IsTerm);
        }
    }

    static List<Draft> Padded(IEnumerable<Draft> rows)
    {
        var list = rows.ToList();
        while (list.Count < SetEditorCopy.MinimumRows) list.Add(new Draft());
        return list;
    }

    void SetRows(IEnumerable<Draft> rows)
    {
        var list = Padded(rows);
        _drafts.Clear();
        _drafts.AddRange(list);
    }

    /// <summary>Appends after the last non-empty row (trailing empty rows are reused).</summary>
    void AppendRows(IEnumerable<Draft> rows)
    {
        var kept = _drafts.ToList();
        while (kept.Count > 0 && !kept[^1].IsFilled) kept.RemoveAt(kept.Count - 1);
        SetRows(kept.Concat(rows));
    }

    /// <summary>Imported rows replacing existing ones keep the card id and star of a row with the same term (Mac: withPreservedIDs).</summary>
    static List<Draft> WithPreservedIds(List<Draft> created, IEnumerable<Draft> previous)
    {
        var pool = previous.Where(d => d.Id is not null && SetEditorCopy.TermKey(d.Term).Length > 0).GroupBy(d => SetEditorCopy.TermKey(d.Term))
            .ToDictionary(g => g.Key, g => new Queue<Draft>(g));
        foreach (var row in created)
        {
            if (!pool.TryGetValue(SetEditorCopy.TermKey(row.Term), out var matches) || matches.Count == 0) continue;
            var match = matches.Dequeue();
            row.Id = match.Id;
            row.Starred = match.Starred;
        }
        return created;
    }

    // MARK: Duplicates

    void ScheduleDuplicates()
    {
        _duplicateTimer?.Dispose();
        _duplicateTimer = DispatcherTimer.RunOnce(CheckDuplicates, TimeSpan.FromMilliseconds(180));
    }

    /// <summary>Marks rows whose term appears more than once (Mac: checkDuplicates).</summary>
    void CheckDuplicates()
    {
        _duplicateTimer?.Dispose();
        _duplicateTimer = null;
        var counts = new Dictionary<string, int>();
        var keys = _drafts.Select(d =>
        {
            var key = SetEditorCopy.TermKey(d.Term);
            if (key.Length > 0) counts[key] = counts.GetValueOrDefault(key) + 1;
            return key;
        }).ToList();
        _duplicateTerms = counts.Values.Count(c => c > 1);
        for (int i = 0; i < _drafts.Count; i++)
        {
            bool duplicate = keys[i].Length > 0 && counts[keys[i]] > 1;
            if (_drafts[i].IsDuplicate == duplicate) continue;
            _drafts[i].IsDuplicate = duplicate;
            UpdateRow(_drafts[i]);
        }
        UpdateStats();
    }

    // MARK: Spelling (Mac: SetEditorModel.checkSpelling, SpellingChip)

    IDisposable? _spellTimer;
    int _spellGeneration;

    void CheckSpelling() => ScheduleSpelling(0);

    /// <summary>Checks every card a moment after the last change, 20 rows at a time so a long list never stalls.</summary>
    void ScheduleSpelling(int delayMs)
    {
        if (!Model.Speller.Supports(_termLang) && !Model.Speller.Supports(_defLang))
        {
            _spellGeneration++;
            foreach (var d in _drafts.Where(d => d.HasSpellingIssues))
            {
                d.TermSpelling = d.DefSpelling = [];
                UpdateRow(d);
            }
            UpdateStats();
            return;
        }
        _spellTimer?.Dispose();
        _spellTimer = DispatcherTimer.RunOnce(() => CheckSpelling(++_spellGeneration, 0), TimeSpan.FromMilliseconds(Math.Max(1, delayMs)));
    }

    void CheckSpelling(int generation, int from)
    {
        if (generation != _spellGeneration || _closed) return;
        int end = Math.Min(_drafts.Count, from + 20);
        for (int i = from; i < end; i++)
        {
            var d = _drafts[i];
            var term = Model.Speller.Issues(d.Term, _termLang);
            var def = Model.Speller.Issues(d.Definition, _defLang);
            if (term.SequenceEqual(d.TermSpelling) && def.SequenceEqual(d.DefSpelling)) continue;
            d.TermSpelling = term;
            d.DefSpelling = def;
            UpdateRow(d);
        }
        if (end < _drafts.Count) Dispatcher.UIThread.Post(() => CheckSpelling(generation, end), DispatcherPriority.Background);
        else UpdateStats();
    }

    Control SpellingChip(Draft d, SpellingIssue issue, bool isTerm)
    {
        var p = WsTheme.P;
        var label = issue.Suggestions.Count > 0 ? $"«{issue.Word}» → {issue.Suggestions[0]}?" : $"«{issue.Word}» unbekannt";
        var chip = Ui.Clickable(Ui.Chip(label, p.Warning, IconName.Pencil), () => { }, $"Möglicher Tippfehler «{issue.Word}»", 10, Colors.Transparent, Colors.Transparent, new Thickness(0));
        ToolTip.SetTip(chip, "Möglicher Tippfehler – klicken für Vorschläge");
        AutomationProperties.SetName(chip, $"Karte {_drafts.IndexOf(d) + 1}: möglicher Tippfehler «{issue.Word}»{(issue.Suggestions.Count > 0 ? $", Vorschlag {issue.Suggestions[0]}" : "")}");
        chip.Click += (_, _) =>
        {
            var menu = new ContextMenu();
            if (issue.Suggestions.Count == 0) menu.Items.Add(new MenuItem { Header = "Keine Vorschläge", IsEnabled = false });
            else
            {
                menu.Items.Add(new MenuItem { Header = "Ersetzen durch", IsEnabled = false });
                foreach (var suggestion in issue.Suggestions)
                {
                    var item = new MenuItem { Header = suggestion, FontWeight = FontWeight.SemiBold };
                    item.Click += (_, _) => ReplaceSpelling(d, issue, isTerm, suggestion);
                    menu.Items.Add(item);
                }
            }
            menu.Items.Add(new Separator());
            var ignore = new MenuItem { Header = $"«{issue.Word}» ignorieren", Icon = Icons.Icon(IconName.X, 15, p.TextSecondary, 1.9) };
            ignore.Click += (_, _) =>
            {
                Model.Speller.Ignore(issue.Word, isTerm ? _termLang : _defLang);
                Announcer.Announce($"«{issue.Word}» wird nicht mehr als Tippfehler markiert");
                CheckSpelling();
                CheckImportTypos();
            };
            menu.Items.Add(ignore);
            menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
            menu.Open(chip);
        };
        return chip;
    }

    /// <summary>A suggestion replaces the word, undoable like other list changes (Mac: SetEditorModel.replaceSpelling).</summary>
    void ReplaceSpelling(Draft d, SpellingIssue issue, bool isTerm, string replacement)
    {
        var text = isTerm ? d.Term : d.Definition;
        int start = issue.Start;
        if (start + issue.Length > text.Length || text.Substring(start, issue.Length) != issue.Word)
            start = text.IndexOf(issue.Word, StringComparison.Ordinal);
        if (start < 0) return;
        var corrected = text[..start] + replacement + text[(start + issue.Length)..];
        Undoable("Tippfehler korrigieren", $"«{issue.Word}» durch «{replacement}» ersetzt", ToastTone.Success, includesImport: false, () =>
        {
            if (isTerm) d.Term = corrected;
            else d.Definition = corrected;
            d.Flags = [];
        });
        if (d.View is { } view) (isTerm ? view.Term : view.Definition).Text = corrected;
        UpdateRow(d);
        if (isTerm) CheckDuplicates();
        CheckSpelling();
    }
}
