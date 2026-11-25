using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features;

/// <summary>
/// «Aktualisiert auf 1.8» at the foot of the sidebar, above the streak, after Wortschatz updated itself
/// (<see cref="Services.AppUpdater.Notice"/>; Mac: UpdateNoticeCard.swift): the first change, «+2 weitere», all of them in
/// a sheet on a click. ✕ closes it for good; otherwise it goes after a week (UpdateNoticeStore).
/// </summary>
public static class UpdateNoticeCard
{
    public static Control Build(AppModel model, UpdateNotice notice, Action onClose)
    {
        var p = WsTheme.P;
        var changes = notice.Changes(english: CoreText.Table is not null);
        var icon = Icons.Icon(IconName.Sparkles, 15, p.Accent, 2);
        icon.Width = 22;
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);

        var title = L($"Aktualisiert auf {notice.Version}");
        var text = Ui.V(2, Ui.Text(title, 13, FontWeight.SemiBold));
        if (changes.Count > 0)
        {
            var first = Ui.Text(changes[0], 11.5, color: p.TextSecondary, wrap: TextWrapping.Wrap);
            first.MaxLines = 2;
            first.TextTrimming = TextTrimming.CharacterEllipsis;
            text.Children.Add(first);
        }
        if (changes.Count > 1) text.Children.Add(Ui.Text(L($"+{changes.Count - 1} weitere"), 11.5, FontWeight.Medium, p.AccentText));

        // A grid, not a row: the text gets the width that is left, so the first change wraps onto a second line.
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 6, Margin = new Thickness(10, 7, 4, 7) };
        body.Children.Add(icon);
        Grid.SetColumn(text, 1);
        body.Children.Add(text);
        Control content = body;
        if (changes.Count > 0)
        {
            // The text opens every change (Mac: a popover; here a sheet like the other lists).
            var open = Ui.Clickable(body, () => ShowChanges(model, notice), title, 12);
            ToolTip.SetTip(open, L("Klicken für alle Neuerungen"));
            AutomationProperties.SetHelpText(open, string.Join(", ", changes.Take(1).Append(changes.Count > 1 ? L($"+{changes.Count - 1} weitere") : "").Where(s => s.Length > 0)));
            content = open;
        }

        var close = Ui.IconButton(IconName.X, L("Schliessen"), onClose, 22, ButtonKind.Plain, p.TextTertiary);
        close.VerticalAlignment = VerticalAlignment.Top;
        close.Margin = new Thickness(0, 5, 5, 0);
        AutomationProperties.SetName(close, L("Hinweis schliessen"));

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        grid.Children.Add(content);
        Grid.SetColumn(close, 1);
        grid.Children.Add(close);
        return new Border
        {
            Child = grid,
            CornerRadius = new CornerRadius(12),
            Background = WsTheme.B(Palette.Hex(Ui.Rgb(p.Accent), 0.1)),
        };
    }

    /// <summary>Every change of the update (Mac: UpdateChangesList in the popover).</summary>
    public static void ShowChanges(AppModel model, UpdateNotice notice) =>
        model.Ask(new PromptRequest(L($"Neu in Version {notice.Version}"), "", [new PromptButton(L("OK"), IsDefault: true, IsCancel: true)])
        {
            Content = ChangeList(notice.Changes(english: CoreText.Table is not null)),
        });

    /// <summary>Changes as a bulleted list (scrolls when long).</summary>
    public static Control ChangeList(IReadOnlyList<string> changes)
    {
        var p = WsTheme.P;
        var list = Ui.V(8);
        foreach (var change in changes)
        {
            var bullet = Ui.Text("•", 14, color: p.TextSecondary);
            bullet.VerticalAlignment = VerticalAlignment.Top;
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 8 };
            row.Children.Add(bullet);
            var line = Ui.Text(change, 14, wrap: TextWrapping.Wrap);
            line.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(line, 1);
            row.Children.Add(line);
            list.Children.Add(row);
        }
        var scroll = Ui.Scroll(list);
        scroll.MaxHeight = 420;
        return scroll;
    }
}
