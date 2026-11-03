using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Editor;

/// <summary>
/// "Neues Lernset" / "Lernset bearbeiten" (Mac: EditorSheet.swift, SetEditorModel.swift, SetEditorCardList.swift,
/// SetEditorMetaSection.swift and the import panel ImportPanelView/ImportDetectionPanel): title, description and
/// languages, "Vokabelliste importieren" (paste or open a TXT/CSV file; VocabParser recognises term and translation
/// and the languages, with a preview), and the card list. Ctrl+Enter saves, Esc cancels.
/// Not yet on Windows: PDF and photo import (the Mac uses PDFKit and Vision for those).
/// </summary>
public sealed class SetEditorScreen : Screen
{
    sealed class Draft
    {
        public string? Id;
        public string Term = "";
        public string Definition = "";
        public bool Starred;
    }

    readonly string? _setId;
    readonly bool _openFile;
    readonly List<Draft> _drafts = [];
    readonly HashSet<Draft> _invalid = [];
    bool _titleMissing;
    string _baseline = "";
    readonly TextBox _title, _description, _importText;
    readonly ComboBox _termLang, _defLang;
    readonly ItemsControl _cardList = new() { ItemsPanel = new FuncTemplate<Panel?>(() => new VirtualizingStackPanel()) };
    readonly StackPanel _importResult = new() { Spacing = 10 };
    readonly TextBlock _countLabel = Ui.Text("", 14, FontWeight.SemiBold);
    bool _importOpen;
    bool _swap;
    ParseResult? _parsed;
    DispatcherTimer? _parseTimer;
    Control? _importBody;

    public SetEditorScreen(AppModel model, MainWindow window, string? setId, bool startWithImport, bool openFile = false) : base(model, window)
    {
        _setId = setId;
        _openFile = openFile;
        var set = setId is null ? null : model.Set(setId);
        _title = Ui.Field("Titel, z. B. «Unité 3 – Les personnes»", set?.Title ?? "", 22, 52);
        _title.FontWeight = FontWeight.Bold;
        _description = Ui.Field("Beschreibung (freiwillig)", set?.Description ?? "", 14, 40);
        _termLang = LangBox(set?.TermLang ?? Lang.Fr);
        _defLang = LangBox(set?.DefLang ?? Lang.De);
        // The rows' placeholders and writing direction follow the languages.
        _termLang.SelectionChanged += (_, _) => { if (_activated) FillCards(); };
        _defLang.SelectionChanged += (_, _) => { if (_activated) FillCards(); };
        if (set is not null)
            foreach (var c in set.Cards) _drafts.Add(new Draft { Id = c.Id, Term = c.Term, Definition = c.Definition, Starred = c.Starred });
        while (_drafts.Count < 3) _drafts.Add(new Draft());
        _importOpen = startWithImport || set is null;
        _importText = Ui.Field("Liste hier einfügen – eine Zeile pro Begriff, z. B. «la maison – das Haus» oder abwechselnd Begriff und Übersetzung", "", 14, 150);
        _importText.AcceptsReturn = true;
        _importText.TextWrapping = TextWrapping.Wrap;
        _importText.VerticalContentAlignment = VerticalAlignment.Top;
        _importText.MaxHeight = 260;
        _importText.TextChanged += (_, _) => ScheduleParse();
        _cardList.ItemTemplate = new FuncDataTemplate<Draft>((d, _) => d is null ? new Border() : CardRow(d, _drafts.IndexOf(d)), supportsRecycling: false);
        _title.TextChanged += (_, _) =>
        {
            if (_titleMissing && JSCompat.Trim(_title.Text ?? "").Length > 0)
            {
                _titleMissing = false;
                _title.BorderBrush = WsTheme.B(WsTheme.P.Hairline);
            }
        };
        _baseline = Fingerprint();
    }

    /// <summary>What the editor would save, to tell whether anything changed (Mac: fingerprint/baseline).</summary>
    string Fingerprint() => string.Join("\u0001", new[] { _title.Text ?? "", _description.Text ?? "", $"{LangOf(_termLang)}", $"{LangOf(_defLang)}" }
        .Concat(_drafts.Where(d => IsFilled(d)).Select(d => $"{d.Id}\u0002{d.Term}\u0002{d.Definition}\u0002{d.Starred}")));

    static bool IsFilled(Draft d) => JSCompat.Trim(d.Term).Length > 0 || JSCompat.Trim(d.Definition).Length > 0;
    static bool IsComplete(Draft d) => JSCompat.Trim(d.Term).Length > 0 && JSCompat.Trim(d.Definition).Length > 0;

    /// <summary>Unsaved changes (also: text waiting in the import box).</summary>
    bool IsDirty => Fingerprint() != _baseline || JSCompat.Trim(_importText.Text ?? "").Length > 0;

    bool IsNew => _setId is null;

    static ComboBox LangBox(Lang selected)
    {
        var box = new ComboBox { MinWidth = 190 };
        foreach (var lang in Labels.LANG_ORDER) box.Items.Add(new ComboBoxItem { Content = Labels.LangName(lang) });
        box.SelectedIndex = Array.IndexOf(Labels.LANG_ORDER, selected);
        return box;
    }

    static Lang LangOf(ComboBox box) => box.SelectedIndex >= 0 ? Labels.LANG_ORDER[box.SelectedIndex] : Lang.Other;

    protected override Control Build()
    {
        var p = WsTheme.P;
        foreach (var c in new Control[] { _title, _description, _termLang, _defLang, _importText, _cardList, _importResult, _countLabel })
            Detach(c);

        var header = Ui.Row(
            Ui.V(4, Ui.Eyebrow(IsNew ? "Neues Lernset" : "Lernset bearbeiten"),
                Ui.Text(IsNew ? "Tippe deine Vokabeln ein oder importiere eine ganze Liste." : "Ändere Begriffe, ergänze neue oder importiere eine weitere Liste.",
                    15, color: p.TextSecondary, wrap: TextWrapping.Wrap)),
            Ui.H(10, Ui.Secondary("Abbrechen", Cancel, keyHint: "Esc"), Ui.Primary(IsNew ? "Erstellen" : "Sichern", Save, "Ctrl ↵", height: 40)));

        var langs = Ui.H(18,
            Ui.V(6, Ui.Eyebrow("Begriff"), _termLang),
            Ui.Text("→", 18, FontWeight.Bold, p.TextTertiary),
            Ui.V(6, Ui.Eyebrow("Definition"), _defLang));
        if (langs.Children[1] is Control arrow) arrow.Margin = new Thickness(0, 20, 0, 0);
        var meta = Ui.Glass(Ui.V(12, _title, _description, langs), 22, new Thickness(20), strong: true);

        var content = new StackPanel { Spacing = 18, Margin = new Thickness(34, 14, 34, 24) };
        content.Children.Add(header);
        content.Children.Add(meta);
        content.Children.Add(ImportPanel());
        content.Children.Add(Ui.Row(Ui.H(10, Ui.Text("Karten", 18, FontWeight.Bold), _countLabel),
            Ui.Secondary("Karte hinzufügen", () => AddRow(focus: true), IconName.Plus)));
        content.Children.Add(_cardList);
        FillCards();
        return Ui.Scroll(content);
    }

    static void Detach(Control c)
    {
        if (c.Parent is Panel panel) panel.Children.Remove(c);
        else if (c.Parent is Decorator d) d.Child = null;
        else if (c.Parent is ContentControl cc) cc.Content = null;
    }

    // MARK: Cards

    /// <summary>
    /// Shows the rows. The list virtualizes (only the rows on screen exist), so showing it again after a change is cheap
    /// even for 300 cards; the row numbers come from the draft's position when a row is made.
    /// </summary>
    void FillCards()
    {
        _cardList.ItemsSource = _drafts.ToList();
        UpdateCount();
    }

    /// <summary>Scrolls the row of <paramref name="d"/> into view and focuses its term (or definition) field.</summary>
    void FocusRow(Draft d, bool definition = false)
    {
        int index = _drafts.IndexOf(d);
        if (index < 0) return;
        Dispatcher.UIThread.Post(() =>
        {
            _cardList.ScrollIntoView(index);
            Dispatcher.UIThread.Post(() =>
            {
                if (_cardList.ContainerFromIndex(index) is not { } container) return;
                var fields = container.GetVisualDescendants().OfType<TextBox>().ToList();
                if (fields.Count < 2) return;
                var field = definition ? fields[1] : fields[0];
                field.BringIntoView();
                field.Focus();
            }, DispatcherPriority.Loaded);
        }, DispatcherPriority.Loaded);
    }

    void UpdateCount()
    {
        int filled = _drafts.Count(d => JSCompat.Trim(d.Term).Length > 0 || JSCompat.Trim(d.Definition).Length > 0);
        _countLabel.Text = Labels.Plural(filled, "Karte", "Karten");
        _countLabel.Foreground = WsTheme.B(WsTheme.P.TextTertiary);
    }

    Control CardRow(Draft d, int index)
    {
        var p = WsTheme.P;
        var term = Ui.Field($"Begriff · {Labels.LangName(LangOf(_termLang))}", d.Term, 15, 42);
        var def = Ui.Field($"Definition · {Labels.LangName(LangOf(_defLang))}", d.Definition, 15, 42);
        if (LangOf(_termLang).IsRTL()) term.FlowDirection = FlowDirection.RightToLeft;
        if (LangOf(_defLang).IsRTL()) def.FlowDirection = FlowDirection.RightToLeft;
        void MarkInvalid()
        {
            bool invalid = _invalid.Contains(d);
            term.BorderBrush = WsTheme.B(invalid && JSCompat.Trim(d.Term).Length == 0 ? p.Failure.Fill : p.Hairline);
            def.BorderBrush = WsTheme.B(invalid && JSCompat.Trim(d.Definition).Length == 0 ? p.Failure.Fill : p.Hairline);
        }
        MarkInvalid();
        void Changed()
        {
            if (_invalid.Contains(d) && (IsComplete(d) || !IsFilled(d))) _invalid.Remove(d);
            MarkInvalid();
            UpdateCount();
        }
        term.TextChanged += (_, _) => { d.Term = term.Text ?? ""; Changed(); };
        def.TextChanged += (_, _) => { d.Definition = def.Text ?? ""; Changed(); };
        def.KeyDown += (_, e) =>
        {
            // Enter in the last definition adds a card (like tabbing on in Quizlet).
            if (e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.None && _drafts.IndexOf(d) == _drafts.Count - 1)
            {
                AddRow(focus: true);
                e.Handled = true;
            }
        };
        WsButton? star = null;
        star = Ui.IconButton(d.Starred ? IconName.StarFilled : IconName.Star, d.Starred ? "Markierung entfernen" : "Markieren", () =>
        {
            d.Starred = !d.Starred;
            // Only the star changes: the icon is swapped in place.
            if (star?.Chrome.Child is Border holder)
            {
                holder.Child = Icons.Icon(d.Starred ? IconName.StarFilled : IconName.Star, 18, d.Starred ? p.Star : p.TextTertiary);
                ToolTip.SetTip(star, d.Starred ? "Markierung entfernen" : "Markieren");
            }
        }, 32, ButtonKind.Plain, d.Starred ? p.Star : p.TextTertiary);
        var delete = Ui.IconButton(IconName.Trash, "Karte löschen", () =>
        {
            if (!_drafts.Remove(d)) return;
            _invalid.Remove(d);
            if (_drafts.Count == 0) _drafts.Add(new Draft());
            FillCards();
        }, 32, ButtonKind.Plain, p.TextTertiary);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("28,*,*,Auto,Auto"), ColumnSpacing = 10 };
        grid.Children.Add(Ui.Text($"{index + 1}", 13, FontWeight.SemiBold, p.TextTertiary, align: TextAlignment.Right));
        Grid.SetColumn(term, 1);
        grid.Children.Add(term);
        Grid.SetColumn(def, 2);
        grid.Children.Add(def);
        Grid.SetColumn(star, 3);
        grid.Children.Add(star);
        Grid.SetColumn(delete, 4);
        grid.Children.Add(delete);
        var row = Ui.Glass(grid, 16, new Thickness(10, 8), shadow: false);
        row.Margin = new Thickness(0, 0, 0, 6);
        return row;
    }

    void AddRow(bool focus)
    {
        var d = new Draft();
        _drafts.Add(d);
        FillCards();
        if (focus) FocusRow(d);
    }

    // MARK: Import

    Control ImportPanel()
    {
        var p = WsTheme.P;
        var toggle = Ui.Clickable(Ui.Row(
            Ui.H(12, new Border { Width = 38, Height = 38, CornerRadius = new CornerRadius(12), Background = WsTheme.B(p.AccentSoft), Child = Icons.Icon(IconName.Download, 19, p.Accent) },
                Ui.V(2, Ui.Text("Vokabelliste importieren", 16, FontWeight.Bold),
                    Ui.Text("Text einfügen oder Datei öffnen – Begriff, Übersetzung und Sprachen werden automatisch erkannt.", 13, color: p.TextTertiary, wrap: TextWrapping.Wrap))),
            Icons.Icon(_importOpen ? IconName.ChevronLeft : IconName.ChevronRight, 18, p.TextTertiary)), () =>
            {
                _importOpen = !_importOpen;
                ReplaceImportPanel();
                if (_importOpen) Dispatcher.UIThread.Post(() => _importText.Focus(), DispatcherPriority.Input);
            }, "Vokabelliste importieren", 16, padding: new Thickness(4));
        if (toggle.Chrome.Child is Grid tg && tg.Children[0] is StackPanel sp && sp.Children[0] is Border icon) icon.Child!.HorizontalAlignment = HorizontalAlignment.Center;
        var body = Ui.V(14, toggle);
        if (_importOpen)
        {
            body.Children.Add(_importText);
            body.Children.Add(Ui.H(10,
                Ui.Secondary("Datei öffnen …", () => _ = OpenFile(), IconName.Upload),
                Ui.Secondary("Aus Zwischenablage", () => _ = Paste(), IconName.Copy),
                Ui.PlainButton("Text leeren", () => _importText.Text = "")));
            body.Children.Add(_importResult);
            RenderImportResult();
        }
        _importBody = Ui.Glass(body, 22, new Thickness(16), strong: true);
        return _importBody;
    }

    void ScheduleParse()
    {
        _parseTimer?.Stop();
        _parseTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _parseTimer.Tick += (_, _) =>
        {
            _parseTimer?.Stop();
            var text = _importText.Text ?? "";
            _parsed = JSCompat.Trim(text).Length == 0 ? null : VocabParser.ParseVocab(text);
            RenderImportResult();
        };
        _parseTimer.Start();
    }

    IReadOnlyList<(string Term, string Definition)> ParsedPairs =>
        _parsed is null ? [] : _parsed.Cards.Select(c => _swap ? (c.Definition, c.Term) : (c.Term, c.Definition)).ToList();

    void RenderImportResult()
    {
        var p = WsTheme.P;
        _importResult.Children.Clear();
        if (_parsed is not { } r) return;
        var pairs = ParsedPairs;
        var (termLang, defLang) = _swap ? (r.DefLang, r.TermLang) : (r.TermLang, r.DefLang);
        if (pairs.Count == 0)
        {
            _importResult.Children.Add(Ui.Text("Keine Paare erkannt. Prüfe, ob jede Zeile einen Begriff und eine Übersetzung enthält.", 14, color: p.Warning.Text, wrap: TextWrapping.Wrap));
            return;
        }
        var swap = new CheckBox { Content = "Seiten tauschen", IsChecked = _swap };
        swap.IsCheckedChanged += (_, _) =>
        {
            _swap = swap.IsChecked == true;
            RenderImportResult();
        };
        _importResult.Children.Add(Ui.Row(
            Ui.H(10, Ui.Chip($"{Labels.LangName(termLang)} → {Labels.LangName(defLang)}"), Ui.Text(Labels.Plural(pairs.Count, "Paar", "Paare") + " erkannt", 14, FontWeight.SemiBold)),
            swap));
        foreach (var w in r.Warnings) _importResult.Children.Add(Ui.H(8, Icons.Icon(IconName.Info, 15, p.Warning.Text), Ui.Text(w, 13, color: p.Warning.Text, wrap: TextWrapping.Wrap)));
        if (r.Skipped.Count > 0) _importResult.Children.Add(Ui.Text($"{Labels.Plural(r.Skipped.Count, "Zeile", "Zeilen")} übersprungen", 13, color: p.TextTertiary));
        var preview = new StackPanel { Spacing = 2 };
        foreach (var (term, def) in pairs.Take(8))
        {
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), ColumnSpacing = 14, Margin = new Thickness(10, 5) };
            g.Children.Add(StudyText.InLang(term.Length > 0 ? term : "Begriff fehlt", termLang, 14, FontWeight.SemiBold, term.Length > 0 ? null : p.Failure.Text));
            var d = StudyText.InLang(def.Length > 0 ? def : "Definition fehlt", defLang, 14, color: def.Length > 0 ? p.TextSecondary : p.Failure.Text);
            Grid.SetColumn(d, 1);
            g.Children.Add(d);
            preview.Children.Add(g);
        }
        if (pairs.Count > 8) preview.Children.Add(Ui.Text($"… und {pairs.Count - 8} weitere", 13, color: p.TextTertiary));
        _importResult.Children.Add(Ui.Card(preview, 14, new Thickness(6)));
        _importResult.Children.Add(Ui.Primary($"{Labels.Plural(pairs.Count, "Karte", "Karten")} übernehmen", ApplyImport, null, IconName.Check, 40));
    }

    /// <summary>The detected languages of the waiting list (after "Seiten tauschen").</summary>
    (Lang Term, Lang Def) ParsedLangs => _parsed is not { } r ? (LangOf(_termLang), LangOf(_defLang)) : _swap ? (r.DefLang, r.TermLang) : (r.TermLang, r.DefLang);

    /// <summary>"N Karten übernehmen": replaces an empty list, else asks Anhängen / Ersetzen (Mac: applyImport).</summary>
    void ApplyImport()
    {
        var pairs = ParsedPairs;
        if (pairs.Count == 0) return;
        int existing = _drafts.Count(IsFilled);
        if (existing == 0)
        {
            TakeOver(append: false);
            return;
        }
        var question = $"Dein Lernset enthält schon {Labels.Plural(existing, "Karte", "Karten")}. Möchtest du die {Labels.Plural(pairs.Count, "neue Karte", "neuen Karten")} anhängen oder die bisherigen ersetzen?";
        if (!IsNew) question += "\n\nBeim Ersetzen bleibt der Lernfortschritt für gleiche Begriffe erhalten.";
        Model.Ask(new PromptRequest("Karten übernehmen", question,
        [
            new PromptButton("Anhängen", () => TakeOver(append: true), IsDefault: true),
            new PromptButton("Ersetzen", () => TakeOver(append: false)),
            new PromptButton("Abbrechen", IsCancel: true),
        ]));
    }

    /// <summary>Takes the waiting list over: appended, or replacing the rows (same terms keep their card and star).</summary>
    void TakeOver(bool append)
    {
        var pairs = ParsedPairs;
        var (termLang, defLang) = ParsedLangs;
        var created = pairs.Select(pr => new Draft { Term = pr.Term, Definition = pr.Definition }).ToList();
        bool hadCards = _drafts.Any(IsFilled);
        if (append)
        {
            _drafts.RemoveAll(d => !IsFilled(d));
            _drafts.AddRange(created);
        }
        else
        {
            if (!IsNew)
            {
                // Replacing keeps the ids (and the progress) of rows with the same term (Mac: withPreservedIDs).
                var pool = _drafts.Where(d => d.Id is not null && TermKey(d.Term).Length > 0).GroupBy(d => TermKey(d.Term))
                    .ToDictionary(g => g.Key, g => new Queue<Draft>(g));
                foreach (var row in created)
                {
                    if (!pool.TryGetValue(TermKey(row.Term), out var matches) || matches.Count == 0) continue;
                    var match = matches.Dequeue();
                    row.Id = match.Id;
                    row.Starred = match.Starred;
                }
            }
            _drafts.Clear();
            _drafts.AddRange(created);
        }
        if (_drafts.Count == 0) _drafts.Add(new Draft());
        _invalid.Clear();
        // The detected languages apply when the set had no cards yet.
        if (!hadCards)
        {
            _termLang.SelectedIndex = Array.IndexOf(Labels.LANG_ORDER, termLang);
            _defLang.SelectedIndex = Array.IndexOf(Labels.LANG_ORDER, defLang);
        }
        _importText.Text = "";
        _parseTimer?.Stop();
        _parsed = null;
        _importOpen = false;
        Model.ShowToast(new ToastMessage($"{Labels.Plural(pairs.Count, "Karte", "Karten")} übernommen", ToastTone.Success));
        Refresh();
    }

    /// <summary>The key that matches a term to the old row it replaces (Mac: SetEditorCopy.termKey).</summary>
    static string TermKey(string term) => JSCompat.Lower(TextNormalizer.NormalizeBasic(term)).TrimEnd('.', '!', '?');

    /// <summary>Parses the import box at once (Save right after pasting must not miss the list).</summary>
    void ParseNow()
    {
        if (_parseTimer is null || !_parseTimer.IsEnabled) return;
        _parseTimer.Stop();
        var text = _importText.Text ?? "";
        _parsed = JSCompat.Trim(text).Length == 0 ? null : VocabParser.ParseVocab(text);
    }

    async Task OpenFile()
    {
        var files = await Window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Vokabelliste öffnen",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Text und CSV") { Patterns = ["*.txt", "*.csv", "*.tsv", "*.text"] }, FilePickerFileTypes.All],
        });
        if (files.Count == 0) return;
        await using var stream = await files[0].OpenReadAsync();
        using var reader = new StreamReader(stream);
        _importText.Text = await reader.ReadToEndAsync();
        if (!_importOpen)
        {
            _importOpen = true;
            ReplaceImportPanel();
        }
        // The file's name becomes the title while there is none (Mac: suggestTitle(fromFileName:)).
        if (JSCompat.Trim(_title.Text ?? "").Length == 0)
        {
            var name = System.IO.Path.GetFileNameWithoutExtension(files[0].Name).Replace('_', ' ').Trim();
            if (name.Length >= 2) _title.Text = name;
        }
    }

    async Task Paste()
    {
        if (Window.Clipboard is not { } clipboard) return;
        var text = await ClipboardExtensions.TryGetTextAsync(clipboard);
        if (!string.IsNullOrEmpty(text)) _importText.Text = text;
    }

    // MARK: Save

    /// <summary>
    /// Ctrl+Enter: takes a list still waiting in the import box over (asking first when the list has cards), checks
    /// the title and the cards, then creates or updates the set (Mac: SetEditorModel.save).
    /// </summary>
    void Save()
    {
        if (Model.Prompt is not null) return;
        ParseNow();
        int pending = JSCompat.Trim(_importText.Text ?? "").Length > 0 ? ParsedPairs.Count : 0;
        if (pending > 0)
        {
            if (!_drafts.Any(IsFilled)) TakeOver(append: false);
            else
            {
                var waiting = pending == 1 ? "wartet noch 1 erkanntes Paar" : $"warten noch {pending} erkannte Paare";
                Model.Ask(new PromptRequest("Liste noch nicht übernommen", $"Im Importfeld {waiting}. Sollen sie vor dem Speichern angehängt werden?",
                [
                    new PromptButton($"{Labels.Plural(pending, "Karte", "Karten")} anhängen", () =>
                    {
                        TakeOver(append: true);
                        Commit();
                    }, IsDefault: true),
                    new PromptButton("Ohne Liste", Commit),
                    new PromptButton("Abbrechen", IsCancel: true),
                ]));
                return;
            }
        }
        Commit();
    }

    void Commit()
    {
        if (!Validate()) return;
        var title = JSCompat.Trim(_title.Text ?? "");
        var description = JSCompat.Trim(_description.Text ?? "");
        var cards = _drafts.Where(IsFilled).Select(d => new CardDraft(d.Id, d.Term, d.Definition, d.Starred)).ToList();
        try
        {
            if (IsNew)
            {
                var set = Model.CreateSet(title, LangOf(_termLang), LangOf(_defLang), cards, description);
                _baseline = Fingerprint();
                Model.ShowToast(new ToastMessage("Lernset erstellt", ToastTone.Success));
                Model.OpenSet(set.Id);
            }
            else
            {
                Model.Store.UpdateSet(_setId!, new SetPatch(title, description, LangOf(_termLang), LangOf(_defLang), Cards: cards));
                Model.Store.Save();
                _baseline = Fingerprint();
                Model.ShowToast(new ToastMessage("Änderungen gespeichert", ToastTone.Success));
                Model.OpenSet(_setId!);
            }
        }
        catch (LibraryStoreError e)
        {
            Model.ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 7000));
        }
    }

    /// <summary>Marks every problem and focuses the first one (Mac: validateAll).</summary>
    bool Validate()
    {
        _invalid.Clear();
        foreach (var d in _drafts) if (IsFilled(d) && !IsComplete(d)) _invalid.Add(d);
        int complete = _drafts.Count(IsComplete);
        _titleMissing = JSCompat.Trim(_title.Text ?? "").Length == 0;
        string? message = _titleMissing ? "Gib deinem Lernset einen Titel."
            : complete == 0 ? "Füge mindestens eine Karte mit Begriff und Definition hinzu."
            : _invalid.Count > 0 ? $"{Labels.Plural(_invalid.Count, "Karte ist", "Karten sind")} unvollständig – ergänze Begriff und Definition oder lösche sie."
            : null;
        if (message is null) return true;
        FillCards();
        _title.BorderBrush = WsTheme.B(_titleMissing ? WsTheme.P.Failure.Fill : WsTheme.P.Hairline);
        Model.ShowToast(new ToastMessage(message, ToastTone.Warning, DurationMs: 5000));
        if (_titleMissing) _title.Focus();
        else FocusFirstIncomplete();
        return false;
    }

    void FocusFirstIncomplete()
    {
        var d = _drafts.FirstOrDefault(x => _invalid.Contains(x)) ?? _drafts.FirstOrDefault(x => !IsComplete(x));
        if (d is not null) FocusRow(d, definition: JSCompat.Trim(d.Term).Length > 0);
    }

    /// <summary>Esc: asks first when there are unsaved changes (Mac: cancel → .discard).</summary>
    void Cancel()
    {
        if (Model.Prompt is not null) return;
        if (IsDirty)
        {
            Model.Ask(new PromptRequest("Änderungen verwerfen?",
                IsNew ? "Dein neues Lernset ist noch nicht gespeichert und geht verloren." : "Deine Änderungen an diesem Lernset sind noch nicht gespeichert und gehen verloren.",
                [
                    new PromptButton("Verwerfen", Leave, IsDestructive: true),
                    new PromptButton("Weiter bearbeiten", IsDefault: true, IsCancel: true),
                ]));
            return;
        }
        Leave();
    }

    void Leave()
    {
        if (IsNew) Model.ShowOverview();
        else Model.OpenSet(_setId!);
    }

    /// <summary>Opens or closes the import box without rebuilding the card rows.</summary>
    void ReplaceImportPanel()
    {
        if (_importBody?.Parent is not Panel parent) return;
        int index = parent.Children.IndexOf(_importBody);
        foreach (var c in new Control[] { _importText, _importResult }) Detach(c);
        parent.Children[index] = ImportPanel();
    }

    public override void Refresh()
    {
        if (_activated) base.Refresh();
    }

    /// <summary>The editor works on its own copy (Mac: SetEditorModel): store notifications do not rebuild the form.</summary>
    public override void LibraryChanged() { }

    bool _activated;

    public override void Activate()
    {
        _activated = true;
        base.Refresh();
        Dispatcher.UIThread.Post(() => (_importOpen && IsNew && !_openFile && JSCompat.Trim(_title.Text ?? "").Length > 0 ? _importText : _title).Focus(), DispatcherPriority.Input);
        // Ctrl+O (Mac: ⌘O "Liste importieren…"): the file chooser opens right away.
        if (_openFile) Dispatcher.UIThread.Post(() => _ = OpenFile(), DispatcherPriority.Background);
    }

    public override void Deactivate() => _activated = false;

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        if (isRepeat) return false;
        if (e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.Control)
        {
            Save();
            return true;
        }
        if (e.Key == Key.Escape && e.KeyModifiers == KeyModifiers.None)
        {
            Cancel();
            return true;
        }
        return false;
    }
}
