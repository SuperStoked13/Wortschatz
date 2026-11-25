using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Controls.Primitives;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

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
        model.Ask(PromptRequest.Confirm(title, message, L("Neu starten"), () => model.Study(id, mode, subset, forceNew: true)));
    }

    /// <summary>
    /// The set's <see cref="Menu"/> on a right-click, a long press or the menu key over <paramref name="target"/>, made
    /// only when it is asked for: the sidebar and the overview built a menu with icons for every set at every rebuild.
    /// It opens where an attached ContextMenu opens (at the pointer; from the keyboard below the control).
    /// </summary>
    public static void AttachMenu(Control target, AppModel model, MainView window, SetSummary summary, bool includesStudy)
    {
        target.ContextRequested += (_, e) =>
        {
            if (e.Handled) return;
            var menu = Menu(model, window, summary, includesStudy);
            if (!e.TryGetPosition(null, out Avalonia.Point _)) menu.Placement = PlacementMode.Bottom;
            menu.PlacementTarget = e.Source as Control ?? target;
            menu.Open(target);
            e.Handled = true;
        };
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
            if (gesture is not null && AppDevice.ShowsKeyHints) item.InputGesture = KeyGesture.Parse(gesture);
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
            Item(summary.Learn is not null ? L("Weiterlernen") : L("Lernen"), summary.Learn is not null ? IconName.Play : IconName.Sparkles,
                () => model.Study(id, StudyMode.Learn), "Ctrl+L", !empty);
            Item(summary.Write is not null ? L("Schreiben fortsetzen") : L("Schreiben"), IconName.Keyboard, () => model.Study(id, StudyMode.Write), "Ctrl+Shift+L", !empty);
            Item(L("Karteikarten"), IconName.Cards, () => model.Study(id, StudyMode.Flashcards), "Ctrl+Alt+L", !empty);
            Item(L("Prüfung"), IconName.Exam, () => model.Study(id, StudyMode.Exam), "Ctrl+Alt+Shift+L", !empty);
            Divider();
            Item(L("Bearbeiten"), IconName.Pencil, () => model.OpenEditor(id), "Ctrl+E");
        }
        else
        {
            if (summary.Learn is { } learn)
            {
                var subset = learn.Subset.Kind is StudySubsetKind.Starred or StudySubsetKind.Learning or StudySubsetKind.Missed ? learn.Subset : null;
                Item(L("Lernen neu starten"), IconName.RotateCcw, () => Restart(model, id, StudyMode.Learn, subset, learn.HasAnswers,
                    L("Neu starten?"), LearnFlow.RestartSessionMessage(learn.Subset)));
            }
            if (summary.Write is { } write)
                Item(L("Schreiben neu starten"), IconName.RotateCcw, () => Restart(model, id, StudyMode.Write, null, write.HasAnswers,
                    L("Neue Runde starten?"), L($"Deine gespeicherte Runde ({write.Detail}) endet. Dein Lernfortschritt bleibt erhalten.")));
            if (model.Preferences.Deck(id) is { IsResumable: true } deck)
                Item(L("Karteikarten neu starten"), IconName.RotateCcw, () => Restart(model, id, StudyMode.Flashcards, deck.StarredOnly ? StudySubset.Starred : null,
                    deck.HasProgress, L("Karteikarten neu starten?"), FlashcardCopy.RestartMessage(deck)));
            if (summary.Starred > 0) Item(L($"Nur markierte schreiben ({summary.Starred})"), IconName.Star, () => model.Study(id, StudyMode.Write, StudySubset.Starred));
            Divider();
        }
        Item(L("Duplizieren"), IconName.Copy, () => model.DuplicateSet(id));
        Item(L("Als Text exportieren …"), IconName.Upload, () => _ = Settings.SettingsScreen.ExportText(model, window, summary.Set), enabled: !empty);
        if (!includesStudy)
        {
            Divider();
            Item(L("Fortschritt zurücksetzen …"), IconName.RotateCcw, () => model.ConfirmResetProgress(id), enabled: summary.CanReset);
        }
        Divider();
        Item(L("Löschen"), IconName.Trash, () => model.DeleteSet(id), "Ctrl+Delete", danger: true);
        return menu;
    }
}
