using System.Text;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.SetDetail;

/// <summary>
/// "Als Text exportieren" (Mac: TextExportSheet.swift, port of <c>openExport</c> in set.js): separators for terms and
/// cards, a preview, "Kopieren" (Ctrl+Shift+C) and "Sichern …" (Enter; a UTF-8 text file named after the set). With
/// "Neue Zeile" between cards the list can be imported again here and in Quizlet.
/// </summary>
public sealed class TextExportSheet
{
    static readonly (string Label, string Separator)[] TermSeparators = [("Tab", "\t"), ("Komma", ", "), ("Bindestrich", " - ")];
    static readonly (string Label, string Separator)[] CardSeparators = [("Neue Zeile", "\n"), ("Strichpunkt", ";")];

    readonly AppModel _model;
    readonly MainView _window;
    readonly VocabSet _set;
    int _term, _card;
    readonly SelectableTextBlock _preview;

    TextExportSheet(AppModel model, MainView window, VocabSet set)
    {
        _model = model;
        _window = window;
        _set = set;
        _preview = new SelectableTextBlock
        {
            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New, monospace"),
            FontSize = 13,
            Foreground = WsTheme.B(WsTheme.P.Text),
            TextWrapping = TextWrapping.NoWrap,
            Margin = new Thickness(10, 8),
        };
        AutomationProperties.SetName(_preview, "Exportierter Text");
        UpdatePreview();
    }

    public static void Show(AppModel model, MainView window, VocabSet set) => new TextExportSheet(model, window, set).Present();

    /// <summary>The exported text with the chosen separators.</summary>
    string Text => Backup.SetToText(_set, TermSeparators[_term].Separator, CardSeparators[_card].Separator);

    /// <summary>
    /// The preview: real tabs would jump to 8-column stops; like the web app's tab size, they are expanded to the column
    /// after the longest term (at most 48), so the list reads as two columns. Copying and saving keep the tabs.
    /// </summary>
    public static string PreviewText(string text, IEnumerable<Card> cards, bool tabs)
    {
        if (!tabs) return text;
        int longest = cards.Select(c => c.Term.Length).DefaultIfEmpty(0).Max();
        int tabSize = Math.Min(48, longest + 3);
        var sb = new StringBuilder();
        int column = 0;
        foreach (var ch in text)
        {
            switch (ch)
            {
                case '\t':
                    int spaces = tabSize - column % tabSize;
                    sb.Append(' ', spaces);
                    column += spaces;
                    break;
                case '\n':
                    sb.Append(ch);
                    column = 0;
                    break;
                default:
                    sb.Append(ch);
                    column++;
                    break;
            }
        }
        return sb.ToString();
    }

    void UpdatePreview() => _preview.Text = PreviewText(Text, _set.Cards, _term == 0);

    void Present()
    {
        var p = WsTheme.P;
        var termPicker = new WsSegmented(TermSeparators.Select(s => s.Label).ToList(), _term, 104);
        termPicker.SelectionChanged += i =>
        {
            _term = i;
            UpdatePreview();
        };
        AutomationProperties.SetName(termPicker, "Zwischen Begriff und Definition");
        var cardPicker = new WsSegmented(CardSeparators.Select(s => s.Label).ToList(), _card, 112);
        cardPicker.SelectionChanged += i =>
        {
            _card = i;
            UpdatePreview();
        };
        AutomationProperties.SetName(cardPicker, "Zwischen den Karten");
        // Phone: the choices take the width the labels leave (and shrink to it).
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions(AppDevice.IsPhone ? "Auto,*" : "Auto,Auto"), RowDefinitions = new RowDefinitions("Auto,Auto"), ColumnSpacing = 14, RowSpacing = 10 };
        void Add(Control c, int row, int column)
        {
            Grid.SetRow(c, row);
            Grid.SetColumn(c, column);
            c.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(c);
        }
        var termLabel = Ui.Text("Zwischen Begriff und Definition", 14, color: p.TextSecondary);
        termLabel.HorizontalAlignment = HorizontalAlignment.Right;
        var cardLabel = Ui.Text("Zwischen den Karten", 14, color: p.TextSecondary);
        cardLabel.HorizontalAlignment = HorizontalAlignment.Right;
        Add(termLabel, 0, 0);
        Add(termPicker, 0, 1);
        Add(cardLabel, 1, 0);
        Add(cardPicker, 1, 1);
        termPicker.HorizontalAlignment = cardPicker.HorizontalAlignment = HorizontalAlignment.Left;

        var scroller = new ScrollViewer
        {
            Content = _preview,
            Height = 260,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var previewBox = new Border
        {
            Child = scroller,
            CornerRadius = new CornerRadius(10),
            Background = WsTheme.B(p.Field),
            BorderBrush = WsTheme.B(p.Hairline),
            BorderThickness = new Thickness(1),
            ClipToBounds = true,
        };

        _model.Ask(new PromptRequest("Als Text exportieren",
            "Kopiere die Liste oder sichere sie als Textdatei. Mit «Neue Zeile» zwischen den Karten lässt sie sich in Wortschatz und Quizlet wieder importieren.",
            [
                new PromptButton("Kopieren", () => _ = Copy(), StaysOpen: true),
                new PromptButton("Abbrechen", IsCancel: true),
                new PromptButton("Sichern …", () => _ = Save(), IsDefault: true, StaysOpen: true),
            ])
        {
            Content = Ui.V(14, grid, previewBox),
            Width = 620,
            KeyHandler = e =>
            {
                // Ctrl+Shift+C (Mac: ⇧⌘C) copies the list; Ctrl+C the selection in the preview (or the list).
                if (e.Key == Key.C && e.KeyModifiers.HasFlag(KeyModifiers.Control))
                {
                    bool selection = !e.KeyModifiers.HasFlag(KeyModifiers.Shift) && !string.IsNullOrEmpty(_preview.SelectedText);
                    _ = selection ? CopyText(_preview.SelectedText) : Copy();
                    return true;
                }
                if (e.Key == Key.A && e.KeyModifiers == KeyModifiers.Control)
                {
                    _preview.SelectAll();
                    return true;
                }
                return false;
            },
        });
    }

    Task Copy() => CopyText(Text);

    async Task CopyText(string text)
    {
        bool copied = false;
        try
        {
            if (_window.Clipboard is { } clipboard)
            {
                await ClipboardExtensions.SetTextAsync(clipboard, text);
                copied = true;
            }
        }
        catch (Exception) { }
        _model.ShowToast(copied
            ? new ToastMessage("Text kopiert", ToastTone.Success)
            : new ToastMessage("Kopieren hat nicht geklappt. Markiere den Text und kopiere ihn von Hand.", ToastTone.Danger));
    }

    async Task Save()
    {
        var text = Text;
        try
        {
            var file = await _window.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Als Text exportieren",
                SuggestedFileName = Backup.TextFileName(_set.Title),
                DefaultExtension = "txt",
                FileTypeChoices = [new FilePickerFileType("Text") { Patterns = ["*.txt"] }],
            });
            if (file is null) return;
            await using (var stream = await file.OpenWriteAsync())
            {
                // UTF-8 without BOM, like the web app's downloads.
                var data = new UTF8Encoding(false).GetBytes(text);
                if (stream.CanSeek) stream.SetLength(0);
                await stream.WriteAsync(data);
            }
            _model.ClosePrompt();
            _model.ShowToast(new ToastMessage($"«{AppModel.ShortTitle(_set.Title)}» als Textdatei exportiert", ToastTone.Success));
        }
        catch (Exception)
        {
            _model.ShowToast(new ToastMessage("Der Export ist fehlgeschlagen.", ToastTone.Danger, DurationMs: 6000));
        }
    }
}
