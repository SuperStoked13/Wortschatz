using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.VisualTree;
using Wortschatz.Core;

namespace Wortschatz.App.Features;

/// <summary>
/// A screen of the main window (Mac: one SwiftUI screen view). View is built once; Refresh updates it when the
/// library changed elsewhere (another screen, an import). Study screens take keys through HandleKey/HandleText
/// before any control does.
/// </summary>
public abstract class Screen
{
    protected readonly AppModel Model;
    protected readonly MainView Window;
    readonly ContentControl _host = new();

    protected Screen(AppModel model, MainView window)
    {
        Model = model;
        Window = window;
    }

    /// <summary>The library sidebar is shown next to the screen (overview, set, editor, settings).</summary>
    public virtual bool UsesSidebar => true;

    /// <summary>How far the toasts stay above the window's bottom edge: above a study screen's or the editor's bottom bar.</summary>
    public virtual double ToastClearance => UsesSidebar ? 24 : 84;

    /// <summary>The screen's root (its content is replaced by Render).</summary>
    public Control View => _host;

    /// <summary>Builds the screen's content from the current data.</summary>
    protected abstract Control Build();

    /// <summary>
    /// Rebuilds the content (cheap enough for these screens; study screens override to keep their fields). The page
    /// keeps its scroll position (a star toggled far down the list must not jump back to the top).
    /// </summary>
    public virtual void Refresh()
    {
        var offset = MainScroller()?.Offset;
        _host.Content = Build();
        if (offset is not { } o || o.Y <= 0) return;
        if (MainScroller() is not { } scroller) return;
        void Restore(object? sender, EventArgs e)
        {
            scroller.LayoutUpdated -= Restore;
            scroller.Offset = o;
        }
        scroller.LayoutUpdated += Restore;
    }

    /// <summary>The page's own scroller (the first one in the content).</summary>
    ScrollViewer? MainScroller() => _host.Content as ScrollViewer
        ?? (_host.Content as Control)?.GetVisualDescendants().OfType<ScrollViewer>().FirstOrDefault()
        ?? (_host.Content as Panel)?.Children.OfType<ScrollViewer>().FirstOrDefault();

    public virtual void Activate() => Refresh();

    /// <summary>The library changed (a store notification): most screens rebuild.</summary>
    public virtual void LibraryChanged() => Refresh();

    public virtual void Deactivate() { }

    public virtual void WindowActivityChanged(bool active) { }

    public virtual bool HandleKey(KeyEventArgs e, bool isRepeat) => false;

    public virtual bool HandleText(string text) => false;

    /// <summary>Text typed outside a text field as the flows' key: a digit (also Arabic-Indic) or a character.</summary>
    public static KeyInput TextKey(string text) => LearnFlow.DigitValue(text) is { } d ? KeyInput.DigitKey(d) : KeyInput.Character(text);

    public static Screen For(Route route, AppModel model, MainView window) => route switch
    {
        Route.SetDetail d => model.Set(d.SetId) is not null ? new SetDetail.SetDetailScreen(model, window, d.SetId) : new Overview.OverviewScreen(model, window),
        Route.Study s => s.Request.Mode switch
        {
            StudyMode.Learn => new Learn.LearnScreen(model, window, s.Request),
            StudyMode.Write => new Write.WriteScreen(model, window, s.Request),
            StudyMode.Flashcards => new Flashcards.FlashcardsScreen(model, window, s.Request),
            _ => new Exam.ExamScreen(model, window, s.Request),
        },
        Route.Editor e => new Editor.SetEditorScreen(model, window, e.SetId, e.StartWithImport, e.OpenFile),
        Route.Settings => new Settings.SettingsScreen(model, window),
        _ => new Overview.OverviewScreen(model, window),
    };

    /// <summary>
    /// Translates a key event to the flows' KeyInput (Windows keys for the Mac's: Alt+Enter = ⌥↩, Ctrl+Enter = ⌘↩,
    /// Ctrl+Backspace = ⌥⌫). Printable characters come through TextInput (HandleText), not here.
    /// </summary>
    public static KeyInput? Translate(KeyEventArgs e)
    {
        var mods = e.KeyModifiers;
        switch (e.Key)
        {
            case Key.Enter or Key.Return:
                if (mods.HasFlag(KeyModifiers.Alt)) return KeyInput.OptionReturn;
                if (mods.HasFlag(KeyModifiers.Control)) return KeyInput.CommandReturn;
                return KeyInput.Return;
            case Key.Escape: return KeyInput.Escape;
            case Key.Up: return KeyInput.Arrow(Direction.Up);
            case Key.Down: return KeyInput.Arrow(Direction.Down);
            case Key.Left: return KeyInput.Arrow(Direction.Left);
            case Key.Right: return KeyInput.Arrow(Direction.Right);
            case Key.Back: return mods.HasFlag(KeyModifiers.Control) || mods.HasFlag(KeyModifiers.Alt) ? KeyInput.DeleteWordBackward : KeyInput.DeleteBackward;
        }
        // Digits and letters arrive as text (TextInput): that respects the keyboard layout (AZERTY digits need Shift).
        return null;
    }
}
