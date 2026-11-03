using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Chrome;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

using Avalonia.Styling;
using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Avalonia.VisualTree;
using Wortschatz.App.Features;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App;

/// <summary>
/// The main window (Mac: ContentView.swift): the Glas backdrop, an own title bar (no Windows chrome; minimise,
/// maximise and close are drawn here), the floating sidebar with the library and the current screen. Study screens
/// (Lernen, Schreiben, Karteikarten, Prüfung) use the whole width. Keys go to the current screen first (tunnel), so
/// Enter, Alt+Enter, Esc and digits work wherever the focus is.
/// </summary>
public sealed class MainWindow : Window
{
    readonly AppModel _model;
    readonly Grid _body = new();
    readonly Grid _promptLayer = new();
    ToastOverlay? _toasts;
    readonly HashSet<Key> _keysDown = [];
    Screen? _screen;
    Grid _root = new();
    bool _renderQueued;

    public AppModel Model => _model;
    public Screen? CurrentScreen => _screen;

    public MainWindow(AppModel model)
    {
        _model = model;
        Title = "Wortschatz";
        // The window's frames drive the animations (DesignSystem/Motion.cs).
        Motion.Host = this;
        Width = 1280;
        Height = 800;
        MinWidth = 900;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        // No Windows title bar: a resizable border only, our own title bar on top (roles below let Windows treat it as
        // the caption: drag, double-click, Snap layouts on the maximise button).
        WindowDecorations = WindowDecorations.BorderOnly;
        ExtendClientAreaToDecorationsHint = true;
        ExtendClientAreaTitleBarHeightHint = 40;
        Background = Brushes.Transparent;
        try
        {
            Icon = new WindowIcon(Avalonia.Platform.AssetLoader.Open(new Uri("avares://Wortschatz/Assets/app.ico")));
        }
        catch (Exception) { }

        ApplyAppearance();
        BuildChrome();
        _model.RouteChanged += () => ShowRoute();
        _model.Changed += QueueRefresh;
        _model.PromptChanged += RenderPrompt;
        AddHandler(KeyDownEvent, OnKeyDownTunnel, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        AddHandler(KeyUpEvent, (_, e) => _keysDown.Remove(e.Key), Avalonia.Interactivity.RoutingStrategies.Tunnel);
        AddHandler(TextInputEvent, OnTextInputTunnel, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        Activated += (_, _) => _screen?.WindowActivityChanged(true);
        Deactivated += (_, _) => _screen?.WindowActivityChanged(false);
        Closing += (_, _) =>
        {
            _screen?.Deactivate();
            _model.Speech.Stop();
            _model.Flush();
        };
        if (Application.Current is { } app) app.ActualThemeVariantChanged += (_, _) => Rebuild();
        ShowRoute();
    }

    // MARK: Appearance

    /// <summary>The theme setting of the library (Hell, Dunkel, System) picks the palette.</summary>
    void ApplyAppearance()
    {
        var setting = _model.Store.GetSettings().Theme;
        bool dark = setting switch
        {
            ThemeSetting.Dark => true,
            ThemeSetting.Light => false,
            _ => Application.Current?.ActualThemeVariant == ThemeVariant.Dark,
        };
        WsTheme.Use(dark);
        if (Application.Current is { } app)
        {
            var styles = app.Styles;
            for (int i = styles.Count - 1; i >= 1; i--) styles.RemoveAt(i);
            styles.Add(AppStyles.Create());
            app.RequestedThemeVariant = setting switch { ThemeSetting.Dark => ThemeVariant.Dark, ThemeSetting.Light => ThemeVariant.Light, _ => ThemeVariant.Default };
        }
    }

    /// <summary>Rebuilds everything (after a theme change).</summary>
    public void Rebuild()
    {
        ApplyAppearance();
        BuildChrome();
        ShowRoute(rebuild: true);
    }

    // MARK: Chrome

    void BuildChrome()
    {
        _root = new Grid { RowDefinitions = new RowDefinitions("40,*") };
        _root.Children.Add(new Backdrop { [Grid.RowSpanProperty] = 2 });
        var titleBar = TitleBar();
        _root.Children.Add(titleBar);
        Grid.SetRow(_body, 1);
        _body.Children.Clear();
        if (_body.Parent is Panel old) old.Children.Remove(_body);
        _root.Children.Add(_body);
        // Prompts over the window's content, under the toasts (Mac: alerts).
        Grid.SetRowSpan(_promptLayer, 2);
        if (_promptLayer.Parent is Panel oldParent) oldParent.Children.Remove(_promptLayer);
        _root.Children.Add(_promptLayer);
        RenderPrompt();
        // Toasts over everything (Mac: toastOverlay at the window root).
        _toasts?.Detach();
        _toasts = new ToastOverlay(_model);
        Grid.SetRowSpan(_toasts, 2);
        _root.Children.Add(_toasts);
        Content = _root;
        Background = WsTheme.B(WsTheme.P.Backdrop);
    }

    Control TitleBar()
    {
        var p = WsTheme.P;
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Background = Brushes.Transparent, Height = 40 };
        var brand = Ui.H(10, Icons.Icon(IconName.App, 18), Ui.Text("Wortschatz", 13, FontWeight.SemiBold, p.TextSecondary));
        brand.Margin = new Thickness(16, 0, 0, 0);
        brand.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(brand);
        var drag = new Border { Background = Brushes.Transparent };
        WindowDecorationProperties.SetElementRole(drag, WindowDecorationsElementRole.TitleBar);
        Grid.SetColumn(drag, 1);
        grid.Children.Add(drag);
        var caption = new StackPanel { Orientation = Orientation.Horizontal };
        caption.Children.Add(CaptionButton(IconName.Minimize, "Minimieren", () => WindowState = WindowState.Minimized, WindowDecorationsElementRole.MinimizeButton));
        caption.Children.Add(CaptionButton(WindowState == WindowState.Maximized ? IconName.Restore : IconName.Maximize, "Maximieren",
            () => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized, WindowDecorationsElementRole.MaximizeButton));
        caption.Children.Add(CaptionButton(IconName.Close, "Schliessen", Close, WindowDecorationsElementRole.CloseButton, close: true));
        Grid.SetColumn(caption, 2);
        grid.Children.Add(caption);
        foreach (var c in new Control[] { drag, brand })
        {
            c.PointerPressed += (_, e) =>
            {
                if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
                if (e.ClickCount == 2) WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
                else BeginMoveDrag(e);
            };
        }
        return grid;
    }

    Control CaptionButton(IconName icon, string name, Action onClick, WindowDecorationsElementRole role, bool close = false)
    {
        var p = WsTheme.P;
        var b = new WsButton(Icons.Icon(icon, 14, p.TextSecondary, 1.6), ButtonKind.Plain, 40, 0, new Thickness(16, 0)) { Width = 46, Focusable = false };
        b.Chrome.Child!.HorizontalAlignment = HorizontalAlignment.Center;
        b.Chrome.Child!.VerticalAlignment = VerticalAlignment.Center;
        if (close) b.SetColors(Colors.Transparent, Palette.Hex(0xE81123), Palette.Hex(0xC50F1F), Colors.Transparent);
        b.Click += (_, _) => onClick();
        WindowDecorationProperties.SetElementRole(b, role);
        AutomationProperties.SetName(b, name);
        ToolTip.SetTip(b, name);
        return b;
    }

    // MARK: Routing

    void ShowRoute(bool rebuild = false)
    {
        var started = PerfTrace.Start();
        _screen?.Deactivate();
        _screen = Screen.For(_model.Route, _model, this);
        _keysDown.Clear();
        // Toasts stay above a study screen's floating action bar.
        if (_toasts is not null) _toasts.BottomClearance = _screen.UsesSidebar ? 24 : 84;
        RenderBody();
        _screen.Activate();
        // Pages fade in where they stand (Mac: AppModel.revealFirstPage / leaveStudyLayout); the study screens play their
        // own entrance (StudyEntrance). A theme change rebuilds without it.
        if (_screen.UsesSidebar && !rebuild) StudyEntrance.RevealScreen(_screen.View);
        PerfTrace.UntilLayout(this, started, _screen.GetType().Name);
    }

    void RenderBody()
    {
        _body.Children.Clear();
        if (_screen is null) return;
        if (_screen.UsesSidebar)
        {
            var layout = new Grid { ColumnDefinitions = new ColumnDefinitions("262,*"), Margin = new Thickness(10, 0, 10, 10) };
            layout.Children.Add(new LibrarySidebar(_model, this).View);
            var main = _screen.View;
            Grid.SetColumn(main, 1);
            layout.Children.Add(main);
            _body.Children.Add(layout);
        }
        else _body.Children.Add(_screen.View);
    }

    /// <summary>Data changed (store notification): the screen refreshes once per dispatcher turn.</summary>
    void QueueRefresh()
    {
        if (_renderQueued) return;
        _renderQueued = true;
        Dispatcher.UIThread.Post(() =>
        {
            _renderQueued = false;
            var started = PerfTrace.Start();
            _screen?.LibraryChanged();
            if (_screen?.UsesSidebar == true) RenderSidebarOnly();
            if (_screen is not null) PerfTrace.UntilLayout(this, started, $"Aktualisieren {_screen.GetType().Name}");
        });
    }

    void RenderSidebarOnly()
    {
        if (_body.Children.FirstOrDefault() is Grid layout && layout.Children.Count > 0 && layout.ColumnDefinitions.Count == 2)
        {
            layout.Children.RemoveAt(0);
            layout.Children.Insert(0, new LibrarySidebar(_model, this).View);
        }
    }

    // MARK: Prompts

    /// <summary>The model's prompt as a card over a dimmed window (Mac: alert): Enter = default, Esc = cancel.</summary>
    void RenderPrompt()
    {
        _promptLayer.Children.Clear();
        if (_model.Prompt is not { } prompt)
        {
            _promptLayer.IsHitTestVisible = false;
            return;
        }
        _promptLayer.IsHitTestVisible = true;
        var p = WsTheme.P;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right };
        WsButton? focus = null;
        foreach (var b in prompt.Buttons)
        {
            string? hint = b.IsDefault ? "↵" : b.IsCancel ? "Esc" : null;
            WsButton button = b.IsDestructive ? Ui.Danger(b.Label, () => _model.Answer(b), null)
                : b.IsDefault ? Ui.Primary(b.Label, () => _model.Answer(b), hint, height: 40)
                : Ui.Secondary(b.Label, () => _model.Answer(b), keyHint: hint);
            if (b.IsDefault) focus = button;
            buttons.Children.Add(button);
        }
        var body = Ui.V(14, Ui.Text(prompt.Title, 20, FontWeight.Bold, wrap: TextWrapping.Wrap),
            Ui.Text(prompt.Message, 14.5, color: p.TextSecondary, wrap: TextWrapping.Wrap), buttons);
        var card = Ui.Hero(body, new Thickness(26, 22), 24);
        card.Width = 500;
        var cancel = prompt.Buttons.FirstOrDefault(b => b.IsCancel);
        _promptLayer.Children.Add(StudyChrome.Overlay(card, () =>
        {
            if (cancel is not null) _model.Answer(cancel);
        }));
        // A question over the page: opaque, so the text behind never shows through.
        card.Background = WsTheme.B(p.Dark ? Palette.Hex(0x2E3142) : Palette.Hex(0xFBFBFE));
        Effects.FadeIn(_promptLayer, Motion.Soft(0.2));
        if (focus is not null) Dispatcher.UIThread.Post(() => focus.Focus(), DispatcherPriority.Input);
    }

    bool HandlePromptKey(KeyEventArgs e)
    {
        if (_model.Prompt is not { } prompt) return false;
        if (e.Key is Key.Enter or Key.Return && e.KeyModifiers == KeyModifiers.None)
        {
            // Enter on a focused button presses that button; otherwise the default one.
            if (FocusManager?.GetFocusedElement() is WsButton { IsFocused: true } focused && _promptLayer.IsVisualAncestorOf(focused))
                return false;
            if (prompt.Buttons.FirstOrDefault(b => b.IsDefault) is { } d) _model.Answer(d);
            return true;
        }
        if (e.Key == Key.Escape)
        {
            if (prompt.Buttons.FirstOrDefault(b => b.IsCancel) is { } c) _model.Answer(c);
            return true;
        }
        // Tab and arrows move between the buttons; everything else stays away from the screen behind.
        return e.Key is not (Key.Tab or Key.Left or Key.Right or Key.Space);
    }

    // MARK: Keys

    void OnKeyDownTunnel(object? sender, KeyEventArgs e)
    {
        bool isRepeat = !_keysDown.Add(e.Key);
        if (HandlePromptKey(e))
        {
            e.Handled = true;
            return;
        }
        if (_model.Prompt is not null) return;
        if (_screen is null) return;
        if (_screen.HandleKey(e, isRepeat)) e.Handled = true;
        else if (!isRepeat && HandleCommand(e)) e.Handled = true;
    }

    void OnTextInputTunnel(object? sender, TextInputEventArgs e)
    {
        if (_model.Prompt is not null)
        {
            e.Handled = true;
            return;
        }
        if (_screen is null || string.IsNullOrEmpty(e.Text)) return;
        if (_screen.HandleText(e.Text)) e.Handled = true;
    }

    /// <summary>
    /// The menu shortcuts of the Mac app (AppCommands.swift) with Ctrl for ⌘: Ctrl+N Neues Lernset, Ctrl+O Liste
    /// importieren, Ctrl+, Einstellungen; on a set: Ctrl+L Lernen, Ctrl+Shift+L Schreiben, Ctrl+Alt+L Karteikarten,
    /// Ctrl+Alt+Shift+L Prüfung, Ctrl+E Bearbeiten, Ctrl+Entf Löschen. Study screens keep their own keys (they come first).
    /// </summary>
    bool HandleCommand(KeyEventArgs e)
    {
        var mods = e.KeyModifiers;
        if (!mods.HasFlag(KeyModifiers.Control)) return false;
        bool shift = mods.HasFlag(KeyModifiers.Shift), alt = mods.HasFlag(KeyModifiers.Alt);
        bool studying = _model.Route is Route.Study;
        bool editing = _model.Route is Route.Editor;
        switch (e.Key)
        {
            case Key.N when !shift && !alt && !editing:
                _model.OpenEditor();
                return true;
            case Key.O when !shift && !alt && !editing:
                _model.OpenEditor(openFile: true);
                return true;
            case Key.OemComma when !shift && !alt && !editing:
                _model.Navigate(new Route.Settings());
                return true;
        }
        if (studying || editing || _model.CurrentSetId is not { } setId) return false;
        switch (e.Key)
        {
            case Key.L:
                var mode = (shift, alt) switch
                {
                    (false, false) => StudyMode.Learn,
                    (true, false) => StudyMode.Write,
                    (false, true) => StudyMode.Flashcards,
                    _ => StudyMode.Exam,
                };
                _model.Study(setId, mode);
                return true;
            case Key.E when !shift && !alt:
                _model.OpenEditor(setId);
                return true;
            case Key.Delete when !shift && !alt && !TextFieldFocused:
                _model.DeleteSet(setId);
                return true;
        }
        return false;
    }

    /// <summary>Whether a text field has the keyboard focus (then letters belong to it).</summary>
    public bool TextFieldFocused => FocusManager?.GetFocusedElement() is TextBox;
}
