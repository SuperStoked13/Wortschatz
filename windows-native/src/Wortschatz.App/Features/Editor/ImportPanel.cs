using System.Globalization;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.App.Services;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Editor;

// "Vokabelliste importieren" (Mac: ImportPanelModel.swift, ImportPanelView.swift, ImportDetectionPanel.swift,
// ImportTextView.swift, ImportCoordinator): the paste box next to the file drop zone, the progress of PDF reading and
// text recognition, and the detection ("✨ 52 Paare erkannt · Abwechselnde Zeilen · Französisch → Deutsch") with the
// separator controls, warnings, skipped lines, the scrolling preview and "N Karten übernehmen". The list is parsed
// off the UI thread while typing (debounced), at once when an answer is needed (saving, a separator change).
public sealed partial class SetEditorScreen
{
    /// <summary>Everything needed to put the panel back (undo of "Karten übernehmen").</summary>
    sealed record ImportSnapshot(string Text, ImportSeparator Separator, string CustomSeparator, bool SwapsSides, IReadOnlyList<string> FileNotes, bool Expanded);

    string _importValue = "";
    ImportSeparator _separator = ImportSeparator.Auto;
    string _customSeparator = "";
    /// <summary>"Seiten tauschen" (the parser applies it after the automatic orientation).</summary>
    bool _swapsSides;
    /// <summary>The latest recognition; null while the box is empty.</summary>
    ParseResult? _parsed;
    /// <summary>Problems of the last file imports that did not stop them; shown until the text is cleared or taken over.</summary>
    List<string> _fileNotes = [];
    bool _importOpen;
    bool _showsSkipped;
    int _parseGeneration;
    bool _parsePending;
    IDisposable? _parseTimer;
    int? _announcedCount;
    /// <summary>Probable typos per recognised card (index in the result), filled in portions after each parse.</summary>
    Dictionary<int, IReadOnlyList<SpellingIssue>> _importTypos = [];
    int _typoGeneration;

    // Controls (made by ImportPanel).
    Control _importPanel = null!;
    TextBox _importBox = null!;
    Control _importBody = null!, _chevron = null!, _clearButton = null!, _findBar = null!;
    WsButton _importHeader = null!;
    TextBox _findBox = null!, _customBox = null!;
    TextBlock _findCount = null!;
    readonly StackPanel _detection = new() { Spacing = 12 };
    readonly Border _summaryHost = new(), _controlsHost = new(), _warningsHost = new(), _skippedHost = new(), _previewHost = new(), _applyHost = new();
    readonly TextBlock _zeroHelp = Ui.Text("", 14, color: WsTheme.P.TextSecondary, wrap: TextWrapping.Wrap);
    int _lastSummaryCount = -1;

    bool HasImportText => JSCompat.Trim(_importValue).Length > 0;

    // MARK: Panel

    Control ImportPanel()
    {
        var p = WsTheme.P;
        var icon = new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(10), Background = WsTheme.B(p.AccentSoft), Child = Icons.Icon(IconName.Sparkles, 18, p.Accent, 2), VerticalAlignment = VerticalAlignment.Top };
        icon.Child!.HorizontalAlignment = HorizontalAlignment.Center;
        string subtitle = AppDevice.ReadsPhotos ? L("Text einfügen, Datei hochladen oder Foto – die Paare werden automatisch erkannt.")
            : L("Text einfügen oder Datei hochladen – die Paare werden automatisch erkannt.");
        var texts = Ui.V(2, Ui.Text(L("Vokabelliste importieren"), 16, FontWeight.Bold), Ui.Text(subtitle, 13.5, color: p.TextSecondary, wrap: TextWrapping.Wrap));
        _chevron = Icons.Icon(IconName.ChevronRight, 16, p.TextSecondary, 2.2);
        _chevron.VerticalAlignment = VerticalAlignment.Center;
        _chevron.RenderTransformOrigin = RelativePoint.Center;
        // A grid (not a horizontal stack) so the subtitle wraps before the chevron.
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 12 };
        header.Children.Add(icon);
        Grid.SetColumn(texts, 1);
        header.Children.Add(texts);
        Grid.SetColumn(_chevron, 2);
        header.Children.Add(_chevron);
        _importHeader = Ui.Clickable(header, ToggleImport, L("Vokabelliste importieren"), 14, padding: new Thickness(4));
        AutomationProperties.SetHelpText(_importHeader, subtitle);
        AutomationProperties.SetHeadingLevel(_importHeader, 2);

        _importBox = new TextBox
        {
            Text = _importValue,
            PlaceholderText = SetEditorCopy.ImportPlaceholder,
            FontSize = 14,
            FontFamily = WsTheme.UI,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalContentAlignment = VerticalAlignment.Top,
            Padding = new Thickness(13, 10),
            CornerRadius = new CornerRadius(12),
            Background = WsTheme.B(p.Field),
            Foreground = WsTheme.B(p.Text),
            BorderBrush = WsTheme.B(p.Hairline),
            BorderThickness = new Thickness(1),
        };
        _importBox.Classes.Add("ws");
        AutomationProperties.SetName(_importBox, L("Vokabelliste zum Importieren"));
        AutomationProperties.SetHelpText(_importBox, SetEditorCopy.ImportHint);
        _importBox.TextChanged += (_, _) => EditImportText(_importBox.Text ?? "");
        // Ctrl+V of a copied image or copied files (the text box itself only pastes text).
        _importBox.AddHandler(InputElement.KeyDownEvent, (_, e) =>
        {
            if (e.Key == Key.V && e.KeyModifiers == KeyModifiers.Control) _ = Paste(fromKey: true);
        }, RoutingStrategies.Bubble, handledEventsToo: true);

        _findBar = FindBar();
        var pasteColumn = new Grid { RowDefinitions = new RowDefinitions("Auto,*"), RowSpacing = 8 };
        pasteColumn.Children.Add(_findBar);
        Grid.SetRow(_importBox, 1);
        pasteColumn.Children.Add(_importBox);
        Grid top;
        var drop = DropZone();
        if (AppDevice.IsPhone)
        {
            // Phone: the text box across the width, the file choice under it.
            top = new Grid { RowDefinitions = new RowDefinitions("180,Auto"), RowSpacing = 10 };
            top.Children.Add(pasteColumn);
            drop.Height = AppDevice.TakePhoto is not null && AppDevice.ReadsPhotos ? 220 : 170;
            Grid.SetRow(drop, 1);
            top.Children.Add(drop);
        }
        else
        {
            top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,218"), ColumnSpacing = 14, Height = 200 };
            top.Children.Add(pasteColumn);
            Grid.SetColumn(drop, 1);
            top.Children.Add(drop);
        }

        _clearButton = Ui.PlainButton(L("Text leeren"), ClearImportText, IconName.X);
        var hint = Ui.Text(SetEditorCopy.ImportHint, 13, color: p.TextSecondary, wrap: TextWrapping.Wrap);
        var tools = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10 };
        tools.Children.Add(hint);
        Grid.SetColumn(_clearButton, 1);
        tools.Children.Add(_clearButton);

        Detach(_progressHost);
        Detach(_detection);
        foreach (var host in new[] { _summaryHost, _controlsHost, _warningsHost, _skippedHost, _previewHost, _applyHost }) Detach(host);
        Detach(_zeroHelp);
        var detectionPanel = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 12),
            Background = WsTheme.B(p.Card),
            BorderBrush = WsTheme.B(p.Hairline),
            BorderThickness = new Thickness(1),
            Child = Ui.V(10, _summaryHost, _zeroHelp, _controlsHost, _warningsHost, _skippedHost),
        };
        _detection.Children.Clear();
        _detection.Children.Add(detectionPanel);
        _detection.Children.Add(_previewHost);
        _detection.Children.Add(_applyHost);

        _importBody = Ui.V(14, top, tools, _progressHost, _detection);
        RenderProgress();
        RenderControls();
        RenderDetection();
        _importPanel = Ui.Glass(Ui.V(14, _importHeader, _importBody), 22, new Thickness(16), strong: true);
        UpdateImportVisibility();
        return _importPanel;
    }

    void ToggleImport()
    {
        _importOpen = !_importOpen;
        UpdateImportVisibility();
        if (_importOpen) FocusImportBox();
    }

    /// <summary>Open or closed panel, the chevron, "Text leeren" and the detection.</summary>
    void UpdateImportVisibility()
    {
        if (_importBody is null) return;
        _importBody.IsVisible = _importOpen;
        _chevron.RenderTransform = new RotateTransform(_importOpen ? 90 : 0);
        AutomationProperties.SetItemStatus(_importHeader, _importOpen ? L("Ausgeklappt") : L("Eingeklappt"));
        _clearButton.IsVisible = HasImportText;
        _detection.IsVisible = _parsed is not null;
    }

    void FocusImportBox()
    {
        if (!_importOpen)
        {
            _importOpen = true;
            UpdateImportVisibility();
        }
        Dispatcher.UIThread.Post(() =>
        {
            _importBox.Focus();
            _importBox.CaretIndex = _importBox.Text?.Length ?? 0;
        }, DispatcherPriority.Input);
    }

    /// <summary>"Datei hierher ziehen" (Mac: ImportDropZone): formats, the file chooser and the clipboard.</summary>
    Control DropZone()
    {
        var p = WsTheme.P;
        Border Tile(IconName icon, double angle, double dx, double dy) => new()
        {
            Width = 38, Height = 44, CornerRadius = new CornerRadius(8),
            Background = WsTheme.B(p.Dark ? Palette.Hex(0x1C2230, 1) : Palette.Hex(0xFFFFFF, 1)),
            BorderBrush = WsTheme.B(p.Hairline), BorderThickness = new Thickness(1),
            BoxShadow = BoxShadows.Parse("0 1 3 0 #14000000"),
            Child = Icons.Icon(icon, 18, p.Accent),
            RenderTransform = new TransformGroup { Children = { new RotateTransform(angle), new TranslateTransform(dx, dy) } },
        };
        var tiles = new Grid { Width = 70, Height = 46, HorizontalAlignment = HorizontalAlignment.Center };
        tiles.Children.Add(Tile(IconName.Book, -8, -13, 2));
        tiles.Children.Add(Tile(IconName.Magnifier, 7, 13, -1));
        AutomationProperties.SetAccessibilityView(tiles, AccessibilityView.Raw);
        // Phone: nothing to drag; photos need text recognition (not on the phone yet).
        var title = Ui.Text(AppDevice.IsPhone ? L("Datei importieren") : L("Datei hierher ziehen"), 15, FontWeight.Bold);
        var formats = Ui.Text(AppDevice.ReadsPhotos ? L("TXT, CSV, PDF oder Foto") : L("TXT, CSV oder PDF"), 13, color: p.TextSecondary);
        title.HorizontalAlignment = formats.HorizontalAlignment = HorizontalAlignment.Center;
        var choose = Ui.Secondary(L("Datei wählen …"), () => _ = OpenFile(), IconName.Upload, height: 34);
        choose.HorizontalAlignment = HorizontalAlignment.Center;
        var paste = Ui.PlainButton(L("Aus Zwischenablage"), () => _ = Paste(), null, p.AccentText, 28);
        if (paste.Chrome.Child is StackPanel row) row.Children.Add(Ui.KeyCap("Ctrl V"));
        paste.HorizontalAlignment = HorizontalAlignment.Center;
        ToolTip.SetTip(paste, AppDevice.IsPhone ? L("Kopierten Text importieren") : L("Text, ein kopiertes Bild oder kopierte Dateien importieren (Ctrl+V im Textfeld)"));
        // Phone with a camera: photograph the list in the book (the most direct way on a phone).
        WsButton? photo = null;
        if (AppDevice.IsPhone && AppDevice.TakePhoto is not null && AppDevice.ReadsPhotos)
        {
            photo = Ui.Primary(L("Foto aufnehmen"), () => _ = TakePhoto(), null, IconName.Camera, 38);
            photo.HorizontalAlignment = HorizontalAlignment.Center;
        }
        var body = Ui.V(6, tiles, Ui.V(1, title, formats), photo, choose, paste);
        body.VerticalAlignment = VerticalAlignment.Center;
        body.HorizontalAlignment = HorizontalAlignment.Center;
        var dashed = new Grid();
        dashed.Children.Add(new Avalonia.Controls.Shapes.Rectangle
        {
            RadiusX = 12, RadiusY = 12, StrokeThickness = 1.5,
            Stroke = new SolidColorBrush(p.Accent, 0.45), StrokeDashArray = [4, 3.3],
            Fill = new SolidColorBrush(p.AccentSoft, 0.5),
        });
        dashed.Children.Add(body);
        return dashed;
    }

    // MARK: Text

    /// <summary>A change typed or pasted in the box: parsed after a short pause (Mac: edit).</summary>
    void EditImportText(string text)
    {
        if (text == _importValue) return;
        _importValue = text;
        _clearButton.IsVisible = HasImportText;
        ScheduleParse(250);
        UpdateStats();
    }

    /// <summary>Text from elsewhere (a list pasted into a card field, the clipboard button): appended or replacing, parsed at once (Mac: setText).</summary>
    void ImportSetText(string text, bool append)
    {
        var existing = JSCompat.Trim(_importValue);
        bool appends = append && existing.Length > 0;
        if (!appends) _fileNotes = [];
        _importValue = appends ? $"{existing}\n\n{text}" : text;
        _importBox.Text = _importValue;
        _importOpen = true;
        UpdateImportVisibility();
        ParseNow();
    }

    /// <summary>"Text leeren".</summary>
    void ClearImportText()
    {
        _importValue = "";
        _importBox.Text = "";
        ParseNow();
        FocusImportBox();
    }

    // MARK: Options

    /// <summary>"Trennung", the custom separator and "Seiten tauschen" (Mac: ImportDetectionPanel.controls).</summary>
    void RenderControls()
    {
        var p = WsTheme.P;
        var separators = new WsSegmented(ImportSeparatorExtensions.All.Select(s => s.Label()).ToList(), (int)_separator, 88);
        separators.HorizontalAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetName(separators, L("Trennung zwischen Begriff und Definition"));
        separators.SelectionChanged += i =>
        {
            _separator = ImportSeparatorExtensions.All[i];
            _customBox.IsVisible = _separator == ImportSeparator.Custom;
            ParseNow();
            if (_separator == ImportSeparator.Custom) Dispatcher.UIThread.Post(() => _customBox.Focus(), DispatcherPriority.Input);
        };
        _customBox = Ui.Field(L("z. B. /"), _customSeparator, 13, 32);
        _customBox.Width = 84;
        _customBox.Padding = new Thickness(10, 4);
        _customBox.CornerRadius = new CornerRadius(8);
        _customBox.IsVisible = _separator == ImportSeparator.Custom;
        AutomationProperties.SetName(_customBox, L("Eigenes Trennzeichen"));
        _customBox.TextChanged += (_, _) =>
        {
            var value = _customBox.Text ?? "";
            var limited = value.Length > SetEditorCopy.CustomSeparatorLimit ? value[..SetEditorCopy.CustomSeparatorLimit] : value;
            if (limited != value) _customBox.Text = limited;
            if (limited == _customSeparator) return;
            _customSeparator = limited;
            ScheduleParse(150);
        };
        OnKeys(_customBox, e =>
        {
            if (e.Key is not (Key.Enter or Key.Return) || e.KeyModifiers != KeyModifiers.None) return false;
            Submit(Field_.CustomSeparator);
            return true;
        });
        var swapLabel = Ui.H(7, EditorGlyphs.Swap(15, _swapsSides ? p.OnAccent : p.Text), Ui.Text(L("Seiten tauschen"), 13.5, FontWeight.SemiBold, _swapsSides ? p.OnAccent : p.Text));
        var swap = new WsButton(swapLabel, _swapsSides ? ButtonKind.Primary : ButtonKind.Glass, 32, padding: new Thickness(12, 0));
        swap.Click += (_, _) =>
        {
            _swapsSides = !_swapsSides;
            ParseNow();
            RenderControls();
        };
        ToolTip.SetTip(swap, L("Begriff und Definition in der Erkennung vertauschen"));
        AutomationProperties.SetName(swap, L("Seiten tauschen"));
        AutomationProperties.SetItemStatus(swap, _swapsSides ? L("Ein") : L("Aus"));
        var label = Ui.Text(L("Trennung"), 13.5, color: p.TextSecondary);
        AutomationProperties.SetAccessibilityView(label, AccessibilityView.Raw);
        var row = new WrapPanel { ItemSpacing = 10, LineSpacing = 8 };
        Control choice = separators;
        if (AppDevice.IsPhone)
        {
            // Phone: six separators do not fit side by side: a list instead.
            var box = new ComboBox { MinWidth = 150 };
            foreach (var s in ImportSeparatorExtensions.All) box.Items.Add(new ComboBoxItem { Content = s.Label() });
            box.SelectedIndex = (int)_separator;
            box.SelectionChanged += (_, _) =>
            {
                if (box.SelectedIndex >= 0 && box.SelectedIndex != (int)_separator) separators.Select(box.SelectedIndex);
            };
            AutomationProperties.SetName(box, L("Trennung zwischen Begriff und Definition"));
            choice = box;
        }
        row.Children.Add(Ui.H(10, label, choice, _customBox));
        row.Children.Add(swap);
        _controlsHost.Child = row;
    }

    // MARK: Parsing

    ParseOptions CurrentParseOptions() =>
        SetEditorCopy.ParseOptionsFor(_separator, _customSeparator, _swapsSides, _termLang, _termTouched, _defLang, _defTouched);

    /// <summary>Parses after <paramref name="delayMs"/>, off the UI thread, so long lists stay smooth to type in.</summary>
    void ScheduleParse(int delayMs)
    {
        _parseTimer?.Dispose();
        int generation = ++_parseGeneration;
        _parsePending = true;
        _parseTimer = DispatcherTimer.RunOnce(() =>
        {
            if (generation != _parseGeneration) return;
            var text = _importValue;
            if (JSCompat.Trim(text).Length == 0)
            {
                _parsePending = false;
                _fileNotes = [];
                ApplyParse(null);
                return;
            }
            var options = CurrentParseOptions();
            Task.Run(() => VocabParser.ParseVocab(text, options)).ContinueWith(task =>
            {
                if (task.IsFaulted || generation != _parseGeneration || _closed) return;
                _parsePending = false;
                ApplyParse(task.Result);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }, TimeSpan.FromMilliseconds(delayMs));
    }

    /// <summary>Parses the text now (an answer is needed: saving, a separator, the languages).</summary>
    void ParseNow()
    {
        _parseTimer?.Dispose();
        _parseGeneration++;
        _parsePending = false;
        if (!HasImportText)
        {
            _fileNotes = [];
            ApplyParse(null);
            return;
        }
        ApplyParse(VocabParser.ParseVocab(_importValue, CurrentParseOptions()));
    }

    /// <summary>Brings the result up to date when a parse is still scheduled (e.g. Ctrl+Enter right after typing).</summary>
    void FlushParse()
    {
        if (_parsePending) ParseNow();
    }

    /// <summary>Parses again with the current languages (after a picker change).</summary>
    void Reparse()
    {
        if (HasImportText) ParseNow();
    }

    /// <summary>The pairs still waiting in the box (0 when it is empty).</summary>
    int PendingCount()
    {
        FlushParse();
        return HasImportText ? _parsed?.Cards.Count ?? 0 : 0;
    }

    IReadOnlyList<ParsedCard> PendingCards()
    {
        FlushParse();
        return _parsed?.Cards ?? [];
    }

    void ApplyParse(ParseResult? result)
    {
        _parsed = result;
        RenderDetection();
        CheckImportTypos();
        int? count = result?.Cards.Count;
        if (count != _announcedCount)
        {
            _announcedCount = count;
            if (count is { } n) Announcer.Announce(SetEditorCopy.PairsDetected(n));
        }
        if (result is { Cards.Count: > 0 }) Detected(result);
    }

    // MARK: Detection

    /// <summary>The recognition below the paste box (Mac: ImportDetectionPanel).</summary>
    void RenderDetection()
    {
        if (_importBody is null) return;
        UpdateImportVisibility();
        if (_parsed is not { } result) return;
        var p = WsTheme.P;
        int count = result.Cards.Count;
        RenderSummary();
        _zeroHelp.IsVisible = count == 0;
        _zeroHelp.Text = _separator == ImportSeparator.Custom && _customSeparator.Length == 0
            ? L("Gib oben dein Trennzeichen ein.")
            : L("Wähle eine andere Trennung oder prüfe, ob jede Zeile einen Begriff und eine Übersetzung enthält.");

        var warnings = SetEditorCopy.Warnings(result, _fileNotes);
        _warningsHost.Child = warnings.Count == 0 ? null : Warnings(warnings);
        _warningsHost.IsVisible = warnings.Count > 0;
        RenderSkipped(result.Skipped);
        RenderPreview();

        var apply = Ui.Primary(count > 0 ? L($"{Labels.Plural(count, "Karte", "Karten")} übernehmen") : L("Karten übernehmen"), ApplyImport, null, IconName.Check, 40);
        apply.IsEnabled = count > 0;
        ToolTip.SetTip(apply, L("Die erkannten Paare in die Kartenliste übernehmen"));
        var more = count > SetEditorCopy.PreviewRows
            ? Ui.Text(L($"Alle {count} Paare in der Vorschau – scrolle darin für mehr."), 13.5, color: p.TextSecondary, wrap: TextWrapping.Wrap)
            : null;
        if (AppDevice.IsPhone)
        {
            // Phone: the note over a full-width button (beside it, it was a narrow column).
            apply.HorizontalAlignment = HorizontalAlignment.Stretch;
            _applyHost.Child = Ui.V(8, more, apply);
            return;
        }
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10 };
        if (more is not null) row.Children.Add(more);
        Grid.SetColumn(apply, 1);
        row.Children.Add(apply);
        _applyHost.Child = row;
    }

    /// <summary>"✨ 52 Paare erkannt · Abwechselnde Zeilen · Französisch → Deutsch" with its chips (Mac: ImportDetectionSummary).</summary>
    void RenderSummary()
    {
        if (_parsed is not { } result) return;
        var p = WsTheme.P;
        int count = result.Cards.Count;
        int flagged = result.Cards.Count(c => SetEditorCopy.HasMarker(c.Flags));
        int typos = _importTypos.Values.Sum(v => v.Count);
        var parts = new List<string>();
        if (count > 0)
        {
            if (SetEditorCopy.FormatLabel(result) is { } layout) parts.Add(layout);
            if (result.TermLang != Lang.Other || result.DefLang != Lang.Other) parts.Add($"{Labels.LangName(result.TermLang)} → {Labels.LangName(result.DefLang)}");
        }
        var icon = Icons.Icon(count > 0 ? IconName.Sparkles : IconName.Magnifier, 18, count > 0 ? p.Accent : p.TextSecondary, 2);
        var text = new TextBlock { FontFamily = WsTheme.UI, FontSize = 14.5, Foreground = WsTheme.B(p.Text), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        text.Inlines!.Add(new Run(SetEditorCopy.PairsDetected(count)) { FontWeight = FontWeight.SemiBold });
        if (parts.Count > 0) text.Inlines.Add(new Run(" · " + string.Join(" · ", parts)));
        var chips = new WrapPanel { ItemSpacing = 6, LineSpacing = 6, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        if (count > 0 && result.Swapped && !_swapsSides)
            chips.Children.Add(Ui.Chip(L("Seiten automatisch getauscht")));
        if (count > 0 && flagged > 0) chips.Children.Add(Ui.Chip(L($"{flagged} bitte prüfen"), p.Warning, IconName.Warning));
        if (count > 0 && typos > 0)
        {
            var chip = Ui.Chip(SetEditorCopy.TypoCount(typos), p.Warning, IconName.Pencil);
            ToolTip.SetTip(chip, L("Diese Wörter kennt die Rechtschreibprüfung nicht – nach dem Übernehmen kannst du sie mit einem Klick korrigieren."));
            chips.Children.Add(chip);
        }
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 10 };
        grid.Children.Add(icon);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        Grid.SetColumn(chips, 2);
        grid.Children.Add(chips);
        AutomationProperties.SetName(grid, string.Join(", ", new[] { text.Inlines.OfType<Run>().Select(r => r.Text) is var runs ? string.Concat(runs) : "" }
            .Concat(chips.Children.OfType<Border>().Select(c => string.Concat((c.Child as StackPanel)?.Children.OfType<TextBlock>().Select(t => t.Text) ?? [])))));
        _summaryHost.Child = grid;
        // The sparkles bounce when the count changes (Mac: symbolEffect(.bounce, value: count)).
        if (_lastSummaryCount >= 0 && count != _lastSummaryCount && count > 0) Effects.Pop(icon, 1.25);
        _lastSummaryCount = count;
    }

    /// <summary>Parser warnings and notes of partly read files (Mac: ImportWarnings).</summary>
    static Control Warnings(IReadOnlyList<string> warnings)
    {
        var p = WsTheme.P;
        var list = new StackPanel { Spacing = 4 };
        foreach (var warning in warnings)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 8 };
            var icon = Icons.Icon(IconName.Warning, 15, p.Warning.Fill, 2);
            icon.VerticalAlignment = VerticalAlignment.Top;
            icon.Margin = new Thickness(0, 1, 0, 0);
            row.Children.Add(icon);
            var t = Ui.Text(warning, 13.5, color: p.Warning.Text, wrap: TextWrapping.Wrap);
            Grid.SetColumn(t, 1);
            row.Children.Add(t);
            list.Children.Add(row);
        }
        var box = new Border { Child = list, Background = WsTheme.B(p.Warning.Soft), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 7) };
        AutomationProperties.SetName(box, L($"Hinweise: {string.Join(" ", warnings)}"));
        return box;
    }

    /// <summary>"3 Zeilen übersprungen" with the lines and reasons, folded open on click (Mac: ImportSkippedLines).</summary>
    void RenderSkipped(IReadOnlyList<SkippedLine> skipped)
    {
        _skippedHost.IsVisible = skipped.Count > 0;
        if (skipped.Count == 0)
        {
            _skippedHost.Child = null;
            return;
        }
        var p = WsTheme.P;
        var chevron = Icons.Icon(IconName.ChevronRight, 13, p.TextSecondary, 2.2);
        chevron.RenderTransformOrigin = RelativePoint.Center;
        chevron.RenderTransform = new RotateTransform(_showsSkipped ? 90 : 0);
        var title = L($"{Labels.Plural(skipped.Count, "Zeile", "Zeilen")} übersprungen");
        var toggle = Ui.Clickable(Ui.H(6, chevron, Ui.Text(title, 13.5, color: p.TextSecondary)), () =>
        {
            _showsSkipped = !_showsSkipped;
            RenderSkipped(skipped);
        }, title, 8, padding: new Thickness(2, 3));
        toggle.HorizontalAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetItemStatus(toggle, _showsSkipped ? L("Ausgeklappt") : L("Eingeklappt"));
        var body = Ui.V(2, toggle);
        if (_showsSkipped)
        {
            var lines = new StackPanel { Spacing = 2, Margin = new Thickness(20, 2, 0, 0) };
            foreach (var line in skipped)
            {
                var row = new Grid { ColumnDefinitions = new ColumnDefinitions("70,*,Auto"), ColumnSpacing = 10 };
                row.Children.Add(Ui.Text(L($"Zeile {line.Line}"), 13, color: p.TextSecondary));
                var text = Ui.Text(line.Text.Length == 0 ? "–" : line.Text, 13);
                Grid.SetColumn(text, 1);
                row.Children.Add(text);
                var reason = Ui.Text(SetEditorCopy.SkipReasonText(line.Reason), 13, color: p.TextSecondary);
                Grid.SetColumn(reason, 2);
                row.Children.Add(reason);
                AutomationProperties.SetName(row, L($"Zeile {line.Line}: {line.Text}, {SetEditorCopy.SkipReasonText(line.Reason)}"));
                lines.Children.Add(row);
            }
            body.Children.Add(lines);
        }
        _skippedHost.Child = body;
    }

    const double PreviewRowHeight = 28;

    /// <summary>
    /// The recognised pairs as a table that scrolls after eight rows; flagged rows and rows with probable typos carry an
    /// amber marker with the reason (Mac: ImportPreviewTable).
    /// </summary>
    void RenderPreview()
    {
        if (_parsed is not { Cards.Count: > 0 } result)
        {
            _previewHost.Child = null;
            _previewHost.IsVisible = false;
            return;
        }
        var p = WsTheme.P;
        _previewHost.IsVisible = true;
        // Phone: a narrower number column, headers without the languages (they stand in the summary above) and rows that
        // wrap – «BEGRIFF · FRA…», «la limitation de v…», «der Donaudamp…» were cut (06.11.2026).
        bool phone = AppDevice.IsPhone;
        string columns = phone ? "26,*,*,20" : "40,*,*,26";
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions(columns), ColumnSpacing = 10, Margin = new Thickness(10, 7) };
        header.Children.Add(Ui.Eyebrow("#"));
        var th = Ui.Eyebrow(phone ? L("Begriff") : L($"Begriff · {Labels.LangName(result.TermLang)}"));
        Grid.SetColumn(th, 1);
        header.Children.Add(th);
        var dh = Ui.Eyebrow(phone ? L("Definition") : L($"Definition · {Labels.LangName(result.DefLang)}"));
        Grid.SetColumn(dh, 2);
        header.Children.Add(dh);

        var cards = result.Cards;
        var typos = _importTypos;
        var list = new ItemsControl
        {
            ItemsPanel = new FuncTemplate<Panel?>(() => new VirtualizingStackPanel()),
            ItemsSource = Enumerable.Range(0, cards.Count).ToList(),
            ItemTemplate = new FuncDataTemplate<int>((index, _) =>
            {
                var card = cards[index];
                var reasons = new[] { SetEditorCopy.FlagTooltip(card.Flags), SetEditorCopy.TypoTooltip(typos.GetValueOrDefault(index) ?? []) }.Where(r => r is not null).ToList();
                string? tooltip = reasons.Count == 0 ? null : string.Join("\n", reasons);
                var row = phone
                    ? new Grid { ColumnDefinitions = new ColumnDefinitions(columns), ColumnSpacing = 8, MinHeight = PreviewRowHeight, Margin = new Thickness(8, 5) }
                    : new Grid { ColumnDefinitions = new ColumnDefinitions(columns), ColumnSpacing = 10, Height = PreviewRowHeight, Margin = new Thickness(10, 0) };
                row.Children.Add(Ui.Text($"{index + 1}", 13, color: tooltip is null ? p.TextSecondary : p.Warning.Text));
                var term = Cell(card.Term, result.TermLang, L("Begriff fehlt"), FontWeight.SemiBold);
                Grid.SetColumn(term, 1);
                row.Children.Add(term);
                var def = Cell(card.Definition, result.DefLang, L("Definition fehlt"), FontWeight.Normal);
                Grid.SetColumn(def, 2);
                row.Children.Add(def);
                if (tooltip is not null)
                {
                    var marker = new Border { Background = Brushes.Transparent, Child = Icons.Icon(IconName.Warning, 14, p.Warning.Fill, 2.2), VerticalAlignment = VerticalAlignment.Center };
                    ToolTip.SetTip(marker, tooltip);
                    AutomationProperties.SetName(marker, tooltip);
                    Grid.SetColumn(marker, 3);
                    row.Children.Add(marker);
                }
                var holder = new Border { Child = row, Background = index % 2 == 1 ? WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.04) : Palette.Hex(0x101828, 0.03)) : Brushes.Transparent };
                AutomationProperties.SetName(holder, $"{index + 1}: {card.Term} – {card.Definition}{(tooltip is null ? "" : $" ({tooltip})")}");
                return holder;
            }, supportsRecycling: false),
        };
        var scroller = new ScrollViewer
        {
            Content = list,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            Height = PreviewRowHeight * Math.Min(cards.Count, SetEditorCopy.PreviewRows) + 2,
        };
        if (phone)
        {
            // Phone: rows wrap and grow; the table takes what they need, up to about the same room.
            scroller.Height = double.NaN;
            scroller.MaxHeight = PreviewRowHeight * SetEditorCopy.PreviewRows * 1.6 + 2;
        }
        var table = new Border
        {
            CornerRadius = new CornerRadius(12),
            ClipToBounds = true,
            Background = WsTheme.B(p.Card),
            BorderBrush = WsTheme.B(p.Hairline),
            BorderThickness = new Thickness(1),
            Child = Ui.V(0, header, new Border { Height = 1, Background = WsTheme.B(p.Hairline) }, scroller),
        };
        AutomationProperties.SetName(table, L("Vorschau der erkannten Karten"));
        _previewHost.Child = table;

        static Control Cell(string text, Lang lang, string missing, FontWeight weight)
        {
            var p = WsTheme.P;
            if (text.Length == 0)
            {
                var t = Ui.Text(missing, 13.5, color: p.Warning.Text);
                t.FontStyle = FontStyle.Italic;
                return t;
            }
            var cell = StudyText.InLang(text, lang, 13.5, weight);
            if (AppDevice.IsPhone)
            {
                cell.TextWrapping = TextWrapping.Wrap;
                StudyText.HyphenateToWidth(cell, text, lang);
            }
            else
            {
                cell.TextWrapping = TextWrapping.NoWrap;
                cell.TextTrimming = TextTrimming.CharacterEllipsis;
            }
            cell.VerticalAlignment = VerticalAlignment.Center;
            ToolTip.SetTip(cell, text);
            return cell;
        }
    }

    /// <summary>Probable typos in the recognised pairs, 20 cards at a time (Mac: ImportPanelModel.checkTypos).</summary>
    void CheckImportTypos()
    {
        int generation = ++_typoGeneration;
        if (_parsed is not { Cards.Count: > 0 } result || (!Model.Speller.Supports(result.TermLang) && !Model.Speller.Supports(result.DefLang)))
        {
            if (_importTypos.Count == 0) return;
            _importTypos = [];
            RenderSummary();
            RenderPreview();
            return;
        }
        var found = new Dictionary<int, IReadOnlyList<SpellingIssue>>();
        void Step(int from)
        {
            if (generation != _typoGeneration || _closed) return;
            int end = Math.Min(result.Cards.Count, from + 20);
            for (int i = from; i < end; i++)
            {
                var issues = Model.Speller.Issues(result.Cards[i].Term, result.TermLang).Concat(Model.Speller.Issues(result.Cards[i].Definition, result.DefLang)).ToList();
                if (issues.Count > 0) found[i] = issues;
            }
            if (end < result.Cards.Count)
            {
                Dispatcher.UIThread.Post(() => Step(end), DispatcherPriority.Background);
                return;
            }
            bool same = found.Count == _importTypos.Count && found.All(kv => _importTypos.TryGetValue(kv.Key, out var v) && v.Count == kv.Value.Count);
            _importTypos = found;
            if (same) return;
            RenderSummary();
            RenderPreview();
        }
        Dispatcher.UIThread.Post(() => Step(0), DispatcherPriority.Background);
    }

    // MARK: Taking the list over

    /// <summary>"N Karten übernehmen": replaces an empty list, else asks Anhängen / Ersetzen (Mac: applyImport).</summary>
    void ApplyImport()
    {
        if (Model.Prompt is not null) return;
        var cards = PendingCards();
        if (!HasImportText || cards.Count == 0) return;
        int existing = _drafts.Count(d => d.IsFilled);
        if (existing == 0)
        {
            TakeOver(cards, append: false);
            return;
        }
        var question = L($"Dein Lernset enthält schon {Labels.Plural(existing, "Karte", "Karten")}. Möchtest du die {Labels.Plural(cards.Count, "neue Karte", "neuen Karten")} anhängen oder die bisherigen ersetzen?");
        if (IsEditing) question += "\n\n" + L("Beim Ersetzen bleibt der Lernfortschritt für gleiche Begriffe erhalten.");
        Model.Ask(new PromptRequest(L("Karten übernehmen"), question,
        [
            new PromptButton(L("Anhängen"), () => TakeOver(cards, append: true), IsDefault: true),
            new PromptButton(L("Ersetzen"), () => TakeOver(cards, append: false)),
            new PromptButton(L("Abbrechen"), IsCancel: true),
        ]));
    }

    /// <summary>Takes the list over, undoable together with the import box (Mac: apply(_:mode:)).</summary>
    void TakeOver(IReadOnlyList<ParsedCard> cards, bool append)
    {
        var created = cards.Select(Draft.FromParsed).ToList();
        Undoable(L("Karten übernehmen"), L($"{Labels.Plural(cards.Count, "Karte", "Karten")} übernommen"), ToastTone.Success, includesImport: true, () =>
        {
            if (append) AppendRows(created);
            else SetRows(IsEditing ? WithPreservedIds(created, _drafts) : created);
            ResetImport();
            _importOpen = false;
            UpdateImportVisibility();
        });
        CheckDuplicates();
        FillCards();
        CheckSpelling();
        if (append && created.Count > 0) ScrollToRow(created[0]);
        else ScrollTo(_cardsHeader, center: false);
    }

    /// <summary>Saving with a list still in the box: taken over without asking about undo (Mac: takeOverPending).</summary>
    void TakeOverPending(bool append)
    {
        var created = PendingCards().Select(Draft.FromParsed).ToList();
        if (append) AppendRows(created);
        else SetRows(created);
        ResetImport();
        _importOpen = false;
        UpdateImportVisibility();
        CheckDuplicates();
        FillCards();
        CheckSpelling();
    }

    ImportSnapshot ImportSnap() => new(_importValue, _separator, _customSeparator, _swapsSides, _fileNotes.ToList(), _importOpen);

    void RestoreImport(ImportSnapshot snapshot)
    {
        _importValue = snapshot.Text;
        _separator = snapshot.Separator;
        _customSeparator = snapshot.CustomSeparator;
        _swapsSides = snapshot.SwapsSides;
        _importOpen = snapshot.Expanded;
        _showsSkipped = false;
        if (_importBox is not null)
        {
            _importBox.Text = _importValue;
            RenderControls();
        }
        ParseNow();
        // ParseNow drops the notes of an empty box only.
        _fileNotes = snapshot.FileNotes.ToList();
        RenderDetection();
        UpdateImportVisibility();
    }

    /// <summary>Empties the panel (after its cards were taken over).</summary>
    void ResetImport() => RestoreImport(new ImportSnapshot("", ImportSeparator.Auto, "", false, [], _importOpen));

    // MARK: Find (Mac: the text view's find bar, Ctrl+F)

    List<int> _findMatches = [];
    int _findIndex = -1;

    Control FindBar()
    {
        var p = WsTheme.P;
        _findBox = Ui.Field(L("Suchen"), "", 13, 30);
        _findBox.Padding = new Thickness(10, 4);
        _findBox.CornerRadius = new CornerRadius(8);
        AutomationProperties.SetName(_findBox, L("In der Liste suchen"));
        _findBox.TextChanged += (_, _) => RunFind(0);
        OnKeys(_findBox, e =>
        {
            if (e.Key is Key.Enter or Key.Return)
            {
                RunFind(e.KeyModifiers.HasFlag(KeyModifiers.Shift) ? -1 : 1);
                return true;
            }
            return false;
        });
        _findCount = Ui.Text("", 12.5, color: p.TextSecondary);
        var previous = Ui.IconButton(IconName.ChevronLeft, L("Vorheriger Treffer (Shift+Enter)"), () => RunFind(-1), 28, ButtonKind.Plain);
        var next = Ui.IconButton(IconName.ChevronRight, L("Nächster Treffer (Enter)"), () => RunFind(1), 28, ButtonKind.Plain);
        var done = Ui.PlainButton(L("Fertig"), CloseFind, null, p.AccentText, 28);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto,Auto,Auto"), ColumnSpacing = 4, IsVisible = false };
        grid.Children.Add(_findBox);
        _findCount.Margin = new Thickness(6, 0);
        Grid.SetColumn(_findCount, 1);
        grid.Children.Add(_findCount);
        Grid.SetColumn(previous, 2);
        grid.Children.Add(previous);
        Grid.SetColumn(next, 3);
        grid.Children.Add(next);
        Grid.SetColumn(done, 4);
        grid.Children.Add(done);
        return grid;
    }

    void OpenFind()
    {
        FocusImportBox();
        _findBar.IsVisible = true;
        Dispatcher.UIThread.Post(() =>
        {
            _findBox.Focus();
            _findBox.SelectAll();
        }, DispatcherPriority.Input);
        RunFind(0);
    }

    void CloseFind()
    {
        _findBar.IsVisible = false;
        _findMatches = [];
        _findIndex = -1;
        _importBox.Focus();
    }

    bool CloseFindIfFocused()
    {
        if (_findBar is null || !_findBar.IsVisible || !_findBox.IsFocused) return false;
        CloseFind();
        return true;
    }

    /// <summary>Finds the query (ignoring case and accents) and selects the match; <paramref name="step"/> moves on.</summary>
    void RunFind(int step)
    {
        var query = _findBox.Text ?? "";
        var text = _importBox.Text ?? "";
        _findMatches = [];
        if (query.Length > 0)
        {
            var compare = CultureInfo.GetCultureInfo("de-CH").CompareInfo;
            const CompareOptions options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;
            int at = 0;
            while (at <= text.Length - 1 && compare.IndexOf(text, query, at, options) is var found and >= 0)
            {
                _findMatches.Add(found);
                at = found + Math.Max(1, query.Length);
            }
        }
        if (_findMatches.Count == 0)
        {
            _findIndex = -1;
            _findCount.Text = query.Length == 0 ? "" : L("Keine Treffer");
            return;
        }
        _findIndex = step == 0 ? Math.Clamp(_findIndex, 0, _findMatches.Count - 1) : ((_findIndex + step) % _findMatches.Count + _findMatches.Count) % _findMatches.Count;
        _findCount.Text = L($"{_findIndex + 1} von {_findMatches.Count}");
        int start = _findMatches[_findIndex];
        _importBox.CaretIndex = start + query.Length;
        _importBox.SelectionStart = start;
        _importBox.SelectionEnd = start + query.Length;
        Announcer.Announce(_findCount.Text);
    }

    // MARK: Files

    /// <summary>"Datei wählen …" and Ctrl+O: text and CSV files, PDFs and photos, several at once.</summary>
    async Task OpenFile()
    {
        var files = await Window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = L("Vokabelliste öffnen"),
            AllowMultiple = true,
            FileTypeFilter =
            [
                AppDevice.ReadsPhotos
                    ? new FilePickerFileType(L("Vokabellisten, PDF und Fotos"))
                    {
                        Patterns = ["*.txt", "*.csv", "*.tsv", "*.text", "*.pdf", "*.png", "*.jpg", "*.jpeg", "*.heic", "*.heif", "*.webp", "*.tif", "*.tiff", "*.bmp", "*.gif"],
                        // Android's document picker filters by type, not by name.
                        MimeTypes = ["text/plain", "text/csv", "text/comma-separated-values", "text/tab-separated-values", "application/pdf", "image/*"],
                    }
                    : new FilePickerFileType(L("Vokabellisten und PDF"))
                    {
                        Patterns = ["*.txt", "*.csv", "*.tsv", "*.text", "*.pdf"],
                        MimeTypes = ["text/plain", "text/csv", "text/comma-separated-values", "text/tab-separated-values", "application/pdf"],
                    },
                FilePickerFileTypes.All,
            ],
        });
        ImportSources(await SourcesAsync(files));
    }

    /// <summary>"Foto aufnehmen" (phone): the camera app's picture goes through the same import as a chosen photo.</summary>
    async Task TakePhoto()
    {
        if (AppDevice.TakePhoto is not { } take) return;
        byte[]? bytes;
        try { bytes = await take(); }
        catch (Exception) { bytes = null; }
        if (bytes is null) return;
        ImportSources([ImportSource.FromData(bytes, $"Foto {DateTime.Now:HH.mm}.jpg", "image/jpeg")]);
    }

    /// <summary>Files as import sources: their path (read in the background) or, without one, their bytes.</summary>
    static List<ImportSource> Sources(IEnumerable<IStorageItem> items) =>
        items.OfType<IStorageFile>().Select(f => f.TryGetLocalPath() is { } path ? new ImportSource(f.Name, FilePath: path) : null)
            .Where(s => s is not null).Select(s => s!).ToList();

    static async Task<List<ImportSource>> SourcesAsync(IEnumerable<IStorageItem> items)
    {
        var list = new List<ImportSource>();
        foreach (var file in items.OfType<IStorageFile>())
        {
            if (file.TryGetLocalPath() is { } path)
            {
                list.Add(new ImportSource(file.Name, FilePath: path));
                continue;
            }
            await using var stream = await file.OpenReadAsync();
            using var memory = new MemoryStream();
            await stream.CopyToAsync(memory);
            list.Add(new ImportSource(file.Name, Data: memory.ToArray()));
        }
        return list;
    }

    /// <summary>
    /// "Aus Zwischenablage": text is added below the list in the box (Mac: setText(append:)); otherwise copied files or an
    /// image are imported. After Ctrl+V in the box (<paramref name="fromKey"/>) the box has pasted the text already;
    /// <paramref name="filesOnly"/>: Ctrl+V outside any text field takes only files and images.
    /// </summary>
    async Task Paste(bool fromKey = false, bool filesOnly = false)
    {
        if (Window.Clipboard is not { } clipboard) return;
        var text = await ClipboardExtensions.TryGetTextAsync(clipboard);
        if (!string.IsNullOrEmpty(text) && !filesOnly)
        {
            if (!fromKey) ImportSetText(text, append: true);
            return;
        }
        if (await ClipboardExtensions.TryGetFilesAsync(clipboard) is { } files && files.Any())
        {
            ImportSources(await SourcesAsync(files));
            return;
        }
        using var bitmap = await ClipboardExtensions.TryGetBitmapAsync(clipboard);
        if (bitmap is not null)
        {
            using var png = new MemoryStream();
            bitmap.Save(png);
            ImportSources([new ImportSource("", "image/png", Data: png.ToArray())]);
            return;
        }
        if (!fromKey && !filesOnly) Model.ShowToast(new ToastMessage(L("In der Zwischenablage ist kein Text, kein Bild und keine Datei.")));
    }

    // MARK: File import (Mac: ImportPanelModel.importSources, ImportCoordinator)

    ImportPipeline? _pipeline;
    CancellationTokenSource? _importCts;
    ImportProgress? _progress;
    bool _showProgress;
    readonly Border _progressHost = new();
    ProgressLine? _progressLine;
    TextBlock? _progressText, _progressPercent;
    DateTime _lastProgressAnnouncement;
    /// <summary>Languages whose missing Windows text recognizer was already explained (once per run).</summary>
    static readonly HashSet<Lang> s_missingRecognizerShown = [];

    /// <summary>Reads files in the background and appends their text.</summary>
    void ImportSources(List<ImportSource> sources)
    {
        if (sources.Count == 0) return;
        if (_importCts is not null)
        {
            Model.ShowToast(new ToastMessage(L("Bitte warte, bis der aktuelle Import fertig ist.")));
            return;
        }
        if (!_importOpen)
        {
            _importOpen = true;
            UpdateImportVisibility();
        }
        var cts = new CancellationTokenSource();
        _importCts = cts;
        _progress = new ImportProgress(0, L("Datei wird gelesen …"));
        _showProgress = false;
        UpdateStats();
        // The progress row appears only for slow imports (text files finish at once), like the Mac and the web app.
        DispatcherTimer.RunOnce(() =>
        {
            if (_importCts != cts) return;
            _showProgress = true;
            RenderProgress();
        }, TimeSpan.FromMilliseconds(160));
        var termLang = _termLang;
        var defLang = _defLang;
        var pipeline = _pipeline ??= ImportServices.CreatePipeline();
        _ = Task.Run(async () =>
        {
            ImportBatch? batch = null;
            try
            {
                batch = await pipeline.ReadAllAsync(sources, termLang, defLang,
                    update => Dispatcher.UIThread.Post(() =>
                    {
                        if (_importCts != cts) return;
                        _progress = update;
                        RenderProgress();
                    }), cts.Token);
            }
            catch (Exception e) when (e is ImportError or OperationCanceledException) { }
            Dispatcher.UIThread.Post(() => FinishImport(cts, batch));
        });
    }

    /// <summary>"Abbrechen" or Esc: stops reading and recognition, drops the result.</summary>
    void CancelImport() => StopImport(announce: true);

    void StopImport(bool announce)
    {
        if (_importCts is not { } cts) return;
        _importCts = null;
        cts.Cancel();
        _progress = null;
        _showProgress = false;
        RenderProgress();
        if (_activated && !_closed) UpdateStats();
        if (announce) Model.ShowToast(new ToastMessage(L("Import abgebrochen")));
    }

    /// <summary>Errors as toasts, texts below the current text, notes kept, the title suggested, a summary toast.</summary>
    void FinishImport(CancellationTokenSource cts, ImportBatch? batch)
    {
        if (_importCts != cts) return; // cancelled (already said) or superseded
        _importCts = null;
        cts.Dispose();
        _progress = null;
        _showProgress = false;
        RenderProgress();
        UpdateStats();
        if (batch is null)
        {
            Model.ShowToast(new ToastMessage(L("Import abgebrochen")));
            return;
        }
        foreach (var message in batch.ErrorMessages) Model.ShowToast(new ToastMessage(message, ToastTone.Danger, DurationMs: 7000));
        if (batch.Texts.Count == 0) return;
        var notes = (HasImportText ? _fileNotes : []).Concat(batch.Warnings).ToList();
        _importValue = batch.AppendedTo(_importValue);
        _importBox.Text = _importValue;
        ParseNow();
        _fileNotes = notes;
        RenderDetection();
        if (batch.FirstName is { } name) SuggestTitle(name);
        int count = _parsed?.Cards.Count ?? 0;
        var pairs = Labels.Plural(count, "Paar", "Paare");
        if (batch.Warnings.Count > 0)
            // Do not suggest completeness: part of the content could not be read.
            Model.ShowToast(new ToastMessage(count > 0
                ? L($"Text teilweise erkannt – {pairs} gefunden. Nicht alles konnte gelesen werden, siehe Hinweis.")
                : L("Text teilweise erkannt – noch keine Paare gefunden. Nicht alles konnte gelesen werden, siehe Hinweis."),
                ToastTone.Warning, DurationMs: 7000));
        else if (count > 0) Model.ShowToast(new ToastMessage(L($"Text erkannt – {pairs} gefunden. Prüfe die Vorschau."), ToastTone.Success));
        else Model.ShowToast(new ToastMessage(L("Text eingefügt. Es wurden noch keine Paare erkannt.")));
        // The detection scrolls into view (Mac: revealToken).
        ScrollTo(_detection, center: false);
    }

    /// <summary>Progress of a slow import (PDF pages, text recognition) with "Abbrechen" (Mac: ImportProgressRow).</summary>
    void RenderProgress()
    {
        var p = WsTheme.P;
        if (!_showProgress || _progress is not { } progress)
        {
            _progressHost.Child = null;
            _progressLine = null;
            return;
        }
        double fraction = Math.Clamp(progress.Fraction, 0, 1);
        if (_progressLine is null || _progressText is null || _progressPercent is null)
        {
            _progressText = Ui.Text(progress.Message, 14, FontWeight.SemiBold, wrap: TextWrapping.NoWrap);
            _progressText.TextTrimming = TextTrimming.CharacterEllipsis;
            _progressPercent = Ui.Text("", 13, color: p.TextTertiary);
            _progressPercent.VerticalAlignment = VerticalAlignment.Center;
            _progressLine = new ProgressLine(fraction, p.Accent, double.NaN) { HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(_progressLine, L("Fortschritt der Texterkennung"));
            var cancel = Ui.Secondary(L("Abbrechen"), CancelImport, keyHint: "Esc", height: 32);
            ToolTip.SetTip(cancel, L("Import abbrechen (Esc)"));
            _progressHost.Child = new Border
            {
                CornerRadius = new CornerRadius(12),
                Background = WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.05) : Palette.Hex(0xFFFFFF, 0.7)),
                Padding = new Thickness(14, 10),
                Child = Ui.V(8, Ui.Row(_progressText, Ui.H(10, _progressPercent, cancel)), _progressLine),
            };
        }
        else _progressLine.SetValue(fraction);
        if (_progressText.Text != progress.Message && DateTime.UtcNow - _lastProgressAnnouncement > TimeSpan.FromSeconds(1.5))
        {
            _lastProgressAnnouncement = DateTime.UtcNow;
            Announcer.Announce(progress.Message);
        }
        _progressText.Text = progress.Message;
        _progressPercent.Text = L($"{(int)Math.Round(fraction * 100)} %");
        AutomationProperties.SetHelpText(_progressLine, L($"{(int)Math.Round(fraction * 100)} Prozent"));
    }

    /// <summary>Windows has no text recognizer for a set language: says once where to add it.</summary>
    void OnMissingRecognizer(Lang lang) => Dispatcher.UIThread.Post(() =>
    {
        if (!s_missingRecognizerShown.Add(lang)) return;
        // Phone: the recognizer comes from Google Play services on first use (Chinese) – a moment later it works.
        Model.ShowToast(new ToastMessage(AppDevice.IsPhone
            ? L($"Die Texterkennung für {Labels.LangName(lang)} ist auf diesem Handy nicht verfügbar. Gelesen wurde nur lateinische Schrift.")
            : L($"Windows fehlt die Texterkennung für {Labels.LangName(lang)} (Einstellungen › Zeit und Sprache › Sprache)."),
            ToastTone.Warning, DurationMs: 9000));
    });
}
