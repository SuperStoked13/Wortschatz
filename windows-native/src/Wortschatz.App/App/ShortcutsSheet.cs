using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Wortschatz.App.DesignSystem;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App;

/// <summary>
/// "Tastenkürzel" (F1 or Ctrl+/): every command with its keys, grouped like the Mac's menu bar (AppCommands.swift:
/// Ablage, Bearbeiten, Lernset, Lernen, Darstellung), where the Mac lists them. Windows has no menu bar, so this sheet
/// is where they can be looked up.
/// </summary>
public static class ShortcutsSheet
{
    /// <summary>
    /// The groups with their commands and keys (Ctrl for ⌘, Alt for ⌥, like the rest of the app); Right: in the right
    /// column. Computed, so the names follow a change of the language.
    /// </summary>
    public static (string Group, bool Right, (string Command, string Keys)[] Items)[] Groups =>
    [
        (L("Ablage"), false, [
            (L("Neues Lernset"), "Ctrl+N"),
            (L("Liste importieren …"), "Ctrl+O"),
            (L("Einstellungen"), "Ctrl+,"),
        ]),
        (L("Bearbeiten"), false, [
            (L("Widerrufen: Lernset löschen"), "Ctrl+Z"),
            (L("Wiederholen"), "Ctrl+Y"),
        ]),
        (L("Lernset"), false, [
            (L("Lernen / Weiterlernen"), "Ctrl+L"),
            (L("Schreiben"), "Ctrl+Shift+L"),
            (L("Karteikarten"), "Ctrl+Alt+L"),
            (L("Prüfung"), "Ctrl+Alt+Shift+L"),
            (L("Bearbeiten"), "Ctrl+E"),
            (L("Löschen"), "Ctrl+Entf"),
        ]),
        (L("Lernen, Schreiben, Karteikarten"), true, [
            (L("Antworten / Weiter"), "Enter"),
            (L("Ich hatte recht"), "Ctrl+Enter"),
            (L("Weiss ich nicht"), "Alt+Enter"),
            (L("Antwort wählen"), "1 – 4"),
            (L("Optionen …"), "Ctrl+K"),
            (L("Vorlesen"), "Ctrl+R"),
            (L("Markieren"), "Ctrl+D"),
            (L("Begriff bearbeiten"), "Ctrl+E"),
            (L("Neu starten"), "Ctrl+Shift+R"),
            (L("Beenden"), "Esc"),
        ]),
        (L("Prüfung"), true, [
            (L("Abgeben"), "Ctrl+Enter"),
            (L("Neue Prüfung"), "Ctrl+Shift+R"),
        ]),
        // The Mac's menu «Darstellung» (View): a key of its own – in the settings «Darstellung» is the appearance.
        (Ui.Meaning("Darstellung", L("Darstellung (Menü)")), false, [
            (L("Seitenleiste ein/aus"), "Ctrl+Alt+S"),
            (L("Vollbild"), "F11"),
            (L("Tastenkürzel"), "F1"),
        ]),
    ];

    public static void Show(AppModel model)
    {
        string title = L("Tastenkürzel");
        if (model.Prompt is { } open && open.Title == title) return;
        model.Ask(new PromptRequest(title, "", [new PromptButton(L("Fertig"), IsDefault: true, IsCancel: true)])
        {
            Width = 620,
            Content = Content(),
        });
    }

    static Control Content()
    {
        var p = WsTheme.P;
        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), ColumnSpacing = 28 };
        var left = Ui.V(18);
        var right = Ui.V(18);
        // Two columns of about equal height: the long study group alone on the right.
        foreach (var (group, inRight, items) in Groups)
        {
            var rows = Ui.V(6);
            foreach (var (command, keys) in items)
            {
                var row = Ui.Row(Ui.Text(command, 13.5, color: p.Text), Keys(keys), 10);
                AutomationProperties.SetName(row, $"{command}: {Spoken(keys)}");
                rows.Children.Add(row);
            }
            var section = Ui.V(8, Ui.Eyebrow(group), rows);
            (inRight ? right : left).Children.Add(section);
        }
        columns.Children.Add(left);
        Grid.SetColumn(right, 1);
        columns.Children.Add(right);
        var scroll = Ui.Scroll(columns);
        scroll.MaxHeight = 520;
        return scroll;
    }

    /// <summary>"Ctrl+Shift+L" as key caps (the German keyboard's «Entf» is «Del» in English).</summary>
    static Control Keys(string keys)
    {
        var row = Ui.H(3);
        string[] parts = keys == "Ctrl+," ? ["Ctrl", ","] : keys.Split('+');
        foreach (var part in parts) row.Children.Add(Ui.KeyCap(part == "Entf" ? L("Entf") : part));
        row.HorizontalAlignment = HorizontalAlignment.Right;
        return row;
    }

    /// <summary>The keys for screen readers ("Strg+Umschalt+L" read as words).</summary>
    public static string Spoken(string keys) => keys
        .Replace("Ctrl", L("Steuerung")).Replace("Shift", L("Umschalt")).Replace("Entf", Ui.Meaning("Entfernen", L("Entfernen (Taste)")))
        .Replace("Esc", "Escape")
        .Replace("+", " ");
}
