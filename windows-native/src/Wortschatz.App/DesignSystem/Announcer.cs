using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Threading;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// Screen reader announcements (Mac: Announcer.swift with VoiceOver announcements), e.g. for the flows' Announce effect.
/// Windows: two invisible live regions in the main window (UI Automation LiveRegionChanged, which Narrator and NVDA
/// read when the text changes): "polite" waits for current speech, "assertive" interrupts it (wrong answers, errors).
/// Without a screen reader nothing happens.
/// </summary>
public static class Announcer
{
    static TextBlock? _polite, _assertive;
    static bool _flip;

    /// <summary>The live regions; the main window puts this into its layout once.</summary>
    public static Control CreateHost()
    {
        _polite = Region(AutomationLiveSetting.Polite);
        _assertive = Region(AutomationLiveSetting.Assertive);
        var host = new StackPanel { Width = 1, Height = 1, Opacity = 0, IsHitTestVisible = false, ClipToBounds = true };
        host.Children.Add(_polite);
        host.Children.Add(_assertive);
        return host;
    }

    static TextBlock Region(AutomationLiveSetting setting)
    {
        var block = new TextBlock { FontSize = 1 };
        AutomationProperties.SetLiveSetting(block, setting);
        return block;
    }

    /// <summary>Speaks <paramref name="text"/> with a running screen reader; <paramref name="important"/> interrupts.</summary>
    public static void Announce(string text, bool important = false)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        Dispatcher.UIThread.Post(() =>
        {
            if ((important ? _assertive : _polite) is not { } region) return;
            // The same text twice must be announced twice: alternate an invisible suffix so the text always changes.
            _flip = !_flip;
            var message = _flip ? text : text + "​";
            region.Text = message;
            AutomationProperties.SetName(region, message);
        });
    }
}
