using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Settings;

/// <summary>
/// "Backup importieren" (Mac: BackupImportSheet.swift, AppModel+Actions prepareBackupImport / performBackupImport; port
/// of <c>openImportDialog</c> in settings.js): the file is read and validated first, then a sheet shows what it contains
/// and lets the learner merge it into the library or replace everything. An empty library restores the backup
/// completely (progress, statistics and settings too). Enter imports, Esc cancels, ↑/↓ switch the choice. Works with
/// backups of the web app, the Mac app and this app.
/// </summary>
public static class BackupImportSheet
{
    /// <summary>The file chooser (only .json, Mac: allowedContentTypes [.json]), then the sheet.</summary>
    public static async Task Choose(AppModel model, MainView window)
    {
        IReadOnlyList<IStorageFile> files;
        try
        {
            files = await window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "Backup importieren",
                AllowMultiple = false,
                FileTypeFilter = [new FilePickerFileType("Wortschatz-Backup (JSON)") { Patterns = ["*.json"] }],
            });
        }
        catch (Exception)
        {
            ShowError(model, Backup.READ_ERROR);
            return;
        }
        if (files.Count == 0) return;
        await Prepare(model, window, files[0]);
    }

    /// <summary>Validates a chosen or dropped file and opens the sheet (or explains the problem).</summary>
    public static async Task Prepare(AppModel model, MainView window, IStorageFile file)
    {
        if (!file.Name.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
        {
            ShowError(model, "Bitte wähle eine Backup-Datei im JSON-Format.");
            return;
        }
        byte[] data;
        try
        {
            await using var stream = await file.OpenReadAsync();
            using var memory = new MemoryStream();
            await stream.CopyToAsync(memory);
            data = memory.ToArray();
        }
        catch (Exception)
        {
            ShowError(model, Backup.READ_ERROR);
            return;
        }
        PrepareData(model, window, file.Name, data);
    }

    /// <summary>A backup's bytes (a file shared from another app): checked, then the sheet.</summary>
    public static void PrepareData(AppModel model, MainView window, string name, byte[] data)
    {
        BackupImportPreview preview;
        try
        {
            preview = BackupImportPreview.Read(name, data, model.Store.ListSets());
        }
        catch (Exception e) when (e is LibraryStoreError or BackupFileError)
        {
            ShowError(model, e.Message);
            return;
        }
        catch (Exception)
        {
            ShowError(model, "Diese Datei ist kein gültiges Wortschatz-Backup.");
            return;
        }
        Show(model, window, preview);
    }

    /// <summary>"Backup kann nicht importiert werden" with the reason (Mac: the alert of SettingsDataTab).</summary>
    public static void ShowError(AppModel model, string message) =>
        model.Ask(new PromptRequest("Backup kann nicht importiert werden", message, [new PromptButton("OK", IsDefault: true, IsCancel: true)]));

    /// <summary>The sheet for a preview; mode null = the default (replace for an empty library, else merge).</summary>
    public static void Show(AppModel model, MainView window, BackupImportPreview preview, ImportMode? mode = null)
    {
        var chosen = mode ?? (preview.LibraryIsEmpty ? ImportMode.Replace : ImportMode.Merge);
        bool destructive = chosen == ImportMode.Replace && !preview.LibraryIsEmpty;
        var p = WsTheme.P;
        var content = Ui.V(16, FileInfo(model, preview));
        if (preview.LibraryIsEmpty)
            content.Children.Add(Ui.Text("Das Backup wird vollständig wiederhergestellt – mit Lernfortschritt, Statistik und Einstellungen.",
                14.5, color: p.TextSecondary, wrap: TextWrapping.Wrap));
        else
        {
            void Choose(ImportMode m)
            {
                if (m != chosen) Show(model, window, preview, m);
            }
            content.Children.Add(Ui.V(8,
                Ui.Text("Wie möchtest du importieren?", 15, FontWeight.SemiBold),
                Choice("Zusammenführen", "Lernsets aus dem Backup kommen dazu. Deine übrigen Lernsets und Einstellungen bleiben erhalten.",
                    preview.MergeDetail, false, chosen == ImportMode.Merge, () => Choose(ImportMode.Merge)),
                Choice("Alles ersetzen", "Alle aktuellen Lernsets, der Fortschritt und die Einstellungen werden durch das Backup ersetzt.",
                    preview.ReplaceDetail, true, chosen == ImportMode.Replace, () => Choose(ImportMode.Replace))));
        }
        model.Ask(new PromptRequest("Backup importieren", "",
        [
            new PromptButton("Abbrechen", IsCancel: true),
            new PromptButton(destructive ? "Alles ersetzen" : "Importieren", () => Perform(model, window, preview, chosen), IsDefault: true, IsDestructive: destructive),
        ])
        {
            Content = content,
            Width = 540,
            KeyHandler = e =>
            {
                if (preview.LibraryIsEmpty || e.KeyModifiers != KeyModifiers.None) return false;
                var next = e.Key switch
                {
                    Key.Up => ImportMode.Merge,
                    Key.Down => ImportMode.Replace,
                    _ => (ImportMode?)null,
                };
                if (next is not { } m) return false;
                if (m != chosen) Show(model, window, preview, m);
                return true;
            },
        });
    }

    /// <summary>The file's name and "3 Lernsets · 120 Begriffe · vom 12.10.2026" beside a document symbol.</summary>
    static Control FileInfo(AppModel model, BackupImportPreview preview)
    {
        var p = WsTheme.P;
        var icon = new Border
        {
            Width = 40,
            Height = 40,
            CornerRadius = new CornerRadius(10),
            Background = WsTheme.B(p.AccentSoft),
            Child = new Border { Child = Icons.Icon(IconName.Download, 20, p.AccentText, 2), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        var name = Ui.Text(preview.FileName, 15, FontWeight.SemiBold);
        name.TextTrimming = TextTrimming.CharacterEllipsis;
        name.MaxLines = 1;
        ToolTip.SetTip(name, preview.FileName);
        var text = Ui.V(2, name, Ui.Text(preview.Meta(model.Store.TimeZone), 13.5, color: p.TextSecondary));
        text.VerticalAlignment = VerticalAlignment.Center;
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 12 };
        row.Children.Add(icon);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        AutomationProperties.SetName(row, $"{preview.FileName}, {preview.Meta(model.Store.TimeZone)}");
        return row;
    }

    /// <summary>One radio choice: a round indicator, title, explanation and what it would do (Mac: the radio group).</summary>
    static Control Choice(string title, string text, string detail, bool danger, bool selected, Action choose)
    {
        var p = WsTheme.P;
        var ring = new Border
        {
            Width = 18,
            Height = 18,
            CornerRadius = new CornerRadius(9),
            BorderThickness = new Thickness(selected ? 5 : 1.5),
            BorderBrush = WsTheme.B(selected ? p.Accent : p.TextTertiary),
            Background = WsTheme.B(selected ? p.OnAccent : Colors.Transparent),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 0, 0),
        };
        var body = Ui.V(2, Ui.Text(title, 14.5, FontWeight.SemiBold),
            Ui.Text(text, 13.5, color: p.TextSecondary, wrap: TextWrapping.Wrap),
            Ui.Text(detail, 13, FontWeight.Medium, danger ? p.Failure.Text : p.AccentText, TextWrapping.Wrap));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 12 };
        row.Children.Add(ring);
        Grid.SetColumn(body, 1);
        row.Children.Add(body);
        var b = Ui.Clickable(row, choose, $"{title}: {text} {detail}", 14, selected ? p.AccentSoft : null, padding: new Thickness(12, 10));
        AutomationProperties.SetItemStatus(b, selected ? "ausgewählt" : "nicht ausgewählt");
        return b;
    }

    /// <summary>Imports a previewed backup and reports the result (Mac: performBackupImport).</summary>
    static void Perform(AppModel model, MainView window, BackupImportPreview preview, ImportMode mode)
    {
        var theme = model.Store.GetSettings().Theme;
        ImportSummary result;
        try
        {
            result = model.Store.ImportAll(preview.Payload, mode);
            model.Store.Save();
        }
        catch (LibraryStoreError e)
        {
            model.ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 6000));
            return;
        }
        catch (Exception)
        {
            model.ShowToast(new ToastMessage("Das Backup konnte nicht importiert werden.", ToastTone.Danger, DurationMs: 6000));
            return;
        }
        // A restored backup can bring another appearance.
        if (model.Store.GetSettings().Theme != theme && window is { } main) main.Rebuild();
        model.ShowToast(new ToastMessage(BackupImportPreview.ResultMessage(result, mode), ToastTone.Success, DurationMs: 5000));
        if (model.Route is not Route.Study) model.ShowOverview();
    }
}
