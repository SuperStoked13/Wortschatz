using Avalonia.Controls;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Services;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Settings;

// Einstellungen › Daten › Updates (AppUpdater; Mac: SettingsUpdateSection.swift): «Automatisch aktualisieren», «Jetzt
// suchen» with the last look, and a downloaded version with «Jetzt neu starten». Only in the Windows app of the
// download page; a Debug build shows it switched off, like the Mac.
public sealed partial class SettingsScreen
{
    Control? UpdateSection()
    {
        var updater = AppUpdater.Shared;
        if (!updater.ShowsSettings) return null;
        bool enabled = updater.IsEnabled || !AppUpdater.IsCompiledIn;
        var automatic = Switch(updater.UpdatesAutomatically, on => updater.UpdatesAutomatically = on, enabled);
        var check = Ui.Secondary(L("Jetzt suchen"), () => _ = CheckForUpdates(), IconName.Download);
        check.IsEnabled = enabled && !updater.IsChecking;
        var rows = new List<Control>
        {
            Row(L("Automatisch aktualisieren"), automatic, L("Lädt neue Versionen im Hintergrund und installiert sie, wenn du Wortschatz beendest.")),
            Row(L("Nach Updates suchen"), check, LastCheckText(updater, enabled)),
        };
        if (updater.Ready is { } ready)
            rows.Add(Row(L($"Version {ready.Version} ist bereit"), Ui.Secondary(L("Jetzt neu starten"), RestartToUpdate, IconName.Repeat),
                L("Wird installiert, wenn du Wortschatz beendest.")));
        string? footer = updater.IsReadOnly ? ReadOnlyText
            : updater.GaveUp is { } version ? L($"Version {version} liess sich nicht installieren. Lade sie von der Downloadseite.") : null;
        return Section(L("Updates"), [.. rows], footer);
    }

    static string ReadOnlyText => L("Wortschatz liegt in einem Ordner, in dem es sich nicht selbst ersetzen kann. Neue Versionen gibt es auf der Downloadseite.");

    static string LastCheckText(AppUpdater updater, bool enabled)
    {
        if (!enabled) return L("Nur in der App von der Downloadseite.");
        if (updater.IsChecking) return L("Sucht nach Updates …");
        if (updater.LastCheck is not { } last) return L("Noch nie gesucht.");
        return L($"Zuletzt gesucht: {TimeUtil.RelativeTime(last, TimeUtil.NowMs())}");
    }

    /// <summary>«Jetzt suchen» (Mac: Sparkle's window): up to date, ready to install, or it did not work.</summary>
    async Task CheckForUpdates()
    {
        var result = await AppUpdater.Shared.CheckAsync(manual: true);
        switch (result)
        {
            case AppUpdater.CheckResult.UpToDate:
                Model.Ask(new PromptRequest(L("Wortschatz ist aktuell"), L($"Version {UpdateFeed.Display(AppUpdater.Current)} ist die neueste."),
                    [new PromptButton(L("OK"), IsDefault: true, IsCancel: true)]));
                break;
            case AppUpdater.CheckResult.Ready when AppUpdater.Shared.Ready is { } ready:
                var changes = AppUpdater.Shared.ReadyChanges(english: CoreText.Table is not null);
                Model.Ask(new PromptRequest(L($"Version {ready.Version} ist bereit"), L("Wird installiert, wenn du Wortschatz beendest."),
                    [new PromptButton(L("Jetzt neu starten"), RestartToUpdate, IsDefault: true), new PromptButton(L("Später"), IsCancel: true)])
                {
                    Content = changes.Count > 0 ? UpdateNoticeCard.ChangeList(changes) : null,
                });
                break;
            case AppUpdater.CheckResult.ReadOnly:
                Model.Ask(new PromptRequest(L("Update nicht möglich"), ReadOnlyText, [new PromptButton(L("OK"), IsDefault: true, IsCancel: true)]));
                break;
            case AppUpdater.CheckResult.GaveUp when AppUpdater.Shared.GaveUp is { } version:
                Model.Ask(new PromptRequest(L("Update nicht möglich"), L($"Version {version} liess sich nicht installieren. Lade sie von der Downloadseite."),
                    [new PromptButton(L("OK"), IsDefault: true, IsCancel: true)]));
                break;
            case AppUpdater.CheckResult.Failed:
                Model.Ask(new PromptRequest(L("Die Suche nach Updates hat nicht geklappt"), L("Prüfe die Internetverbindung und versuche es später nochmals."),
                    [new PromptButton(L("OK"), IsDefault: true, IsCancel: true)]));
                break;
        }
    }

    void RestartToUpdate()
    {
        if (TopLevel.GetTopLevel(Window) is Avalonia.Controls.Window host) AppUpdater.Shared.RestartToUpdate(host);
    }

    void UpdaterChanged()
    {
        if (Tab == 4) Refresh();
    }
}
