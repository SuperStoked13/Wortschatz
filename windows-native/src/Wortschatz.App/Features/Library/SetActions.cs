using Avalonia.Controls;
using Avalonia.Input;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features;

/// <summary>
/// The actions of a set as a menu (Mac: SetActionsMenu.swift), shared by the sidebar's and the overview cards'
/// context menus (with the study actions) and the set page's "…" menu (restarts first, then "Fortschritt
/// zurücksetzen…"): Lernen, Schreiben, Karteikarten, Prüfung, Bearbeiten, Duplizieren, Als Text exportieren…, Löschen.
/// </summary>
public static class SetActions
{
    /// <summary>Starts over at once without answers, else after asking (the running session ends).</summary>
    static void Restart(AppModel model, string id, StudyMode mode, StudySubset? subset, bool hasAnswers, string title, string message)
    {
        if (!hasAnswers)
        {
            model.Study(id, mode, subset, forceNew: true);
            return;
        }
        model.Ask(PromptRequest.Confirm(title, message, "Neu starten", () => model.Study(id, mode, subset, forceNew: true)));
    }

    public static ContextMenu Menu(AppModel model, MainView window, SetSummary summary, bool includesStudy)
    {
        var menu = new ContextMenu();
        var id = summary.Id;
        bool empty = summary.IsEmpty;
        void Item(string header, IconName icon, Action action, string? gesture = null, bool enabled = true, bool danger = false)
        {
            var item = new MenuItem
            {
                Header = header,
                Icon = Icons.Icon(icon, 15, danger ? WsTheme.P.Failure.Text : WsTheme.P.TextSecondary, 1.9),
                IsEnabled = enabled,
            };
            if (gesture is not null) item.InputGesture = KeyGesture.Parse(gesture);
            if (danger) item.Foreground = WsTheme.B(WsTheme.P.Failure.Text);
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        void Divider()
        {
            if (menu.Items.Count > 0 && menu.Items[^1] is not Separator) menu.Items.Add(new Separator());
        }

        if (includesStudy)
        {
            Item(summary.Learn is not null ? "Weiterlernen" : "Lernen", summary.Learn is not null ? IconName.Play : IconName.Sparkles,
                () => model.Study(id, StudyMode.Learn), "Ctrl+L", !empty);
            Item(summary.Write is not null ? "Schreiben fortsetzen" : "Schreiben", IconName.Keyboard, () => model.Study(id, StudyMode.Write), "Ctrl+Shift+L", !empty);
            Item("Karteikarten", IconName.Cards, () => model.Study(id, StudyMode.Flashcards), "Ctrl+Alt+L", !empty);
            Item("Prüfung", IconName.Exam, () => model.Study(id, StudyMode.Exam), "Ctrl+Alt+Shift+L", !empty);
            Divider();
            Item("Bearbeiten", IconName.Pencil, () => model.OpenEditor(id), "Ctrl+E");
        }
        else
        {
            if (summary.Learn is { } learn)
            {
                var subset = learn.Subset.Kind is StudySubsetKind.Starred or StudySubsetKind.Learning or StudySubsetKind.Missed ? learn.Subset : null;
                Item("Lernen neu starten", IconName.RotateCcw, () => Restart(model, id, StudyMode.Learn, subset, learn.HasAnswers,
                    "Neu starten?", LearnFlow.RestartSessionMessage(learn.Subset)));
            }
            if (summary.Write is { } write)
                Item("Schreiben neu starten", IconName.RotateCcw, () => Restart(model, id, StudyMode.Write, null, write.HasAnswers,
                    "Neue Runde starten?", $"Deine gespeicherte Runde ({write.Detail}) endet. Dein Lernfortschritt bleibt erhalten."));
            if (model.Preferences.Deck(id) is { IsResumable: true } deck)
                Item("Karteikarten neu starten", IconName.RotateCcw, () => Restart(model, id, StudyMode.Flashcards, deck.StarredOnly ? StudySubset.Starred : null,
                    deck.HasProgress, "Karteikarten neu starten?", FlashcardCopy.RestartMessage(deck)));
            if (summary.Starred > 0) Item($"Nur markierte schreiben ({summary.Starred})", IconName.Star, () => model.Study(id, StudyMode.Write, StudySubset.Starred));
            Divider();
        }
        Item("Duplizieren", IconName.Copy, () => model.DuplicateSet(id));
        Item("Als Text exportieren …", IconName.Upload, () => _ = Settings.SettingsScreen.ExportText(model, window, summary.Set), enabled: !empty);
        if (!includesStudy)
        {
            Divider();
            Item("Fortschritt zurücksetzen …", IconName.RotateCcw, () => model.ConfirmResetProgress(id), enabled: summary.CanReset);
        }
        Divider();
        Item("Löschen", IconName.Trash, () => model.DeleteSet(id), "Ctrl+Delete", danger: true);
        return menu;
    }
}
