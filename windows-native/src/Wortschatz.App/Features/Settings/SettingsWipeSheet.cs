using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Settings;

/// <summary>
/// "Alle Daten löschen …" with two confirmations (Mac: SettingsWipeSheet.swift, <c>wipeEverything</c> in settings.js):
/// first what will be gone, with a backup offer; then "Wirklich alles löschen?". Enter moves on in the first step and
/// cancels in the second, so two presses of Enter never delete anything. Esc cancels in both.
/// </summary>
public static class SettingsWipeSheet
{
    /// <summary>The first step: what will be gone, and "Tipp: Sichere vorher ein Backup." while there are sets.</summary>
    public static void Show(AppModel model, MainView window)
    {
        var sets = model.Sets;
        var shown = DateTime.UtcNow;
        model.Ask(new PromptRequest("Alle Daten löschen?", WipeMessage(sets),
        [
            new PromptButton("Abbrechen", IsCancel: true),
            new PromptButton("Weiter", () => Confirm(model, window), IsDefault: true, IsDestructive: true),
        ])
        {
            Content = sets.Count > 0 ? BackupTip(model, window) : null,
            Width = 520,
            // Ignore a held Enter (the key that pressed "Alle Daten löschen …"): the next step must be reached on purpose.
            KeyHandler = e => e.Key is Key.Enter or Key.Return && DateTime.UtcNow - shown < TimeSpan.FromMilliseconds(450),
        });
    }

    /// <summary>The second step: "Endgültig löschen" or "Abbrechen" (the default, also on Enter).</summary>
    /// <summary>"diesem Computer" / "diesem Gerät" (phone).</summary>
    static string Device => AppDevice.IsPhone ? "diesem Gerät" : "diesem Computer";

    static void Confirm(AppModel model, MainView window)
    {
        model.Ask(new PromptRequest("Wirklich alles löschen?",
            "Das kann nicht rückgängig gemacht werden. Ohne Backup sind deine Lernsets danach endgültig weg.",
            [
                new PromptButton("Endgültig löschen", () => Wipe(model, window), IsDestructive: true),
                new PromptButton("Abbrechen", IsDefault: true, IsCancel: true),
            ])
        { Width = 520 });
        Announcer.Announce("Wirklich alles löschen? Das kann nicht rückgängig gemacht werden.");
    }

    /// <summary>The first question (Mac: SettingsCopy.wipeMessage, "von diesem Computer" for "von diesem Mac").</summary>
    public static string WipeMessage(IReadOnlyList<VocabSet> sets)
    {
        var terms = Labels.Plural(sets.Sum(s => s.Cards.Count), "Begriff", "Begriffen");
        return sets.Count switch
        {
            0 => $"Deine Statistik und deine Einstellungen werden von {Device} gelöscht.",
            1 => $"Dein Lernset mit {terms}, dein Lernfortschritt, deine Statistik und deine Einstellungen werden von {Device} gelöscht.",
            _ => $"Alle {sets.Count} Lernsets mit {terms}, dein Lernfortschritt, deine Statistik und deine Einstellungen werden von {Device} gelöscht.",
        };
    }

    static Control BackupTip(AppModel model, MainView window)
    {
        var p = WsTheme.P;
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 10 };
        var bulb = Icons.Icon(IconName.Lightbulb, 17, p.Warning.Fill, 2);
        bulb.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(bulb);
        var text = Ui.Text("Tipp: Sichere vorher ein Backup.", 14, color: p.Text, wrap: TextWrapping.Wrap);
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        var export = Ui.Secondary("Backup exportieren …", () => _ = SettingsScreen.ExportBackup(model, window), height: 34);
        Grid.SetColumn(export, 2);
        row.Children.Add(export);
        return new Border { Child = row, Padding = new Thickness(12, 8), CornerRadius = new CornerRadius(10), Background = WsTheme.B(p.Warning.Soft) };
    }

    /// <summary>Clears the library, the settings and the chosen voices, saves at once, removes the older copies of the
    /// library file and confirms.</summary>
    static void Wipe(AppModel model, MainView window)
    {
        var theme = model.Store.GetSettings().Theme;
        try
        {
            model.Store.ClearAll();
        }
        catch (LibraryStoreError)
        {
            model.ShowToast(new ToastMessage("Die Daten konnten nicht gelöscht werden.", ToastTone.Danger, DurationMs: 6000));
            return;
        }
        foreach (var lang in model.Speech.PreferredVoiceIds.Keys.ToList()) model.Speech.SetPreferredVoice(lang, null);
        try { model.Store.Save(); }
        catch (LibraryStoreError e)
        {
            model.ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 6000));
        }
        // "von diesem Computer gelöscht": the rotating backups and a set-aside damaged copy go too, so no recovery can
        // bring the deleted sets back.
        model.Store.Backend.DiscardBackups();
        if (model.Store.GetSettings().Theme != theme) window.Rebuild();
        model.ShowToast(new ToastMessage("Alle Daten wurden gelöscht.", ToastTone.Success));
    }
}
