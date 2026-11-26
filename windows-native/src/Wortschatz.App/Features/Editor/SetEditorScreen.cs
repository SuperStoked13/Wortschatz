using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Services;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Editor;

/// <summary>
/// "Neues Lernset" / "Lernset bearbeiten" (Mac: EditorSheet.swift, SetEditorModel.swift, SetEditorChrome.swift,
/// SetEditorMetaSection.swift; the card list in SetEditorCardList.cs, the import panel in ImportPanel.cs): title,
/// description and languages with "⇄", the import panel, the card rows with duplicate and completeness checks, undo,
/// the floating save bar, and saving through the store. Ctrl+Enter / Ctrl+S save, Esc cancels (or stops a running
/// import first), Ctrl+Z / Ctrl+Shift+Z undo and redo list changes.
/// </summary>
public sealed partial class SetEditorScreen : Screen
{
    readonly string? _setId;
    readonly bool _openFile;

    string _title = "", _details = "";
    Lang _termLang, _defLang;
    /// <summary>
    /// The learner picked the language (an existing set's languages count as picked). A new set starts with neither:
    /// "Automatisch" until the import recognises the languages, or until saving looks at the cards (ResolvedLanguages).
    /// </summary>
    bool _termTouched, _defTouched;
    /// <summary>The picker was filled from the recognised list ("Automatisch erkannt").</summary>
    bool _termDetected, _defDetected;
    /// <summary>The title came from a file name.</summary>
    bool _titleFromFile;
    /// <summary>A save was attempted: errors show from now on.</summary>
    bool _attempted;
    /// <summary>Saved or discarded: the editor is going away.</summary>
    bool _closed;
    double _loadedAt;
    string _baseline = "";
    bool _activated;

    // Controls (made by Build).
    TextBox _titleBox = null!, _detailsBox = null!;
    ComboBox _termBox = null!, _defBox = null!;
    Control _termDetectedLabel = null!, _defDetectedLabel = null!;
    Control _titleError = null!, _titleNote = null!;
    readonly Border _capsuleHost = new();
    ScrollViewer _scroll = null!;
    Control _dropOverlay = null!;
    readonly StackPanel _status = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    WsButton _saveButton = null!, _cancelButton = null!;

    public SetEditorScreen(AppModel model, MainView window, string? setId, bool startWithImport, bool openFile = false) : base(model, window)
    {
        _setId = setId;
        _openFile = openFile;
        var set = setId is null ? null : model.Set(setId);
        _title = set?.Title ?? "";
        _details = set?.Description ?? "";
        // New sets: "Automatisch" (Mac 1.8, Anthony 25.11.2026); Other until something is recognised.
        _termLang = set?.TermLang ?? Lang.Other;
        _defLang = set?.DefLang ?? Lang.De;
        _termTouched = _defTouched = set is not null;
        _loadedAt = set?.UpdatedAt ?? 0;
        SetRows(set?.Cards.Select(Draft.FromCard) ?? []);
        _importOpen = startWithImport || set is null;
        _baseline = Fingerprint();
        CheckDuplicates();
    }

    /// <summary>The toasts stay above the save bar.</summary>
    public override double ToastClearance => 76;

    bool IsNew => _setId is null;
    bool IsEditing => !IsNew;
    /// <summary>
    /// "Lernset erstellen" / "Sichern". Phone: "Erstellen" – the longer button squeezed the status beside it to «Titel fe…»
    /// (26.11.2026).
    /// </summary>
    string SaveLabel => AppDevice.IsPhone && IsNew ? L("Erstellen") : SetEditorCopy.SaveLabel(IsEditing);
    bool IsTitleEmpty => JSCompat.Trim(_title).Length == 0;
    /// <summary>"Automatisch": the side has no language yet (neither picked nor recognised).</summary>
    bool TermIsAuto => !_termTouched && !_termDetected;
    bool DefIsAuto => !_defTouched && !_defDetected;

    /// <summary>What the editor would save, to tell whether anything changed (Mac: fingerprint/baseline).</summary>
    string Fingerprint() => string.Join("\u0001", new[] { JSCompat.Trim(_title), JSCompat.Trim(_details), $"{_termLang}", $"{_defLang}" }
        .Concat(_drafts.Where(d => d.IsFilled).Select(d => $"{d.Id}\u0002{d.TrimmedTerm}\u0002{d.TrimmedDefinition}\u0002{d.Starred}")));

    /// <summary>Unsaved changes (also: text waiting in the import box).</summary>
    bool IsDirty => !_closed && (Fingerprint() != _baseline || HasImportText);

    // MARK: Layout

    protected override Control Build()
    {
        var p = WsTheme.P;
        var content = new StackPanel { Spacing = 0, Margin = AppDevice.IsPhone ? new Thickness(8, 4, 8, 24) : new Thickness(34, 14, 34, 28), MaxWidth = ContentWidth };
        content.Children.Add(Header());
        content.Children.Add(Spaced(MetaSection(), 22));
        content.Children.Add(Spaced(ImportPanel(), 18));
        content.Children.Add(Spaced(CardsHeader(), 30));
        var columns = Spaced(ColumnHeader(pinned: false), 8);
        // Phone: each card shows its two fields one under the other, with their language as placeholder: no columns.
        columns.IsVisible = !AppDevice.IsPhone;
        content.Children.Add(columns);
        Detach(_cardList);
        content.Children.Add(_cardList);
        content.Children.Add(Spaced(CardsFooter(), 4));
        FillCards();

        _scroll = Ui.Scroll(content);
        _scroll.ScrollChanged += (_, _) => UpdatePinnedHeader();

        var stage = new Grid();
        stage.Children.Add(_scroll);
        _pinnedHeader = PinnedHeader();
        stage.Children.Add(_pinnedHeader);
        _dropOverlay = DropOverlay();
        stage.Children.Add(_dropOverlay);

        var root = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
        root.Children.Add(stage);
        var bar = ActionBar();
        Grid.SetRow(bar, 1);
        root.Children.Add(bar);
        HookDrops(root);
        UpdateStats();
        UpdateMetaErrors();
        UpdateLanguages(rows: false);
        return root;
    }

    const double ContentWidth = 980;

    /// <summary>A new set (not editing an existing one).</summary>
    public bool IsNewSet => IsNew;

    /// <summary>Nothing typed, imported or changed yet.</summary>
    public bool IsUntouched => !IsDirty && _importCts is null;

    /// <summary>Imports what another app shared (Android "Teilen"): text into the import box, files through the import.</summary>
    public void TakePendingImport()
    {
        if (!IsNew || Model.PendingImport is not { } shared) return;
        Model.PendingImport = null;
        if (shared.Text is { Length: > 0 } text) ImportSetText(text, append: true);
        if (shared.Sources.Count > 0) ImportSources(shared.Sources.ToList());
    }

    static Control Spaced(Control c, double top)
    {
        c.Margin = new Thickness(c.Margin.Left, top, c.Margin.Right, c.Margin.Bottom);
        return c;
    }

    /// <summary>"Neues Lernset" / "Lernset bearbeiten" with the language pair (Mac: SetEditorHeader).</summary>
    Control Header()
    {
        var p = WsTheme.P;
        var heading = Ui.Text(IsEditing ? L("Lernset bearbeiten") : L("Neues Lernset"), AppDevice.IsPhone ? 22 : 28, FontWeight.Bold, font: WsTheme.Prompt);
        heading.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetHeadingLevel(heading, 1);
        var lead = Ui.Text(IsEditing ? L("Ändere Begriffe, ergänze neue oder importiere eine weitere Liste.")
            : AppDevice.ReadsPhotos ? L("Tippe deine Vokabeln ein oder importiere eine ganze Liste – aus Text, Datei oder Foto.")
            : L("Tippe deine Vokabeln ein oder importiere eine ganze Liste – aus Text oder Datei."), 15, color: p.TextSecondary, wrap: TextWrapping.Wrap);
        Detach(_capsuleHost);
        _capsuleHost.VerticalAlignment = VerticalAlignment.Top;
        _capsuleHost.Margin = new Thickness(0, 10, 0, 0);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16 };
        // Phone: the heading is already in the bar on top; the lead and the language pair stay.
        if (AppDevice.IsPhone) _capsuleHost.Margin = new Thickness(0, 1, 0, 0);
        grid.Children.Add(AppDevice.IsPhone ? lead : Ui.V(4, heading, lead));
        Grid.SetColumn(_capsuleHost, 1);
        grid.Children.Add(_capsuleHost);
        return grid;
    }

    /// <summary>Titel, Beschreibung and the language pickers "Ich lerne" ⇄ "Übersetzung" (Mac: SetEditorMetaSection).</summary>
    Control MetaSection()
    {
        var p = WsTheme.P;
        _titleBox = Field(SetEditorCopy.TitlePlaceholder, _title, 20, maxLines: 2);
        _titleBox.FontWeight = FontWeight.SemiBold;
        AutomationProperties.SetName(_titleBox, L("Titel"));
        _titleBox.TextChanged += (_, _) => SetTitle(_titleBox.Text ?? "");
        OnKeys(_titleBox, e =>
        {
            if (e.Key is Key.Enter or Key.Return && e.KeyModifiers is KeyModifiers.None or KeyModifiers.Alt)
            {
                if (e.KeyModifiers == KeyModifiers.None) Submit(Field_.Title);
                return true;
            }
            return false;
        });
        _titleError = ErrorLabel(SetEditorCopy.TitleMissing);
        var note = Ui.H(6, Icons.Icon(IconName.Sparkles, 14, p.AccentText, 2), Ui.Text(SetEditorCopy.TitleFromFile, 13, color: p.AccentText, wrap: TextWrapping.Wrap));
        _titleNote = note;

        _detailsBox = Field(SetEditorCopy.DescriptionPlaceholder, _details, 14, maxLines: 4);
        AutomationProperties.SetName(_detailsBox, L("Beschreibung"));
        _detailsBox.TextChanged += (_, _) => SetDetails(_detailsBox.Text ?? "");
        OnKeys(_detailsBox, e =>
        {
            if (e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.None)
            {
                Submit(Field_.Description);
                return true;
            }
            return e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.Alt && InsertLineBreak(_detailsBox);
        });

        _termBox = LangBox(SetEditorCopy.TermLanguages, L("Ich lerne"));
        _defBox = LangBox(SetEditorCopy.DefinitionLanguages, L("Übersetzung"));
        _termBox.SelectionChanged += (_, _) => { if (!_settingLangs) PickLanguage(isTerm: true, _termBox.SelectedIndex); };
        _defBox.SelectionChanged += (_, _) => { if (!_settingLangs) PickLanguage(isTerm: false, _defBox.SelectedIndex); };
        _termDetectedLabel = DetectedLabel();
        _defDetectedLabel = DetectedLabel();
        var flip = Ui.IconButton(IconName.Repeat, L("Begriffe und Definitionen tauschen"), FlipSides, 38);
        if (flip.Chrome.Child is Border holder) holder.Child = EditorGlyphs.Swap(16, p.TextSecondary);
        flip.Margin = new Thickness(0, 22, 0, 0);
        flip.VerticalAlignment = VerticalAlignment.Top;
        Control langs;
        if (AppDevice.IsPhone)
        {
            // Phone: the two languages side by side as on the PC (reads like «FR → DE»), sharing the width, the swap
            // button between them (one under the other they left a gap and the button floated beside the first).
            _termBox.MinWidth = _defBox.MinWidth = 0;
            _termBox.HorizontalAlignment = _defBox.HorizontalAlignment = HorizontalAlignment.Stretch;
            flip.Width = flip.Height = 34;
            flip.Margin = new Thickness(0, 24, 0, 0);
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,*"), ColumnSpacing = 6 };
            row.Children.Add(Ui.V(6, Label(L("Ich lerne")), _termBox, _termDetectedLabel));
            Grid.SetColumn(flip, 1);
            row.Children.Add(flip);
            var second = Ui.V(6, Label(L("Übersetzung")), _defBox, _defDetectedLabel);
            Grid.SetColumn(second, 2);
            row.Children.Add(second);
            langs = row;
        }
        else langs = Ui.H(14,
            Ui.V(6, Label(L("Ich lerne")), _termBox, _termDetectedLabel),
            flip,
            Ui.V(6, Label(L("Übersetzung")), _defBox, _defDetectedLabel));

        var body = Ui.V(16,
            Ui.V(6, Label(L("Titel")), _titleBox, _titleError, _titleNote),
            Ui.V(6, Label(L("Beschreibung")), _detailsBox),
            langs);
        return Ui.Glass(body, 22, AppDevice.IsPhone ? new Thickness(14, 14) : new Thickness(20, 18), strong: true);

        static TextBlock Label(string text) => Ui.Text(text, 13, FontWeight.Medium, WsTheme.P.TextSecondary);

        static Control DetectedLabel()
        {
            var p = WsTheme.P;
            var label = Ui.H(4, Icons.Icon(IconName.Sparkles, 12, p.AccentText, 2.2), Ui.Text(SetEditorCopy.Detected, 12, FontWeight.Medium, p.AccentText));
            label.Opacity = 0;
            AutomationProperties.SetAccessibilityView(label, AccessibilityView.Raw);
            return label;
        }
    }

    /// <summary>Index of the first language in a picker: "Automatisch" and a line come first.</summary>
    const int FirstLanguageIndex = 2;

    /// <summary>A language picker: "Automatisch" (the recognition decides), a line, then the languages (Mac: SetEditorLanguagePicker).</summary>
    static ComboBox LangBox(IReadOnlyList<Lang> langs, string name)
    {
        var box = new ComboBox { MinWidth = 190 };
        box.Items.Add(new ComboBoxItem { Content = SetEditorCopy.Automatic });
        box.Items.Add(new ComboBoxItem
        {
            Content = new Border { Height = 1, Background = WsTheme.B(WsTheme.P.Hairline), HorizontalAlignment = HorizontalAlignment.Stretch },
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsEnabled = false,
            Focusable = false,
            MinHeight = 0,
            Padding = new Thickness(8, 4),
        });
        foreach (var lang in langs) box.Items.Add(new ComboBoxItem { Content = Labels.LangName(lang) });
        AutomationProperties.SetName(box, name);
        return box;
    }

    /// <summary>A picker's choice: "Automatisch" or a language (the line between them takes nothing).</summary>
    void PickLanguage(bool isTerm, int index)
    {
        var langs = isTerm ? SetEditorCopy.TermLanguages : SetEditorCopy.DefinitionLanguages;
        if (index == 0)
        {
            if (isTerm) SetTermAuto();
            else SetDefAuto();
        }
        else if (index >= FirstLanguageIndex && index - FirstLanguageIndex < langs.Count)
        {
            if (isTerm) SetTermLang(langs[index - FirstLanguageIndex]);
            else SetDefLang(langs[index - FirstLanguageIndex]);
        }
        else UpdateLanguages(rows: false);
    }

    /// <summary>A text field of the editor: wraps, grows up to <paramref name="maxLines"/>, Enter is handled by the editor.</summary>
    static TextBox Field(string placeholder, string text, double fontSize, int maxLines)
    {
        var box = Ui.Field(placeholder, text, fontSize, fontSize >= 18 ? 48 : 42);
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.Wrap;
        box.MaxLines = maxLines;
        box.VerticalContentAlignment = VerticalAlignment.Center;
        return box;
    }

    /// <summary>A red "⚠ message" line (Mac: the field box's error).</summary>
    static Control ErrorLabel(string text)
    {
        var p = WsTheme.P;
        var t = Ui.Text(text, 13, FontWeight.Medium, p.Failure.Text, TextWrapping.Wrap);
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 6 };
        var icon = Icons.Icon(IconName.Warning, 14, p.Failure.Text, 2);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 1, 0, 0);
        row.Children.Add(icon);
        Grid.SetColumn(t, 1);
        row.Children.Add(t);
        row.IsVisible = false;
        return row;
    }

    static void SetErrorText(Control label, string? text)
    {
        label.IsVisible = text is not null;
        if (text is not null && label is Grid g && g.Children.OfType<TextBlock>().FirstOrDefault() is { } t) t.Text = text;
    }

    /// <summary>Handles keys of a field before the field does (tunnel): the handler returns true when it took the key.</summary>
    static void OnKeys(TextBox box, Func<KeyEventArgs, bool> handler) =>
        box.AddHandler(InputElement.KeyDownEvent, (_, e) => { if (!e.Handled && handler(e)) e.Handled = true; }, RoutingStrategies.Tunnel);

    /// <summary>Alt+Enter: a line break at the caret (Mac: ⌥↩ in a vertical text field).</summary>
    static bool InsertLineBreak(TextBox box)
    {
        var text = box.Text ?? "";
        int start = Math.Min(box.SelectionStart, box.SelectionEnd), end = Math.Max(box.SelectionStart, box.SelectionEnd);
        start = Math.Clamp(start, 0, text.Length);
        end = Math.Clamp(end, start, text.Length);
        box.Text = text[..start] + "\n" + text[end..];
        box.CaretIndex = start + 1;
        return true;
    }

    /// <summary>The floating glass bar at the bottom: count and what still blocks saving, "Abbrechen", the save button (Mac: SetEditorActionBar).</summary>
    Control ActionBar()
    {
        var p = WsTheme.P;
        _cancelButton = Ui.Secondary(L("Abbrechen"), Cancel, keyHint: "Esc", height: 40);
        _saveButton = Ui.Primary(SaveLabel, Save, "Ctrl ↵", height: 40);
        Detach(_status);
        var capsule = new Border
        {
            Child = _status,
            MinHeight = 40,
            Padding = new Thickness(16, 0),
            CornerRadius = new CornerRadius(20),
            Background = WsTheme.B(p.GlassStrong),
            BorderBrush = WsTheme.B(p.GlassBorder),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Left,
            ClipToBounds = true,
        };
        AutomationProperties.SetName(capsule, L("Status"));
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), ColumnSpacing = AppDevice.IsPhone ? 6 : 10, Margin = AppDevice.IsPhone ? new Thickness(8, 6, 8, 10) : new Thickness(34, 8, 34, 14), MaxWidth = ContentWidth };
        if (AppDevice.IsPhone) capsule.Padding = new Thickness(12, 0);
        grid.Children.Add(capsule);
        Grid.SetColumn(_cancelButton, 1);
        grid.Children.Add(_cancelButton);
        Grid.SetColumn(_saveButton, 2);
        grid.Children.Add(_saveButton);
        return grid;
    }

    /// <summary>The status line and the buttons' tooltips (Mac: SetEditorActionBar.status, .help).</summary>
    void UpdateActionBar(Stats stats)
    {
        if (_saveButton is null) return;
        var p = WsTheme.P;
        var blocker = SetEditorCopy.Readiness(IsTitleEmpty, stats.Complete);
        var extras = new List<string>();
        if (stats.Duplicates > 0) extras.Add(L($"{stats.Duplicates} doppelt"));
        if (stats.Invalid > 0) extras.Add(L($"{stats.Invalid} unvollständig"));
        if (stats.Typos > 0) extras.Add(L($"{stats.Typos} Tippfehler?"));
        // Both sides in the same language (Deutsch → Deutsch) went through without a word (Joan's test, 06.11.2026):
        // said first, before what still blocks saving.
        bool isAuto = TermIsAuto || DefIsAuto;
        string languages = isAuto ? L("Sprachen automatisch") : Labels.LangPair(_termLang, _defLang);
        string? sameLang = !isAuto && _termLang == _defLang && _termLang != Lang.Other ? L("Zweimal dieselbe Sprache?") : null;
        _status.Children.Clear();
        if (AppDevice.IsPhone)
        {
            // Phone: two short lines – in one line «0 Karten FR → DE · Noch keine vollständige Karte» was cut to «· No…»
            // (06.11.2026). The count and languages on top, what blocks saving (or the warnings) small below.
            _status.Orientation = Orientation.Vertical;
            _status.Spacing = 0;
            var top = Ui.H(6, Ui.Text(Labels.Plural(stats.Filled, "Karte", "Karten"), 13.5, FontWeight.SemiBold),
                // «Sprachen automatisch» did not fit beside the count: the pickers above say it (26.11.2026).
                isAuto ? null : Ui.Text(languages, 13.5, color: p.TextSecondary));
            _status.Children.Add(top);
            // Short words: the bar has room for about 22 letters («Noch keine vollständig…» was cut). Told by the state,
            // not by the blocker's text (which is in the app's language).
            string? shortBlocker = blocker is not null && !IsTitleEmpty && stats.Complete == 0 ? L("Noch keine Karte") : blocker;
            string? note = (sameLang is null ? null : L("Gleiche Sprache?")) ?? shortBlocker ?? (extras.Count > 0 ? string.Join(" · ", extras) : null);
            if (note is not null)
            {
                var line = Ui.Text(note, 11.5, color: blocker is not null && sameLang is null ? p.TextSecondary : p.Warning.Text);
                line.TextTrimming = TextTrimming.CharacterEllipsis;
                _status.Children.Add(line);
            }
            var phoneText = string.Join(" ", new[] { Labels.Plural(stats.Filled, "Karte", "Karten"), languages, note }.Where(s => s is not null));
            if (_status.Parent is Control phoneCapsule) AutomationProperties.SetHelpText(phoneCapsule, phoneText);
            ToolTip.SetTip(_saveButton, blocker is not null ? SaveHelp(blocker) : SaveLabel);
            return;
        }
        _status.Children.Add(Ui.Text(Labels.Plural(stats.Filled, "Karte", "Karten"), 13.5, FontWeight.SemiBold));
        _status.Children.Add(Ui.Text(languages, 13.5, color: p.TextSecondary));
        if (sameLang is not null)
        {
            _status.Children.Add(Ui.Text("·", 13.5, color: p.TextTertiary));
            _status.Children.Add(Ui.Text(sameLang, 13.5, color: p.Warning.Text));
        }
        if (blocker is not null || extras.Count > 0)
        {
            _status.Children.Add(Ui.Text("·", 13.5, color: p.TextTertiary));
            _status.Children.Add(blocker is not null ? Ui.Text(blocker, 13.5, color: p.TextSecondary) : Ui.Text(string.Join(" · ", extras), 13.5, color: p.Warning.Text));
        }
        var statusText = string.Join(" ", _status.Children.OfType<TextBlock>().Select(t => t.Text));
        if (_status.Parent is Control capsule) AutomationProperties.SetHelpText(capsule, statusText);
        ToolTip.SetTip(_saveButton, SaveHelp(blocker));
        ToolTip.SetTip(_cancelButton, _importCts is not null ? L("Import abbrechen (Esc)") : L("Ohne Speichern schliessen (Esc)"));
    }

    /// <summary>The save button's tooltip: what still blocks saving, else its keys (Mac: SetEditorActionBar.saveHelp).</summary>
    string SaveHelp(string? blocker) => (blocker, IsEditing) switch
    {
        ({ } b, true) => L($"{b} – Sichern zeigt, was fehlt"),
        ({ } b, false) => L($"{b} – Erstellen zeigt, was fehlt"),
        (null, true) => L("Sichern (Ctrl+Enter oder Ctrl+S)"),
        (null, false) => L("Lernset erstellen (Ctrl+Enter oder Ctrl+S)"),
    };

    /// <summary>Shown while files are dragged over the editor (Mac: SetEditorDropOverlay).</summary>
    static Control DropOverlay()
    {
        var p = WsTheme.P;
        var grid = new Grid { IsHitTestVisible = false, IsVisible = false };
        grid.Children.Add(new Border { Background = new SolidColorBrush(p.Accent, 0.06) });
        grid.Children.Add(new Avalonia.Controls.Shapes.Rectangle
        {
            RadiusX = 22, RadiusY = 22, StrokeThickness = 2.5, Margin = new Thickness(10),
            Stroke = WsTheme.B(p.Accent), StrokeDashArray = [4, 2.8],
        });
        var icon = Icons.Icon(IconName.Download, 30, p.Accent, 2);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        var title = Ui.Text(L("Datei loslassen zum Importieren"), 20, FontWeight.Bold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var note = Ui.Text(L("Text, CSV, PDF oder Foto – mehrere Dateien gehen auch."), 14, color: p.TextSecondary);
        note.HorizontalAlignment = HorizontalAlignment.Center;
        var card = Ui.Glass(Ui.V(8, icon, title, note), 22, new Thickness(40, 28), strong: true);
        card.HorizontalAlignment = HorizontalAlignment.Center;
        // Opaque, so the page never shows through the text.
        card.Background = WsTheme.B(p.Dark ? Palette.Hex(0x2E3142) : Palette.Hex(0xFBFBFE));
        card.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(card);
        return grid;
    }

    static void Detach(Control c)
    {
        if (c.Parent is Panel panel) panel.Children.Remove(c);
        else if (c.Parent is Decorator d) d.Child = null;
        else if (c.Parent is ContentControl cc) cc.Content = null;
    }

    // MARK: Title, description, languages

    void SetTitle(string value)
    {
        if (value == _title) return;
        if (SetEditorCopy.PasteShapeOf(SetEditorCopy.InsertedText(_title, value), rowIsEmpty: false) is SetEditorCopy.PasteShape.List list)
        {
            // The field gets its old text back; the list goes to the import box.
            var old = _title;
            Dispatcher.UIThread.Post(() =>
            {
                _titleBox.Text = old;
                DivertList(list.Text);
            });
            return;
        }
        var clean = SetEditorCopy.CleanTitle(value);
        _title = clean;
        if (clean != value)
        {
            int caret = Math.Min(_titleBox.CaretIndex, clean.Length);
            _titleBox.Text = clean;
            _titleBox.CaretIndex = caret;
        }
        if (_titleFromFile)
        {
            _titleFromFile = false;
            _titleNote.IsVisible = false;
        }
        UpdateMetaErrors();
        UpdateStats();
    }

    void SetDetails(string value)
    {
        if (value == _details) return;
        if (SetEditorCopy.PasteShapeOf(SetEditorCopy.InsertedText(_details, value), rowIsEmpty: false) is SetEditorCopy.PasteShape.List list)
        {
            var old = _details;
            Dispatcher.UIThread.Post(() =>
            {
                _detailsBox.Text = old;
                DivertList(list.Text);
            });
            return;
        }
        var clean = SetEditorCopy.CleanDescription(value);
        _details = clean;
        if (clean != value)
        {
            int caret = Math.Min(_detailsBox.CaretIndex, clean.Length);
            _detailsBox.Text = clean;
            _detailsBox.CaretIndex = caret;
        }
    }

    bool _settingLangs;

    /// <summary>"Automatisch" in a language picker: the recognition decides again (Mac: setTermAuto).</summary>
    void SetTermAuto()
    {
        _termTouched = false;
        _termDetected = false;
        AutoChanged();
    }

    void SetDefAuto()
    {
        _defTouched = false;
        _defDetected = false;
        AutoChanged();
    }

    void AutoChanged()
    {
        Reparse();
        UpdateLanguages(rows: false);
        UpdateStats();
    }

    void SetTermLang(Lang lang)
    {
        _termTouched = true;
        _termDetected = false;
        if (lang == _termLang)
        {
            UpdateLanguages(rows: false);
            return;
        }
        _termLang = lang;
        LanguagesChanged();
    }

    void SetDefLang(Lang lang)
    {
        _defTouched = true;
        _defDetected = false;
        if (lang == _defLang)
        {
            UpdateLanguages(rows: false);
            return;
        }
        _defLang = lang;
        LanguagesChanged();
    }

    void LanguagesChanged()
    {
        Reparse();
        UpdateLanguages(rows: true);
        CheckSpelling();
        UpdateStats();
    }

    /// <summary>
    /// "Begriffe und Definitionen tauschen": languages and every row (undoable). The cards of the import box turn with
    /// them: its recognition is turned too (Mac: flipSides).
    /// </summary>
    void FlipSides()
    {
        Undoable(L("Seiten tauschen"), L("Begriffe und Definitionen getauscht"), ToastTone.Neutral, includesImport: false, () =>
        {
            bool termWasAuto = TermIsAuto, defWasAuto = DefIsAuto;
            bool? swappedBefore = _parsed?.Swapped;
            _termTouched = !defWasAuto;
            _defTouched = !termWasAuto;
            _termDetected = _defDetected = false;
            (_termLang, _defLang) = (_defLang, _termLang);
            foreach (var d in _drafts)
            {
                (d.Term, d.Definition) = (d.Definition, d.Term);
                (d.TermSpelling, d.DefSpelling) = (d.DefSpelling, d.TermSpelling);
                d.Flags = SetEditorCopy.Swapped(d.Flags);
            }
            Reparse();
            // The new languages may already turn the recognition; if not, "Seiten tauschen" does.
            if (swappedBefore is { } before && _parsed?.Swapped == before) ToggleSwap();
        }, includesSwap: true);
        CheckDuplicates();
        FillCards();
        UpdateLanguages(rows: false);
        CheckSpelling();
    }

    /// <summary>Recognised languages fill the pickers the learner has not chosen (Mac: SetEditorModel.detected).</summary>
    void Detected(ParseResult result)
    {
        bool termKnown = !_termTouched && SetEditorCopy.IsKnown(result.TermLang);
        bool defKnown = !_defTouched && SetEditorCopy.IsKnown(result.DefLang);
        var nextTerm = termKnown ? result.TermLang : _termLang;
        var nextDef = defKnown ? result.DefLang : _defLang;
        if (nextTerm == nextDef) return;
        // Recognised also when it is the language the picker already had (German).
        bool marked = (termKnown && !_termDetected) || (defKnown && !_defDetected);
        if (termKnown) _termDetected = true;
        if (defKnown) _defDetected = true;
        if (nextTerm == _termLang && nextDef == _defLang)
        {
            if (!marked) return;
            UpdateLanguages(rows: false);
            UpdateStats();
            return;
        }
        _termLang = nextTerm;
        _defLang = nextDef;
        UpdateLanguages(rows: true);
        CheckSpelling();
        UpdateStats();
    }

    /// <summary>Pickers, "Automatisch erkannt", the language capsule, the column headers and (when asked) the rows.</summary>
    void UpdateLanguages(bool rows)
    {
        if (_termBox is null) return;
        _settingLangs = true;
        _termBox.SelectedIndex = TermIsAuto ? 0 : FirstLanguageIndex + Math.Max(0, SetEditorCopy.TermLanguages.ToList().IndexOf(_termLang));
        _defBox.SelectedIndex = DefIsAuto ? 0 : FirstLanguageIndex + Math.Max(0, SetEditorCopy.DefinitionLanguages.ToList().IndexOf(_defLang));
        _settingLangs = false;
        _termDetectedLabel.Opacity = _termDetected ? 1 : 0;
        _defDetectedLabel.Opacity = _defDetected ? 1 : 0;
        AutomationProperties.SetHelpText(_termBox, LanguageValue(_termLang, TermIsAuto, _termDetected));
        AutomationProperties.SetHelpText(_defBox, LanguageValue(_defLang, DefIsAuto, _defDetected));
        // Once both languages are known (not "Automatisch"; Mac: SetEditorHeader).
        _capsuleHost.Child = TermIsAuto || DefIsAuto ? null : Ui.Chip(Labels.LangPair(_termLang, _defLang));
        foreach (var header in new[] { _columnHeaderInFlow, _pinnedColumns }) if (header is not null) FillColumnHeader(header);
        if (rows) FillCards();
    }

    static string LanguageValue(Lang lang, bool isAuto, bool detected) =>
        isAuto ? SetEditorCopy.Automatic : detected ? L($"{Labels.LangName(lang)}, automatisch erkannt") : Labels.LangName(lang);

    /// <summary>The first imported file's name becomes the title while there is none (Mac: suggestTitle(fromFileName:)).</summary>
    void SuggestTitle(string fileName)
    {
        if (!IsTitleEmpty) return;
        var suggestion = SetEditorCopy.TitleFromFileName(fileName);
        if (suggestion.Length == 0) return;
        _title = suggestion;
        _titleBox.Text = suggestion;
        _titleFromFile = true;
        _titleNote.IsVisible = true;
        UpdateMetaErrors();
        UpdateStats();
    }

    void UpdateMetaErrors()
    {
        if (_titleBox is null) return;
        var p = WsTheme.P;
        bool error = _attempted && IsTitleEmpty;
        SetErrorText(_titleError, error ? SetEditorCopy.TitleMissing : null);
        _titleBox.BorderBrush = WsTheme.B(error ? p.Failure.Fill : p.Hairline);
        _titleBox.BorderThickness = new Thickness(error ? 2 : 1);
        _titleNote.IsVisible = _titleFromFile;
    }

    // MARK: Keyboard navigation

    enum Field_ { Title, Description, CustomSeparator }

    /// <summary>Enter in a field (Mac: SetEditorModel.submit): title → description → import box or first card.</summary>
    void Submit(Field_ field)
    {
        switch (field)
        {
            case Field_.Title:
                _detailsBox.Focus();
                break;
            case Field_.Description:
                if (_importOpen) FocusImportBox();
                else if (_drafts.Count > 0) FocusRow(_drafts[0]);
                break;
            case Field_.CustomSeparator:
                ParseNow();
                break;
        }
    }

    // MARK: Save

    /// <summary>
    /// Ctrl+Enter / Ctrl+S ("Lernset erstellen" / "Sichern"): the latest text of the import box counts (its pairs are
    /// cards already), then validates and creates or updates the set (Mac: SetEditorModel.save).
    /// </summary>
    void Save()
    {
        if (Model.Prompt is not null || _closed) return;
        if (_importCts is not null)
        {
            Model.ShowToast(new ToastMessage(L("Bitte warte, bis der Import fertig ist.")));
            return;
        }
        FlushParse();
        Commit();
    }

    void Commit()
    {
        if (!ValidateAll()) return;
        var title = JSCompat.Trim(_title);
        var description = JSCompat.Trim(_details);
        var cards = _drafts.Where(d => d.IsFilled).Select(d => new CardDraft(d.Id, d.TrimmedTerm, d.TrimmedDefinition, d.Starred)).ToList();
        var (termLang, defLang) = ResolvedLanguages(cards);
        try
        {
            if (IsNew)
            {
                var set = Model.CreateSet(title, termLang, defLang, cards, description);
                Close();
                Model.ShowToast(new ToastMessage(L("Lernset erstellt"), ToastTone.Success));
                Model.OpenSet(set.Id);
            }
            else
            {
                Model.Store.UpdateSet(_setId!, new SetPatch(title, description, termLang, defLang, Cards: cards));
                Model.Store.Save();
                Close();
                Model.ShowToast(new ToastMessage(L("Änderungen gespeichert"), ToastTone.Success));
                Model.OpenSet(_setId!);
            }
        }
        catch (LibraryStoreError e)
        {
            _closed = false;
            Model.ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 7000));
        }
    }

    /// <summary>
    /// The languages to save: a side still on "Automatisch" gets the language its cards are in (LangDetect), else "Andere"
    /// (term) or German (definition) (Mac: resolvedLanguages).
    /// </summary>
    (Lang Term, Lang Def) ResolvedLanguages(IReadOnlyList<CardDraft> cards) => (
        TermIsAuto ? LangDetect.DetectColumn(cards.Select(c => c.Term)).SetLang ?? Lang.Other : _termLang,
        DefIsAuto ? LangDetect.DetectColumn(cards.Select(c => c.Definition)).SetLang ?? Lang.De : _defLang);

    /// <summary>Marks every problem and moves the focus to the first one (Mac: validateAll). The errors stay on screen.</summary>
    bool ValidateAll()
    {
        _attempted = true;
        Draft? firstInvalid = null;
        foreach (var d in _drafts)
        {
            bool invalid = d.IsFilled && !d.IsComplete;
            if (d.IsInvalid != invalid)
            {
                d.IsInvalid = invalid;
                UpdateRow(d);
            }
            if (invalid) firstInvalid ??= d;
        }
        var stats = ComputeStats();
        var message = SetEditorCopy.CardsMessage(stats.Complete, stats.Invalid);
        UpdateStats();
        UpdateMetaErrors();
        if (IsTitleEmpty)
        {
            _titleBox.Focus();
            _titleBox.BringIntoView();
            Announcer.Announce(SetEditorCopy.TitleMissing, important: true);
        }
        else if (firstInvalid is not null) FocusRow(firstInvalid, definition: firstInvalid.TrimmedTerm.Length > 0);
        else if (message is not null)
        {
            var d = _drafts.FirstOrDefault(x => !x.IsComplete) ?? _drafts.FirstOrDefault();
            if (d is not null) FocusRow(d, definition: d.TrimmedTerm.Length > 0);
        }
        if (!IsTitleEmpty && message is not null) Announcer.Announce(message, important: true);
        return !IsTitleEmpty && message is null;
    }

    // MARK: Closing

    /// <summary>Esc / "Abbrechen": stops a running import first; asks before throwing changes away (Mac: cancel).</summary>
    void Cancel()
    {
        if (_importCts is not null)
        {
            CancelImport();
            return;
        }
        if (Model.Prompt is not null || _closed) return;
        if (!AskBeforeLeaving(Leave)) Leave();
    }

    /// <summary>
    /// With unsaved changes: «Änderungen verwerfen?» and true (<paramref name="leave"/> runs once confirmed); false when
    /// there is nothing to lose. Also the leave guard for every other way out (Mac: the editor sheet blocks the window).
    /// </summary>
    bool AskBeforeLeaving(Action leave)
    {
        if (!IsDirty || Model.Prompt is not null) return false;
        Model.Ask(new PromptRequest(L("Änderungen verwerfen?"),
            IsNew ? L("Dein neues Lernset ist noch nicht gespeichert und geht verloren.") : L("Deine Änderungen an diesem Lernset sind noch nicht gespeichert und gehen verloren."),
            [
                new PromptButton(L("Verwerfen"), () =>
                {
                    Close();
                    leave();
                }, IsDestructive: true),
                new PromptButton(L("Weiter bearbeiten"), IsDefault: true, IsCancel: true),
            ]));
        return true;
    }

    Func<Action, bool>? _leaveGuard;

    void ReleaseLeaveGuard()
    {
        if (_leaveGuard is not null && Model.LeaveGuard == _leaveGuard) Model.LeaveGuard = null;
    }

    /// <summary>Saved or discarded: nothing keeps running, the undo actions and their toasts go (Mac: finish).</summary>
    void Close()
    {
        _closed = true;
        StopImport(announce: false);
        ReleaseLeaveGuard();
        ForgetUndo();
    }

    void Leave()
    {
        Close();
        if (IsNew) Model.ShowOverview();
        else Model.OpenSet(_setId!);
    }

    // MARK: External changes

    /// <summary>
    /// The library changed while the editor is open (Mac: storeDidChange): a deleted set closes the editor; a set changed
    /// elsewhere is reloaded when nothing was edited. Otherwise the editor keeps working on its own copy.
    /// </summary>
    public override void LibraryChanged()
    {
        if (IsNew || _closed || !_activated) return;
        if (Model.Set(_setId!) is not { } fresh)
        {
            Close();
            Model.ShowToast(new ToastMessage(L("Dieses Lernset wurde gelöscht."), ToastTone.Danger));
            Model.ShowOverview();
            return;
        }
        if (fresh.UpdatedAt == _loadedAt || IsDirty) return;
        ForgetUndo();
        _title = fresh.Title;
        _details = fresh.Description;
        _termLang = fresh.TermLang;
        _defLang = fresh.DefLang;
        SetRows(fresh.Cards.Select(Draft.FromCard));
        _importEdits = [];
        _loadedAt = fresh.UpdatedAt;
        _baseline = Fingerprint();
        CheckDuplicates();
        base.Refresh();
        CheckSpelling();
        Model.ShowToast(new ToastMessage(L("Das Lernset wurde anderswo geändert – die neue Version ist geladen.")));
    }

    public override void Refresh()
    {
        if (_activated) base.Refresh();
    }

    public override void Activate()
    {
        _activated = true;
        _leaveGuard ??= AskBeforeLeaving;
        Model.LeaveGuard = _leaveGuard;
        ImportServices.MissingRecognizer -= OnMissingRecognizer;
        ImportServices.MissingRecognizer += OnMissingRecognizer;
        base.Refresh();
        CheckSpelling();
        // Phone: no field takes the focus by itself (that would open the keyboard over half the screen).
        if (!AppDevice.IsPhone)
            Dispatcher.UIThread.Post(() =>
            {
                if (_importOpen && IsNew && !_openFile && !IsTitleEmpty) FocusImportBox();
                else _titleBox.Focus();
            }, DispatcherPriority.Input);
        Dispatcher.UIThread.Post(TakePendingImport, DispatcherPriority.Background);
        // Ctrl+O (Mac: ⌘O "Liste importieren…"): the file chooser opens right away.
        if (_openFile) Dispatcher.UIThread.Post(() => _ = OpenFile(), DispatcherPriority.Background);
    }

    public override void Deactivate()
    {
        _activated = false;
        ReleaseLeaveGuard();
        ImportServices.MissingRecognizer -= OnMissingRecognizer;
        StopImport(announce: false);
        ForgetUndo();
    }

    // MARK: Keys

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        var mods = e.KeyModifiers;
        if ((e.Key is Key.Enter or Key.Return && mods == KeyModifiers.Control) || (e.Key == Key.S && mods == KeyModifiers.Control))
        {
            if (!isRepeat) Save();
            return true;
        }
        if (e.Key == Key.Escape && mods == KeyModifiers.None)
        {
            if (isRepeat) return true;
            if (CloseFindIfFocused()) return true;
            Cancel();
            return true;
        }
        if (e.Key == Key.Z && mods is KeyModifiers.Control or (KeyModifiers.Control | KeyModifiers.Shift) || (e.Key == Key.Y && mods == KeyModifiers.Control))
        {
            bool redo = e.Key == Key.Y || mods.HasFlag(KeyModifiers.Shift);
            // A text field undoes its own typing first.
            if (Window.FocusManager?.GetFocusedElement() is TextBox box && (redo ? box.CanRedo : box.CanUndo)) return false;
            return redo ? RedoChange() : UndoChange();
        }
        if (e.Key == Key.F && mods == KeyModifiers.Control)
        {
            if (!isRepeat) OpenFind();
            return true;
        }
        if (e.Key == Key.V && mods == KeyModifiers.Control && !Window.TextFieldFocused)
        {
            // Ctrl+V of an image or files while no text field takes it (Mac: onPasteCommand).
            if (!isRepeat) _ = Paste(filesOnly: true);
            return true;
        }
        return false;
    }

    // MARK: Undo

    /// <summary>
    /// What an undo puts back: the rows, the languages (and whether they were picked or recognised), the learner's changes
    /// to the import box's cards, and the whole import box (its text too, for changes of the box) or only its "Seiten
    /// tauschen" (turning the sides keeps what was typed in the box since).
    /// </summary>
    sealed record UndoState(IReadOnlyList<Draft.Snapshot> Rows, Lang TermLang, Lang DefLang, LanguageState Languages,
        IReadOnlyDictionary<string, ImportEdit> ImportEdits, ImportSnapshot? Import, bool? ImportSwapsSides);

    sealed record LanguageState(bool TermTouched, bool DefTouched, bool TermDetected, bool DefDetected);

    readonly UndoHistory<UndoState> _history = new();
    readonly List<Guid> _undoToasts = [];

    UndoState CurrentUndoState(bool includesImport, bool includesSwap) =>
        new(_drafts.Select(d => d.Snap()).ToList(), _termLang, _defLang, new LanguageState(_termTouched, _defTouched, _termDetected, _defDetected),
            new Dictionary<string, ImportEdit>(_importEdits), includesImport ? ImportSnap() : null, includesSwap ? _swapsSides : null);

    /// <summary>Runs <paramref name="change"/> and offers to undo it: a toast with "Rückgängig" and Ctrl+Z (Mac: undoable).</summary>
    void Undoable(string actionName, string toast, ToastTone tone, bool includesImport, Action change, bool includesSwap = false)
    {
        var before = CurrentUndoState(includesImport, includesSwap);
        change();
        var record = _history.Register(actionName, before, CurrentUndoState(includesImport, includesSwap));
        var message = new ToastMessage(toast, tone, L("Rückgängig"), () =>
        {
            if (_closed || !_activated) return;
            _history.Revert(record);
            Restore(record.Before);
        }, DurationMs: 6000);
        _undoToasts.Add(message.Id);
        Model.ShowToast(message);
    }

    bool UndoChange()
    {
        if (_history.Undo() is not { } record) return false;
        Restore(record.Before);
        Announcer.Announce(L($"Rückgängig: {record.Name}"));
        return true;
    }

    bool RedoChange()
    {
        if (_history.Redo() is not { } record) return false;
        Restore(record.After);
        Announcer.Announce(L($"Wiederholen: {record.Name}"));
        return true;
    }

    void Restore(UndoState state)
    {
        _drafts.Clear();
        _drafts.AddRange(state.Rows.Select(Draft.FromSnapshot));
        // Before the import box parses again (SyncImport finds the learner's changes here).
        _importEdits = new Dictionary<string, ImportEdit>(state.ImportEdits);
        bool languagesChanged = state.TermLang != _termLang || state.DefLang != _defLang;
        _termLang = state.TermLang;
        _defLang = state.DefLang;
        (_termTouched, _defTouched, _termDetected, _defDetected) = (state.Languages.TermTouched, state.Languages.DefTouched, state.Languages.TermDetected, state.Languages.DefDetected);
        // The cards from the import box follow the box as it is now (it may have changed since).
        if (state.Import is { } panel) RestoreImport(panel);
        else if (state.ImportSwapsSides is { } swaps && swaps != _swapsSides) SetSwapsSides(swaps);
        else if (languagesChanged && HasImportText) Reparse();
        else SyncImport(_parsed);
        CheckDuplicates();
        FillCards();
        UpdateLanguages(rows: false);
        CheckSpelling();
        UpdateStats();
    }

    /// <summary>Undo actions and their toasts only make sense while this editor (and this version of the set) is open.</summary>
    void ForgetUndo()
    {
        _history.Clear();
        foreach (var id in _undoToasts) Model.DismissToast(id);
        _undoToasts.Clear();
    }

    // MARK: Focus and scrolling

    /// <summary>Brings <paramref name="target"/> into view: its top at the top of the page, or centred.</summary>
    void ScrollTo(Control? target, bool center)
    {
        if (target is null) return;
        Dispatcher.UIThread.Post(() =>
        {
            if (_scroll?.Content is not Visual content || target.TranslatePoint(new Point(0, 0), content) is not { } point) return;
            double y = center ? point.Y - (_scroll.Viewport.Height - target.Bounds.Height) / 2 : point.Y - 12;
            double max = Math.Max(0, _scroll.Extent.Height - _scroll.Viewport.Height);
            _scroll.Offset = new Vector(_scroll.Offset.X, Math.Clamp(y, 0, max));
        }, DispatcherPriority.Loaded);
    }

    // MARK: Drops

    bool _dragInside;

    /// <summary>
    /// Files or images dropped anywhere on the editor are imported, with the "Datei loslassen" frame while they hover
    /// (Mac: onDrop on the editor sheet, SetEditorDropOverlay).
    /// </summary>
    void HookDrops(Control root)
    {
        DragDrop.SetAllowDrop(root, true);
        static bool Usable(DragEventArgs e) => e.DataTransfer.Contains(DataFormat.File) || e.DataTransfer.Contains(DataFormat.Bitmap);
        root.AddHandler(DragDrop.DragEnterEvent, (_, e) =>
        {
            if (!Usable(e)) return;
            _dragInside = true;
            ShowDropOverlay(true);
        });
        root.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            e.DragEffects = Usable(e) ? DragDropEffects.Copy : DragDropEffects.None;
        });
        root.AddHandler(DragDrop.DragLeaveEvent, (_, _) =>
        {
            // Moving between the editor's own parts leaves one and enters the next.
            _dragInside = false;
            Dispatcher.UIThread.Post(() => { if (!_dragInside) ShowDropOverlay(false); });
        });
        root.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            _dragInside = false;
            ShowDropOverlay(false);
            if (e.DataTransfer.TryGetFiles() is { } files && Sources(files) is { Count: > 0 } sources)
            {
                e.Handled = true;
                ImportSources(sources);
                return;
            }
            if (e.DataTransfer.TryGetBitmap() is { } bitmap)
            {
                // Image data without a file (dragged out of a browser or a photo app).
                e.Handled = true;
                using var png = new MemoryStream();
                bitmap.Save(png);
                ImportSources([new ImportSource("", "image/png", Data: png.ToArray())]);
            }
        });
    }

    void ShowDropOverlay(bool show)
    {
        if (_dropOverlay.IsVisible == show) return;
        _dropOverlay.IsVisible = show;
        if (show) Effects.FadeIn(_dropOverlay, Motion.Soft(0.18));
    }

    // MARK: Snapshot tool

    /// <summary>For the snapshot tool: puts <paramref name="text"/> into the import box and parses it at once.</summary>
    public void SnapshotImportText(string text)
    {
        ImportSetText(text, append: false);
        ScrollTo(_importPanel, center: false);
    }

    /// <summary>For the snapshot tool: a save attempt (shows the errors) or the cards section.</summary>
    public void SnapshotValidate() => ValidateAll();

    /// <summary>For the snapshot tool: "Zu den Karten".</summary>
    public void SnapshotShowCards() => ScrollTo(_cardsHeader, center: false);

    /// <summary>
    /// For the snapshot tool (Mac: SetEditorSnapshots «importEdits»): a pasted list, its first card changed, its second
    /// deleted, a card typed in, then "Seiten tauschen" – the changes stay, the own card stays where it is.
    /// </summary>
    public void SnapshotImportEdits(string text)
    {
        ImportSetText(text, append: false);
        var imported = _drafts.Where(d => d.ImportKey is not null).ToList();
        if (imported.Count < 2) return;
        imported[0].Term = "le monsieur (Anrede)";
        NoteImportEdit(imported[0]);
        DeleteRow(imported[1]);
        var own = new Draft { Term = "zzz eigene Karte", Definition = "selbst getippt" };
        _drafts.Add(own);
        ToggleSwap();
        foreach (var t in Model.Toasts.ToList()) Model.DismissToast(t.Id);
        FillCards();
        ScrollTo(_cardsHeader, center: false);
    }
}
