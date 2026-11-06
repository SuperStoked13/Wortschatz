using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Chrome;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features;
using Wortschatz.App.Services;

namespace Wortschatz.App;

/// <summary>
/// The Windows window around <see cref="MainView"/> (the app itself, shared with the Android app): an own title bar
/// (no Windows chrome; minimise, maximise and close are drawn here), the window's size and place from the last session,
/// F11 full screen, and the questions before closing. Everything else lives in MainView, so a new feature never needs
/// this file.
/// </summary>
public sealed class MainWindow : Window
{
    readonly AppModel _model;
    readonly MainView _view;

    public AppModel Model => _model;
    public MainView View => _view;
    public Screen? CurrentScreen => _view.CurrentScreen;

    public MainWindow(AppModel model)
    {
        _model = model;
        Title = "Wortschatz";
        // The window's frames drive the animations (DesignSystem/Motion.cs).
        Motion.Host = this;
        Width = 1240;
        Height = 800;
        MinWidth = 980;
        MinHeight = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        RestoreFrame();
        WatchFrame();
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

        _view = new MainView(model, TitleBar);
        _view.ChromeRebuilt += () => Background = WsTheme.B(WsTheme.P.Backdrop);
        Background = WsTheme.B(WsTheme.P.Backdrop);
        Content = _view;
        Activated += (_, _) => _view.HostActivityChanged(true);
        Deactivated += (_, _) => _view.HostActivityChanged(false);
        Closing += (_, e) =>
        {
            if (!_view.CanQuit(Close))
            {
                e.Cancel = true;
                return;
            }
            Shutdown();
        };
    }

    /// <summary>Rebuilds everything (after a theme change).</summary>
    public void Rebuild() => _view.Rebuild();

    /// <summary>Ctrl+Alt+S: hides or shows the sidebar.</summary>
    public void ToggleSidebar() => _view.ToggleSidebar();

    void Shutdown()
    {
        SaveFrame();
        _view.Shutdown();
    }

    // MARK: Window frame

    /// <summary>The size and place of the last session, if it still fits on a screen (Mac: macOS restores the frame).</summary>
    void RestoreFrame()
    {
        if (_model.Preferences.MainWindowFrame is not { } frame) return;
        Width = Math.Max(MinWidth, frame.Width);
        Height = Math.Max(MinHeight, frame.Height);
        var place = new PixelPoint(frame.X, frame.Y);
        // Only where a screen still is (a monitor may have been unplugged since).
        bool visible = Screens.All.Count == 0 || Screens.All.Any(sc => sc.WorkingArea.Contains(place + new PixelPoint(40, 20)));
        if (visible)
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Position = place;
        }
        if (frame.Maximized) WindowState = WindowState.Maximized;
        else if (!visible) WindowStartupLocation = WindowStartupLocation.CenterScreen;
    }

    void WatchFrame() => PositionChanged += (_, _) => NoteNormalFrame();

    /// <summary>Remembers the window's frame in preferences.json (the normal frame also while maximised).</summary>
    void SaveFrame()
    {
        bool maximized = WindowState is WindowState.Maximized or WindowState.FullScreen;
        if (WindowState == WindowState.Minimized)
        {
            // Closed from the taskbar: the last frame it had on screen.
            if (_normalFrame is { } last) _model.Preferences.MainWindowFrame = last;
            return;
        }
        var normal = maximized && _normalFrame is { } n ? n : new WindowFrame(Position.X, Position.Y, ClientSize.Width, ClientSize.Height, false);
        _model.Preferences.MainWindowFrame = normal with { Maximized = maximized };
    }

    WindowFrame? _normalFrame;

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        // The last normal frame, to restore under a maximised window next time.
        if (change.Property == ClientSizeProperty || change.Property == WindowStateProperty) NoteNormalFrame();
    }

    void NoteNormalFrame()
    {
        if (WindowState == WindowState.Normal && IsVisible && ClientSize.Width > 0)
            _normalFrame = new WindowFrame(Position.X, Position.Y, ClientSize.Width, ClientSize.Height, false);
    }

    // MARK: Title bar

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

    /// <summary>F11: full screen and back (Mac: Darstellung › Vollbildmodus).</summary>
    public void ToggleFullScreen()
    {
        _stateBeforeFullScreen = WindowState == WindowState.FullScreen ? _stateBeforeFullScreen : WindowState;
        WindowState = WindowState == WindowState.FullScreen
            ? (_stateBeforeFullScreen == WindowState.Maximized ? WindowState.Maximized : WindowState.Normal)
            : WindowState.FullScreen;
    }

    WindowState _stateBeforeFullScreen = WindowState.Normal;
}
