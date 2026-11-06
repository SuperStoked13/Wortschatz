using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;

namespace Wortschatz.App;

/// <summary>
/// "Tastenkürzel" (F1 or Ctrl+/): every command with its keys, grouped like the Mac's menu bar (AppCommands.swift:
/// Ablage, Bearbeiten, Lernset, Lernen, Darstellung), where the Mac lists them. Windows has no menu bar, so this sheet
/// is where they can be looked up.
/// </summary>
public static class ShortcutsSheet
{
    /// <summary>The groups with their commands and keys (Ctrl for ⌘, Alt for ⌥, like the rest of the app).</summary>
    public static readonly (string Group, (string Command, string Keys)[] Items)[] Groups =
    [
        ("Ablage", [
            ("Neues Lernset", "Ctrl+N"),
            ("Liste importieren …", "Ctrl+O"),
            ("Einstellungen", "Ctrl+,"),
        ]),
        ("Bearbeiten", [
            ("Widerrufen: Lernset löschen", "Ctrl+Z"),
            ("Wiederholen", "Ctrl+Y"),
        ]),
        ("Lernset", [
            ("Lernen / Weiterlernen", "Ctrl+L"),
            ("Schreiben", "Ctrl+Shift+L"),
            ("Karteikarten", "Ctrl+Alt+L"),
            ("Prüfung", "Ctrl+Alt+Shift+L"),
            ("Bearbeiten", "Ctrl+E"),
            ("Löschen", "Ctrl+Entf"),
        ]),
        ("Lernen, Schreiben, Karteikarten", [
            ("Antworten / Weiter", "Enter"),
            ("Ich hatte recht", "Ctrl+Enter"),
            ("Weiss ich nicht", "Alt+Enter"),
            ("Antwort wählen", "1 – 4"),
            ("Optionen …", "Ctrl+K"),
            ("Vorlesen", "Ctrl+R"),
            ("Markieren", "Ctrl+D"),
            ("Begriff bearbeiten", "Ctrl+E"),
            ("Neu starten", "Ctrl+Shift+R"),
            ("Beenden", "Esc"),
        ]),
        ("Prüfung", [
            ("Abgeben", "Ctrl+Enter"),
            ("Neue Prüfung", "Ctrl+Shift+R"),
        ]),
        ("Darstellung", [
            ("Seitenleiste ein/aus", "Ctrl+Alt+S"),
            ("Vollbild", "F11"),
            ("Tastenkürzel", "F1"),
        ]),
    ];

    public static void Show(AppModel model)
    {
        if (model.Prompt is { Title: "Tastenkürzel" }) return;
        model.Ask(new PromptRequest("Tastenkürzel", "", [new PromptButton("Fertig", IsDefault: true, IsCancel: true)])
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
        foreach (var (group, items) in Groups)
        {
            var rows = Ui.V(6);
            foreach (var (command, keys) in items)
            {
                var row = Ui.Row(Ui.Text(command, 13.5, color: p.Text), Keys(keys), 10);
                AutomationProperties.SetName(row, $"{command}: {Spoken(keys)}");
                rows.Children.Add(row);
            }
            var section = Ui.V(8, Ui.Eyebrow(group), rows);
            (group.StartsWith("Lernen,", StringComparison.Ordinal) || group == "Prüfung" ? right : left).Children.Add(section);
        }
        columns.Children.Add(left);
        Grid.SetColumn(right, 1);
        columns.Children.Add(right);
        var scroll = Ui.Scroll(columns);
        scroll.MaxHeight = 520;
        return scroll;
    }

    /// <summary>"Ctrl+Shift+L" as key caps.</summary>
    static Control Keys(string keys)
    {
        var row = Ui.H(3);
        string[] parts = keys == "Ctrl+," ? ["Ctrl", ","] : keys.Split('+');
        foreach (var part in parts) row.Children.Add(Ui.KeyCap(part));
        row.HorizontalAlignment = HorizontalAlignment.Right;
        return row;
    }

    /// <summary>The keys for screen readers ("Strg+Umschalt+L" read as words).</summary>
    public static string Spoken(string keys) => keys
        .Replace("Ctrl", "Steuerung").Replace("Shift", "Umschalt").Replace("Entf", "Entfernen").Replace("Esc", "Escape")
        .Replace("+", " ");
}
