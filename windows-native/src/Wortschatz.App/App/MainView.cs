using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App;

/// <summary>
/// The app's content (Mac: ContentView.swift), the same on every platform: the Glas backdrop, the floating sidebar with
/// the library and the current screen. Study screens (Lernen, Schreiben, Karteikarten, Prüfung) use the whole width.
/// Keys go to the current screen first (tunnel), so Enter, Alt+Enter, Esc and digits work wherever the focus is.
/// <para>
/// Hosts: on Windows <see cref="MainWindow"/> (own title bar, window frame, closing), on Android the activity's single
/// view. Everything a screen needs from its host (title, files, clipboard, focus) goes through
/// this class, so a new screen or feature works on both without platform code.
/// </para>
/// <para>
/// Phone layout (<see cref="AppDevice.IsPhone"/>): no sidebar next to the page; a bar on top with ☰ opens the library
/// as a drawer from the left, and the system's back gesture works like Esc (<see cref="GoBack"/>).
/// </para>
/// </summary>
public sealed class MainView : UserControl
{
    readonly AppModel _model;
    readonly Func<Control>? _titleBar;
    readonly Grid _body = new();
    readonly Grid _promptLayer = new();
    ToastOverlay? _toasts;
    readonly HashSet<Key> _keysDown = [];
    Screen? _screen;
    Grid _root = new();
    bool _renderQueued;
    TopLevel? _top;

    public AppModel Model => _model;
    public Screen? CurrentScreen => _screen;

    /// <summary>The chrome was built anew (theme change): a host takes the new backdrop colour.</summary>
    public event Action? ChromeRebuilt;

    /// <param name="titleBar">The host's own title bar (Windows: caption buttons), rebuilt with the chrome; null on a phone.</param>
    public MainView(AppModel model, Func<Control>? titleBar = null)
    {
        _model = model;
        _titleBar = titleBar;
        if (AppDevice.IsPhone) PhoneLayout.Install();
        ApplyAppearance();
        BuildChrome();
        _model.RouteChanged += () => ShowRoute();
        _model.Changed += QueueRefresh;
        // «Aktualisiert auf …» closed (or shown by the snapshot tool): the sidebar without it.
        Services.AppUpdater.Shared.NoticeChanged += () =>
        {
            if (_screen?.UsesSidebar == true) RenderSidebarOnly();
        };
        _model.PromptChanged += RenderPrompt;
        if (Application.Current?.PlatformSettings is { } platform)
            platform.ColorValuesChanged += (_, _) => Dispatcher.UIThread.Post(RefreshSystemLook);
        if (Application.Current is { } app) app.ActualThemeVariantChanged += (_, _) => Rebuild();
        _model.SharedArrived += HandleShared;
        SizeChanged += (_, e) =>
        {
            AppDevice.ViewWidth = e.NewSize.Width;
            UpdateStudyScale(e.NewSize);
            // Turning the phone with the keyboard open: Android closes the keyboard without telling (no InputPane
            // change), and the old keyboard height left an empty page in landscape and the buttons hanging in the
            // middle back in portrait (Joan's phone, 06.11.2026). A new size starts without it; an open keyboard
            // reports itself again.
            if (_keyboardInset > 0 && Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1)
            {
                _keyboardInset = 0;
                ApplySafeArea();
            }
            // Turned with an answer field focused: the field with its character bar into view (in landscape the bar
            // sat half behind the buttons, 06.11.2026). The nearest stack around the field holds both.
            // Android drops the focus when the phone turns, so in a study screen it is the answer field on screen.
            if (AppDevice.IsPhone && Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1 && _model.Route is Route.Study)
                foreach (var ms in new[] { 400, 900 })
                    DispatcherTimer.RunOnce(() =>
                    {
                        var field = FocusManager?.GetFocusedElement() as TextBox
                            ?? _screen?.View.GetVisualDescendants().OfType<TextBox>().FirstOrDefault(b => b.IsEffectivelyVisible && b.IsEffectivelyEnabled && b.Bounds.Width > 100);
                        // The field and the room of a character bar under it (about 60 points).
                        field?.BringIntoView(new Rect(0, 0, field.Bounds.Width, field.Bounds.Height + 72));
                    }, TimeSpan.FromMilliseconds(ms));
        };
        ShowRoute();
    }

    // MARK: Shared from other apps

    /// <summary>
    /// Something shared from another app (Android): a backup opens the backup import; text, lists, PDFs and photos go
    /// to the import of a new set (the editor takes them from <see cref="AppModel.PendingImport"/>).
    /// </summary>
    void HandleShared()
    {
        if (_top is null || _model.TakeShared() is not { } shared) return;
        CloseDrawer(animated: false);
        if (shared.Sources.FirstOrDefault(IsBackup) is { } backup && backup.Data is { } data)
        {
            Features.Settings.BackupImportSheet.PrepareData(_model, this, backup.Name, data);
            return;
        }
        _model.PendingImport = shared;
        // An untouched new set takes it; otherwise a fresh one (an unsaved editor asks first).
        if (_screen is Features.Editor.SetEditorScreen { IsNewSet: true, IsUntouched: true } editor) editor.TakePendingImport();
        else _model.Navigate(new Route.Editor(null, StartWithImport: true, Nonce: ++_shareCount));
    }

    int _shareCount;

    /// <summary>A Wortschatz backup (JSON) rather than a vocabulary list.</summary>
    static bool IsBackup(Wortschatz.Core.ImportSource source) =>
        source.Name.EndsWith(".json", StringComparison.OrdinalIgnoreCase) || source.MimeType == "application/json";

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        var top = TopLevel.GetTopLevel(this);
        if (top is null || top == _top) return;
        DetachTop();
        _top = top;
        // The host's frames drive the animations (DesignSystem/Motion.cs).
        Motion.Host ??= top;
        // Keys of the whole host, also when nothing has the focus (then they go to the host itself, not to this view).
        top.AddHandler(KeyDownEvent, OnKeyDownTunnel, RoutingStrategies.Tunnel);
        top.AddHandler(KeyUpEvent, OnKeyUpTunnel, RoutingStrategies.Tunnel);
        top.AddHandler(TextInputEvent, OnTextInputTunnel, RoutingStrategies.Tunnel);
        // Enter that moved to another screen (KeyActionGate): the bubbling end of the key press clears the mark.
        top.AddHandler(KeyDownEvent, OnKeyDownBubble, RoutingStrategies.Bubble, handledEventsToo: true);
        // Phone: the system's back gesture / button.
        top.BackRequested += OnBackRequested;
        if (top.InsetsManager is { } insets) insets.SafeAreaChanged += OnSafeAreaChanged;
        ApplySystemBars();
        if (top.InputPane is { } pane) pane.StateChanged += OnInputPaneChanged;
        ApplySafeArea();
        if (_model.StartupPrompt is { } notice)
        {
            _model.StartupPrompt = null;
            Dispatcher.UIThread.Post(() => _model.Ask(notice), DispatcherPriority.Background);
        }
        // Shared while the app was starting.
        Dispatcher.UIThread.Post(HandleShared, DispatcherPriority.Background);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        DetachTop();
    }

    void DetachTop()
    {
        if (_top is not { } top) return;
        top.RemoveHandler(KeyDownEvent, OnKeyDownTunnel);
        top.RemoveHandler(KeyUpEvent, OnKeyUpTunnel);
        top.RemoveHandler(TextInputEvent, OnTextInputTunnel);
        top.RemoveHandler(KeyDownEvent, OnKeyDownBubble);
        top.BackRequested -= OnBackRequested;
        if (top.InsetsManager is { } insets) insets.SafeAreaChanged -= OnSafeAreaChanged;
        if (top.InputPane is { } pane) pane.StateChanged -= OnInputPaneChanged;
        _top = null;
    }

    void OnKeyUpTunnel(object? sender, KeyEventArgs e) => _keysDown.Remove(e.Key);

    void OnKeyDownBubble(object? sender, KeyEventArgs e) => _enterInFlight = false;

    // MARK: Host

    /// <summary>The host became active or inactive (Windows: the window; Android: the app in front or not).</summary>
    public void HostActivityChanged(bool active)
    {
        if (active) RefreshSystemLook();
        _screen?.WindowActivityChanged(active);
    }

    /// <summary>The host's title (the window title on Windows; nothing on a phone).</summary>
    public string Title
    {
        get => (_top as Window)?.Title ?? "Wortschatz";
        set
        {
            if (TopLevel.GetTopLevel(this) is Window window) window.Title = value;
        }
    }

    /// <summary>The host's file pickers (Windows: the file dialogs; Android: the system's document picker).</summary>
    public IStorageProvider StorageProvider => TopLevel.GetTopLevel(this)?.StorageProvider ?? throw new InvalidOperationException("Kein Fenster.");

    public Avalonia.Input.Platform.IClipboard? Clipboard => TopLevel.GetTopLevel(this)?.Clipboard;

    public IFocusManager? FocusManager => TopLevel.GetTopLevel(this)?.FocusManager;

    /// <summary>The space the app has (the view's size, or the host's while it is not laid out yet).</summary>
    Size ViewSize => Bounds.Width > 0 ? Bounds.Size : TopLevel.GetTopLevel(this)?.ClientSize ?? new Size(1240, 800);

    /// <summary>
    /// Whether the app may end now. An exam with answers or an unsaved editor asks first; a library that could not be
    /// written asks whether to lose the changes (Mac: AppModel+Termination). <paramref name="close"/> ends the app
    /// once the question is answered.
    /// </summary>
    public bool CanQuit(Action close)
    {
        if (_quitConfirmed) return true;
        if (_model.LeaveGuard is { } guard && guard(() =>
            {
                _model.LeaveGuard = null;
                close();
            }))
            return false;
        if (!_model.Flush())
        {
            _model.Ask(new PromptRequest(L("Deine Änderungen konnten nicht gespeichert werden"),
                L("Wenn du Wortschatz jetzt beendest, gehen die letzten Änderungen verloren. Exportiere zur Sicherheit ein Backup."),
                [
                    new PromptButton(L("Nochmal versuchen"), close, IsDefault: true),
                    new PromptButton(L("Backup exportieren …"), () => _ = Features.Settings.SettingsScreen.ExportBackup(_model, this)),
                    new PromptButton(L("Trotzdem beenden"), () =>
                    {
                        _quitConfirmed = true;
                        close();
                    }, IsDestructive: true),
                    new PromptButton(L("Abbrechen"), IsCancel: true),
                ]));
            return false;
        }
        return true;
    }

    bool _quitConfirmed;

    /// <summary>The app ends: the screen lets go, speech stops.</summary>
    public void Shutdown()
    {
        _screen?.Deactivate();
        _model.Speech.Stop();
    }

    // MARK: System settings

    /// <summary>
    /// The system's contrast theme, transparency effects and animation effects, read again whenever the host becomes
    /// active: a change in the system settings shows at once (Mac: the environment values update live).
    /// </summary>
    void RefreshSystemLook()
    {
        bool motion = Motion.RefreshReduceMotion();
        if (WsTheme.ReadAccessibility()) Rebuild();
        else if (motion) BuildChromeKeepingScreen();
    }

    /// <summary>Rebuilds the chrome (backdrop, toasts) around the current screen (Reduce Motion changed).</summary>
    void BuildChromeKeepingScreen()
    {
        BuildChrome();
        RenderBody();
    }

    // MARK: Appearance

    /// <summary>The theme setting of the library (Hell, Dunkel, System) picks the palette.</summary>
    void ApplyAppearance()
    {
        WsTheme.ReadAccessibility();
        var setting = _model.Store.GetSettings().Theme;
        bool dark = setting switch
        {
            ThemeSetting.Dark => true,
            ThemeSetting.Light => false,
            _ => Application.Current?.ActualThemeVariant == Avalonia.Styling.ThemeVariant.Dark,
        };
        WsTheme.Use(dark);
        if (Application.Current is { } app)
        {
            var styles = app.Styles;
            for (int i = styles.Count - 1; i >= 1; i--) styles.RemoveAt(i);
            styles.Add(AppStyles.Create());
            app.RequestedThemeVariant = setting switch
            {
                ThemeSetting.Dark => Avalonia.Styling.ThemeVariant.Dark,
                ThemeSetting.Light => Avalonia.Styling.ThemeVariant.Light,
                _ => Avalonia.Styling.ThemeVariant.Default,
            };
        }
    }

    /// <summary>
    /// Rebuilds everything (after a theme change). Applying a theme can switch Avalonia's theme variant, whose change
    /// event rebuilds once more while this one runs: needed (25.11.2026), the second one picks the palette of «System»
    /// from the new variant, the first one still read the old one.
    /// </summary>
    public void Rebuild()
    {
        ApplyAppearance();
        BuildChrome();
        ShowRoute(rebuild: true);
    }

    // MARK: Chrome

    /// <summary>Height of the bar on top: the host's title bar (Windows) or the phone's bar with ☰.</summary>
    double TopBarHeight => _titleBar is not null ? 40 : AppDevice.IsPhone ? PhoneBarHeight : 0;

    void BuildChrome()
    {
        double bar = TopBarHeight;
        _root = new Grid { RowDefinitions = new RowDefinitions($"{bar.ToString(System.Globalization.CultureInfo.InvariantCulture)},*") };
        // The backdrop fills everything (on a phone also under the system bars); the content sits in _root.
        var frame = new Grid();
        frame.Children.Add(new Backdrop());
        frame.Children.Add(_root);
        if (_titleBar is not null) _root.Children.Add(_titleBar());
        else if (AppDevice.IsPhone) _root.Children.Add(_phoneBar = PhoneBar());
        Grid.SetRow(_body, 1);
        _body.Children.Clear();
        if (_body.Parent is Panel old) old.Children.Remove(_body);
        _root.Children.Add(_body);
        // Phone: the library slides in over the page.
        if (AppDevice.IsPhone)
        {
            Grid.SetRowSpan(_drawerLayer, 2);
            if (_drawerLayer.Parent is Panel oldDrawer) oldDrawer.Children.Remove(_drawerLayer);
            _root.Children.Add(_drawerLayer);
            CloseDrawer(animated: false);
        }
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
        _root.Children.Add(DesignSystem.Announcer.CreateHost());
        Content = frame;
        Background = WsTheme.B(WsTheme.P.Backdrop);
        ApplySystemBars();
        ApplySafeArea();
        ChromeRebuilt?.Invoke();
    }

    // MARK: Safe area (phone)

    void OnSafeAreaChanged(object? sender, Avalonia.Controls.Platform.SafeAreaChangedArgs e) => ApplySafeArea();

    /// <summary>
    /// Phone: the status and navigation bars in the backdrop's colour, with dark or light symbols to match the app's
    /// theme (also when the app is dark and the phone light).
    /// </summary>
    void ApplySystemBars()
    {
        if (!AppDevice.IsPhone) return;
        var brush = new SolidColorBrush(WsTheme.P.Backdrop);
        TopLevel.SetSystemBarColor(this, brush);
        if (_top is not null) TopLevel.SetSystemBarColor(_top, brush);
    }

    /// <summary>How far the on-screen keyboard covers the view's bottom (phone).</summary>
    double _keyboardInset;

    /// <summary>
    /// The on-screen keyboard opened or closed: the content ends above it (the study screens' buttons and the
    /// editor's bar stay reachable), and the focused field scrolls into view.
    /// </summary>
    void OnInputPaneChanged(object? sender, Avalonia.Controls.Platform.InputPaneStateEventArgs e)
    {
        // The content ends at the keyboard's top edge. Its height alone is not enough: with gesture navigation Avalonia
        // gives it without the navigation bar (the emulator, 05.11.2026: 312 of 336 points), and subtracting the bar
        // again left the buttons under the keyboard by its 24 points. The top edge is right either way.
        double inset = 0;
        if (e.NewState == Avalonia.Controls.Platform.InputPaneState.Open && e.EndRect.Height > 0)
        {
            double contentBottom = (_root.TranslatePoint(new Point(0, _root.Bounds.Height), this)?.Y ?? Bounds.Height) + _root.Margin.Bottom;
            double origin = _top is not null ? this.TranslatePoint(default, _top)?.Y ?? 0 : 0;
            inset = Math.Max(0, contentBottom - (e.EndRect.Y - origin));
        }
        if (Math.Abs(inset - _keyboardInset) < 0.5) return;
        _keyboardInset = inset;
        ApplySafeArea();
        if (inset > 0)
            Dispatcher.UIThread.Post(() => (FocusManager?.GetFocusedElement() as Control)?.BringIntoView(), DispatcherPriority.Background);
    }

    /// <summary>
    /// Phone: Avalonia keeps the content out of the status and navigation bars itself (no edge-to-edge drawing); the
    /// keyboard's height is added at the bottom. An app that asks for edge to edge pads for the bars here as well
    /// (SafeAreaPadding comes in device pixels).
    /// </summary>
    void ApplySafeArea()
    {
        if (_top is null) return;
        var safe = default(Thickness);
        if (_top.InsetsManager is { DisplayEdgeToEdgePreference: true } insets)
        {
            double scale = _top.RenderScaling > 0 ? _top.RenderScaling : 1;
            var px = insets.SafeAreaPadding;
            safe = new Thickness(px.Left / scale, px.Top / scale, px.Right / scale, px.Bottom / scale);
        }
        _root.Margin = new Thickness(safe.Left, safe.Top, safe.Right, Math.Max(safe.Bottom, _keyboardInset));
    }

    // MARK: Phone bar and drawer

    const double PhoneBarHeight = 52;
    Control? _phoneBar;
    readonly Grid _drawerLayer = new() { IsVisible = false };
    bool _drawerOpen;

    /// <summary>The bar on top of a phone: ☰ (the library), the page's name, + (new set).</summary>
    Control PhoneBar()
    {
        var p = WsTheme.P;
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Height = PhoneBarHeight, Margin = new Thickness(6, 0) };
        var menu = Ui.IconButton(IconName.Menu, L("Lernsets und Menü"), OpenDrawer, 44, ButtonKind.Plain);
        menu.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(menu);
        var title = Ui.Text(PageName(), 17, FontWeight.SemiBold, p.Text);
        title.VerticalAlignment = VerticalAlignment.Center;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        title.Margin = new Thickness(6, 0);
        Grid.SetColumn(title, 1);
        grid.Children.Add(title);
        // «+ Neues Lernset» next to the library pages; in the settings it looked like «add a setting».
        if (_model.Route is not (Route.Editor or Route.Settings))
        {
            var add = Ui.IconButton(IconName.Plus, L("Neues Lernset"), () => _model.OpenEditor(), 44, ButtonKind.Plain);
            add.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(add, 2);
            grid.Children.Add(add);
        }
        return grid;
    }

    /// <summary>The name of the current page in the phone's bar.</summary>
    string PageName() => _model.Route switch
    {
        Route.SetDetail d => _model.Set(d.SetId)?.Title is { Length: > 0 } t ? t : L("Lernset"),
        Route.Editor e => e.SetId is null ? L("Neues Lernset") : L("Lernset bearbeiten"),
        Route.Settings => L("Einstellungen"),
        _ => "Wortschatz",
    };

    void RenderPhoneBar()
    {
        if (!AppDevice.IsPhone || _titleBar is not null || _phoneBar is null) return;
        int index = _root.Children.IndexOf(_phoneBar);
        if (index < 0) return;
        var margin = _phoneBar.Margin;
        _phoneBar = PhoneBar();
        _phoneBar.Margin = margin;
        _root.Children[index] = _phoneBar;
    }

    /// <summary>Opens the library over the page (phone).</summary>
    public void OpenDrawer()
    {
        if (!AppDevice.IsPhone || _drawerOpen) return;
        _drawerOpen = true;
        var p = WsTheme.P;
        _drawerLayer.Children.Clear();
        var dim = new Border { Background = WsTheme.B(Color.FromArgb(p.Dark ? (byte)150 : (byte)90, 0, 0, 0)) };
        dim.PointerPressed += (_, e) =>
        {
            e.Handled = true;
            CloseDrawer();
        };
        _drawerLayer.Children.Add(dim);
        // At most PhoneLayout.MaxFixedWidth: a wider fixed width would turn into a centred maximum.
        double width = Math.Min(PhoneLayout.MaxFixedWidth, ViewSize.Width - 48);
        var panel = new Border
        {
            Width = width,
            HorizontalAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(8, 8, 8, 8),
            Background = WsTheme.B(p.Dark ? Palette.Hex(0x23252F) : Palette.Hex(0xF4F5FA)),
            CornerRadius = new CornerRadius(0, 22, 22, 0),
            Child = new LibrarySidebar(_model, this).View,
        };
        _drawerLayer.Children.Add(panel);
        _drawerLayer.IsVisible = true;
        _drawerLayer.IsHitTestVisible = true;
        Effects.FadeIn(dim, Motion.Soft(0.2));
        var from = Motion.ReduceMotion ? new Placement(Opacity: 0) : new Placement(X: -(width + 20), Opacity: 1);
        Effects.Of(panel).Enter(from, Motion.Soft(0.3));
    }

    /// <summary>Closes the library drawer (phone).</summary>
    public void CloseDrawer(bool animated = true)
    {
        if (!_drawerOpen && !_drawerLayer.IsVisible) return;
        _drawerOpen = false;
        _drawerLayer.IsHitTestVisible = false;
        if (!animated || _drawerLayer.Children.Count < 2)
        {
            _drawerLayer.Children.Clear();
            _drawerLayer.IsVisible = false;
            return;
        }
        var panel = (Control)_drawerLayer.Children[1];
        Effects.Of(_drawerLayer.Children[0]).Place(new Placement(Opacity: 0), Motion.Soft(0.2));
        var to = Motion.ReduceMotion ? new Placement(Opacity: 0) : new Placement(X: -(panel.Bounds.Width + 20));
        Effects.Of(panel).Place(to, Motion.Soft(0.25), () =>
        {
            if (_drawerOpen) return;
            _drawerLayer.Children.Clear();
            _drawerLayer.IsVisible = false;
        });
    }

    // MARK: Back (phone)

    void OnBackRequested(object? sender, RoutedEventArgs e)
    {
        // One press of the system back reached the app twice when a text field had the focus (the keyboard sends an
        // Esc as well; Joan's phone with Typewise, 06.11.2026): the second one closed again what the first opened, or
        // went a second page back. A back right after a back or an Esc is the same press.
        if (BackJustHandled())
        {
            e.Handled = true;
            return;
        }
        _lastBackAt = DateTime.UtcNow;
        // The system closes an open drop-down list or menu itself on back, before the app hears of it (Joan's phone,
        // 06.11.2026: back on «Zeitlimit» or «⋯» left the page). Such a back has done its job.
        if (AppDevice.IsPhone && DateTime.UtcNow - s_popupClosedAt < PopupEcho)
        {
            e.Handled = true;
            return;
        }
        if (GoBack()) e.Handled = true;
    }

    static DateTime s_popupClosedAt;
    static readonly TimeSpan PopupEcho = TimeSpan.FromMilliseconds(400);

    DateTime _lastBackAt;
    static readonly TimeSpan BackEcho = TimeSpan.FromMilliseconds(450);

    bool BackJustHandled() => AppDevice.IsPhone && DateTime.UtcNow - _lastBackAt < BackEcho;

    /// <summary>An open drop-down list or context menu (phone: back closes it first, like a tap outside).</summary>
    bool ClosePopups()
    {
        bool closed = false;
        foreach (var box in this.GetVisualDescendants().OfType<ComboBox>())
        {
            if (!box.IsDropDownOpen) continue;
            box.IsDropDownOpen = false;
            closed = true;
        }
        if (s_openMenu is { } r && r.TryGetTarget(out var menu) && menu.IsOpen)
        {
            menu.Close();
            closed = true;
        }
        s_openMenu = null;
        // The phone shows menus in the window's overlay layer: look for open ones there too (the opened event did not
        // come for menus opened in code, «⋯» on the set page – back went to the overview, 06.11.2026).
        if (_top is { } top)
            foreach (var open in top.GetVisualDescendants().OfType<ContextMenu>().Where(m => m.IsOpen).ToList())
            {
                open.Close();
                closed = true;
            }
        return closed;
    }

    /// <summary>The context menu open right now (see <see cref="TrackMenus"/>).</summary>
    static WeakReference<ContextMenu>? s_openMenu;

    /// <summary>Remembers the open context menu, so the system back can close it.</summary>
    public static void TrackMenus()
    {
        // Phone: no tooltips – a long press showed a PC tooltip that stayed and was cut at the right edge (06.11.2026).
        // (A style for every control froze the start; the tip is simply dropped where it is set.)
        if (AppDevice.IsPhone)
            ToolTip.TipProperty.Changed.AddClassHandler<Control>((c, e) =>
            {
                if (e.NewValue is not null) c.ClearValue(ToolTip.TipProperty);
            });
        ComboBox.IsDropDownOpenProperty.Changed.AddClassHandler<ComboBox>((_, e) =>
        {
            if (e.NewValue is false) s_popupClosedAt = DateTime.UtcNow;
        });
        ContextMenu.ClosedEvent.AddClassHandler<ContextMenu>((_, _) => s_popupClosedAt = DateTime.UtcNow);
        MenuBase.IsOpenProperty.Changed.AddClassHandler<MenuBase>((_, e) =>
        {
            if (e.NewValue is false) s_popupClosedAt = DateTime.UtcNow;
        });
        Avalonia.Controls.Primitives.Popup.IsOpenProperty.Changed.AddClassHandler<Avalonia.Controls.Primitives.Popup>((_, e) =>
        {
            if (e.NewValue is false) s_popupClosedAt = DateTime.UtcNow;
        });
        ContextMenu.OpenedEvent.AddClassHandler<ContextMenu>((menu, _) => s_openMenu = new WeakReference<ContextMenu>(menu));
        ContextMenu.ClosedEvent.AddClassHandler<ContextMenu>((menu, _) =>
        {
            if (s_openMenu is { } r && r.TryGetTarget(out var m) && ReferenceEquals(m, menu)) s_openMenu = null;
        });
    }

    /// <summary>
    /// The system's back gesture (Android): closes the drawer or a question, then works like Esc on the screen (a study
    /// screen ends, the editor asks about unsaved changes), then goes one page up (set → overview). False on the
    /// overview: the system then puts the app away.
    /// </summary>
    public bool GoBack()
    {
        if (ClosePopups()) return true;
        if (_drawerOpen)
        {
            CloseDrawer();
            return true;
        }
        if (_model.Prompt is { } prompt)
        {
            var cancel = prompt.Buttons.FirstOrDefault(b => b.IsCancel) ?? prompt.Buttons.LastOrDefault();
            if (cancel is not null) _model.Answer(cancel);
            else _model.ClosePrompt();
            return true;
        }
        if (_screen is null) return false;
        var esc = new KeyEventArgs { RoutedEvent = KeyDownEvent, Key = Key.Escape, KeyModifiers = KeyModifiers.None };
        var route = _model.Route;
        if (_screen.HandleKey(esc, false) || esc.Handled || !ReferenceEquals(route, _model.Route)) return true;
        switch (route)
        {
            case Route.Study s:
                _model.OpenSet(s.Request.SetId);
                return true;
            case Route.Editor { SetId: { } id }:
                _model.OpenSet(id);
                return true;
            case Route.Overview:
                return false;
            default:
                _model.ShowOverview();
                return true;
        }
    }

    // MARK: Routing

    void ShowRoute(bool rebuild = false)
    {
        var started = PerfTrace.Start();
        // Enter moved to another screen: its key-bound actions wait a moment (Mac: KeyActionGate.returnKeyMoved).
        if (_enterInFlight) _enterSettlesAt = DateTime.UtcNow + KeySettleTime;
        bool hadSidebar = _screen?.UsesSidebar ?? true;
        var leavingSidebar = hadSidebar ? CurrentSidebar() : null;
        var leavingPage = hadSidebar ? _screen?.View : null;
        _screen?.Deactivate();
        _screen = Screen.For(_model.Route, _model, this);
        _keysDown.Clear();
        // Toasts stay above a study screen's floating action bar.
        // Phone: above the study screens' two-line action bar.
        ApplyToastClearance();
        if (AppDevice.IsPhone) CloseDrawer();
        RenderBody();
        if (!rebuild && !AppDevice.IsPhone) SlideSidebar(hadSidebar, _screen.UsesSidebar, leavingSidebar, leavingPage);
        _screen.Activate();
        // Pages fade in where they stand (Mac: AppModel.revealFirstPage / leaveStudyLayout); the study screens play their
        // own entrance (StudyEntrance). A theme change rebuilds without it.
        if (_screen.UsesSidebar && !rebuild) StudyEntrance.RevealScreen(_screen.View);
        PerfTrace.UntilLayout(this, started, _screen.GetType().Name);
    }

    // MARK: Study screens on large windows

    /// <summary>
    /// The study screens (Lernen, Schreiben, Karteikarten, Prüfung) are laid out for 1280 × 800. On a larger window they
    /// grow as a whole – card, type and buttons alike – instead of a small card in the middle of a large monitor (Joan,
    /// 06.11.2026). No upper limit (Joan: on a huge monitor it should just keep growing); in steps of 0.05 (no new
    /// layout for every pixel); never smaller than designed, never on a phone. The sizes are Windows' logical pixels:
    /// a 4K/8K screen at 200–300 % display scaling grows only a little, the same screen at 100 % a lot.
    /// </summary>
    public double StudyScale { get; private set; } = 1;

    /// <summary>The size a study screen lays out in: the window divided by StudyScale.</summary>
    public Size StudyArea => new(Bounds.Width / StudyScale, Bounds.Height / StudyScale);

    public const double StudyDesignWidth = 1280, StudyDesignHeight = 800;

    /// <summary>The scale for a window of <paramref name="size"/> (pure, for tests and the snapshot tool).</summary>
    public static double StudyScaleFor(Size size)
    {
        if (AppDevice.IsPhone || size.Width <= 0 || size.Height <= 0) return 1;
        double fit = Math.Min(size.Width / StudyDesignWidth, size.Height / StudyDesignHeight);
        return Math.Max(1, Math.Floor(fit * 20) / 20);
    }

    LayoutTransformControl? _studyHost;

    /// <summary>
    /// Toasts stay above a study screen's floating action bar; phone: above its two-line bar. On a scaled study screen
    /// they grow with it (from their bottom edge), so they do not shrink to a speck on a huge monitor.
    /// </summary>
    void ApplyToastClearance()
    {
        if (_toasts is null || _screen is null) return;
        bool scaled = !AppDevice.IsPhone && !_screen.UsesSidebar && StudyScale > 1;
        _toasts.BottomClearance = AppDevice.IsPhone && !_screen.UsesSidebar ? 150
            : _screen.UsesSidebar ? _screen.ToastClearance : _screen.ToastClearance * StudyScale;
        _toasts.RenderTransformOrigin = new RelativePoint(0.5, 1, RelativeUnit.Relative);
        _toasts.RenderTransform = scaled ? new ScaleTransform(StudyScale, StudyScale) : null;
    }

    void UpdateStudyScale(Size size)
    {
        double scale = StudyScaleFor(size);
        if (scale == StudyScale) return;
        StudyScale = scale;
        if (_studyHost is not null) _studyHost.LayoutTransform = new ScaleTransform(scale, scale);
        ApplyToastClearance();
    }

    void RenderBody()
    {
        _body.Children.Clear();
        if (_screen is null) return;
        // The same screen again (sidebar shown or hidden): out of its old layout first.
        if (_screen.View.Parent is Panel previous) previous.Children.Remove(_screen.View);
        _studyHost = null;
        if (AppDevice.IsPhone)
        {
            // Phone: the page alone; the bar on top only next to pages that would have the sidebar.
            RenderPhoneBar();
            if (_phoneBar is not null) _phoneBar.IsVisible = _screen.UsesSidebar;
            _root.RowDefinitions[0].Height = new GridLength(_screen.UsesSidebar ? PhoneBarHeight : 0);
            _screen.View.Margin = _screen.UsesSidebar ? new Thickness(8, 0, 8, 8) : new Thickness(10, 0, 10, 0);
            _body.Children.Add(_screen.View);
            return;
        }
        if (_screen.UsesSidebar)
        {
            var layout = new Grid { ColumnDefinitions = new ColumnDefinitions($"{(_sidebarHidden ? 0 : SidebarWidth).ToString(System.Globalization.CultureInfo.InvariantCulture)},*"), Margin = new Thickness(10, 0, 10, 10) };
            // A host that stays while the sidebar's content is rebuilt after data changes (a slide keeps running).
            var sidebar = new ContentControl { Content = new LibrarySidebar(_model, this).View, IsVisible = !_sidebarHidden };
            layout.Children.Add(sidebar);
            var main = _screen.View;
            Grid.SetColumn(main, 1);
            layout.Children.Add(main);
            if (!_sidebarHidden) layout.Children.Add(SidebarEdge(layout));
            _body.Children.Add(layout);
        }
        else
        {
            // A study screen: scaled to the window (StudyScale). LayoutTransformControl scales through its child's
            // RenderTransform, which the screens' entrance animations set too: a plain panel in between keeps both.
            var inner = new Panel();
            inner.Children.Add(_screen.View);
            _studyHost = new LayoutTransformControl { Child = inner, LayoutTransform = new ScaleTransform(StudyScale, StudyScale) };
            _body.Children.Add(_studyHost);
        }
    }

    // MARK: Sidebar

    /// <summary>
    /// Like the Mac's SidebarColumn: at least 250 wide, at most 360 – dragged out, the sidebar stops there and the set
    /// page beside it always stays in view (Mac since 24.11.2026, Anthony; before: half the window).
    /// </summary>
    const double SidebarMinWidth = 250;
    const double SidebarDefaultWidth = 262;
    const double SidebarMaxWidth = 360;
    bool _sidebarHidden;

    double SidebarWidth => Math.Clamp(_model.Preferences.SidebarWidth ?? SidebarDefaultWidth, SidebarMinWidth, SidebarMaxWidth);

    /// <summary>The sidebar of the current layout (null on a study screen).</summary>
    Control? CurrentSidebar() =>
        _body.Children.FirstOrDefault() is Grid { ColumnDefinitions.Count: 2 } layout && layout.Children.Count > 0 && layout.Children[0].IsVisible ? layout.Children[0] : null;

    /// <summary>
    /// The sidebar's right edge: drag it to make the sidebar wider or narrower (Mac: NavigationSplitView's divider, at most
    /// SidebarMaxWidth), double-click to go back to the usual width.
    /// </summary>
    Control SidebarEdge(Grid layout)
    {
        var edge = new Border
        {
            Width = 10,
            Background = Brushes.Transparent,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, -10, 0),
            Cursor = new Cursor(StandardCursorType.SizeWestEast),
            ZIndex = 5,
        };
        ToolTip.SetTip(edge, L("Ziehen, um die Seitenleiste breiter oder schmaler zu machen"));
        AutomationProperties.SetAccessibilityView(edge, AccessibilityView.Raw);
        double? startX = null, startWidth = null;
        edge.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(edge).Properties.IsLeftButtonPressed) return;
            if (e.ClickCount == 2)
            {
                _model.Preferences.SidebarWidth = null;
                layout.ColumnDefinitions[0].Width = new GridLength(SidebarWidth);
                e.Handled = true;
                return;
            }
            startX = e.GetPosition(this).X;
            startWidth = layout.ColumnDefinitions[0].ActualWidth;
            e.Pointer.Capture(edge);
            e.Handled = true;
        };
        edge.PointerMoved += (_, e) =>
        {
            if (startX is not { } x0 || startWidth is not { } w0) return;
            // In 10-pt steps like the Mac, so dragging does not lay out the page on every pixel.
            double width = Math.Clamp(Math.Round((w0 + e.GetPosition(this).X - x0) / 10) * 10, SidebarMinWidth, SidebarMaxWidth);
            if (Math.Abs(layout.ColumnDefinitions[0].Width.Value - width) >= 1) layout.ColumnDefinitions[0].Width = new GridLength(width);
        };
        edge.PointerReleased += (_, e) =>
        {
            if (startX is null) return;
            startX = null;
            e.Pointer.Capture(null);
            _model.Preferences.SidebarWidth = layout.ColumnDefinitions[0].Width.Value;
        };
        return edge;
    }

    /// <summary>Ctrl+Alt+S: hides or shows the sidebar (Mac: Darstellung › Seitenleiste ein-/ausblenden); on a phone ☰.</summary>
    public void ToggleSidebar()
    {
        if (AppDevice.IsPhone)
        {
            if (_drawerOpen) CloseDrawer();
            else OpenDrawer();
            return;
        }
        if (_screen is not { UsesSidebar: true }) return;
        var before = CurrentSidebar();
        _sidebarHidden = !_sidebarHidden;
        RenderBody();
        SlideSidebar(_sidebarHidden, !_sidebarHidden, before);
        DesignSystem.Announcer.Announce(_sidebarHidden ? L("Seitenleiste ausgeblendet") : L("Seitenleiste eingeblendet"));
    }

    /// <summary>
    /// Into a study screen the sidebar slides away to the left and fades; out of it, it slides back in (Mac:
    /// AppModel.enterStudyLayout / leaveStudyLayout with StudyEntrance.sidebar). Under Reduce Motion it only fades.
    /// </summary>
    void SlideSidebar(bool hadSidebar, bool hasSidebar, Control? leaving, Control? leavingPage = null)
    {
        var curve = Motion.ReduceMotion ? Curve.EaseOut(0.15) : Motion.Soft(0.42);
        if (hadSidebar && !hasSidebar && leaving is not null && leaving.Bounds.Width > 0)
        {
            // The old sidebar stays a moment over the new screen, sliding out.
            var bounds = leaving.Bounds;
            if (leaving.Parent is Panel old) old.Children.Remove(leaving);
            var holder = new Canvas { IsHitTestVisible = false };
            // The page it leaves dissolves into the backdrop meanwhile (Mac: StudyEntrance.dissolve, 0.28 s).
            if (leavingPage is { Bounds.Width: > 0 } page && page.Parent is Panel pageParent)
            {
                var pageBounds = page.Bounds;
                pageParent.Children.Remove(page);
                page.Width = pageBounds.Width;
                page.Height = pageBounds.Height;
                Canvas.SetLeft(page, pageBounds.X + 10);
                Canvas.SetTop(page, pageBounds.Y);
                holder.Children.Add(page);
                Effects.Of(page).Place(new Placement(Opacity: 0), Motion.ReduceMotion ? Curve.EaseOut(0.12) : Motion.Soft(0.28));
            }
            leaving.Width = bounds.Width;
            leaving.Height = bounds.Height;
            Canvas.SetLeft(leaving, 10);
            Canvas.SetTop(leaving, 0);
            holder.Children.Add(leaving);
            _body.Children.Add(holder);
            var to = Motion.ReduceMotion ? new Placement(Opacity: 0) : new Placement(X: -(bounds.Width + 20), Opacity: 0);
            Effects.Of(leaving).Place(to, curve, () => _body.Children.Remove(holder));
        }
        else if (!hadSidebar && hasSidebar && CurrentSidebar() is { } arriving)
        {
            var from = Motion.ReduceMotion ? new Placement(Opacity: 0) : new Placement(X: -(SidebarWidth + 20), Opacity: 0);
            Effects.Of(arriving).Enter(from, curve);
        }
    }

    // MARK: Key gate

    /// <summary>As long as the study flows' input lock (Mac: KeyActionGate.settleTime).</summary>
    static readonly TimeSpan KeySettleTime = TimeSpan.FromMilliseconds(280);
    bool _enterInFlight;
    DateTime _enterSettlesAt;

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
        if (AppDevice.IsPhone)
        {
            // The page's name may have changed (a set renamed); an open drawer shows the new list.
            RenderPhoneBar();
            if (_drawerOpen && _drawerLayer.Children.Count > 1 && _drawerLayer.Children[1] is Border panel)
                panel.Child = new LibrarySidebar(_model, this).View;
            return;
        }
        if (_body.Children.FirstOrDefault() is Grid layout && layout.Children.Count > 0 && layout.ColumnDefinitions.Count == 2)
        {
            if (layout.Children[0] is ContentControl host) host.Content = new LibrarySidebar(_model, this).View;
            else
            {
                layout.Children.RemoveAt(0);
                layout.Children.Insert(0, new LibrarySidebar(_model, this).View);
            }
        }
    }

    // MARK: Prompts

    /// <summary>The model's prompt as a card over a dimmed window (Mac: alert): Enter = default, Esc = cancel.</summary>
    void RenderPrompt()
    {
        // A prompt that replaces another (a sheet's next step) does not fade in again.
        bool replacing = _promptLayer.Children.Count > 0;
        _promptLayer.Children.Clear();
        if (_model.Prompt is not { } prompt)
        {
            _promptLayer.IsHitTestVisible = false;
            return;
        }
        _promptLayer.IsHitTestVisible = true;
        var p = WsTheme.P;
        bool phone = AppDevice.IsPhone;
        // Phone: the buttons one under the other (long labels do not fit side by side), the default one on top.
        Panel buttons = phone
            ? new StackPanel { Spacing = 8 }
            : new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right };
        WsButton? focus = null;
        foreach (var b in phone ? prompt.Buttons.OrderBy(b => b.IsDefault ? 0 : b.IsCancel ? 2 : 1).ToList() : prompt.Buttons)
        {
            string? hint = phone ? null : b.IsDefault ? "↵" : b.IsCancel ? "Esc" : null;
            WsButton button = b.IsDestructive ? Ui.Danger(b.Label, () => _model.Answer(b), null)
                : b.IsDefault ? Ui.Primary(b.Label, () => _model.Answer(b), hint, height: 40)
                : Ui.Secondary(b.Label, () => _model.Answer(b), keyHint: hint);
            if (phone) button.HorizontalAlignment = HorizontalAlignment.Stretch;
            if (b.IsDefault) focus = button;
            buttons.Children.Add(button);
        }
        // A sheet's own content (kept across renders: taken out of the previous card first).
        if (prompt.Content is { } content)
        {
            if (content.Parent is Panel holder) holder.Children.Remove(content);
            else if (content.Parent is Decorator decorator) decorator.Child = null;
        }
        var body = Ui.V(14, Ui.Text(prompt.Title, 20, FontWeight.Bold, wrap: TextWrapping.Wrap),
            prompt.Message.Length > 0 ? Ui.Text(prompt.Message, 14.5, color: p.TextSecondary, wrap: TextWrapping.Wrap) : null, prompt.Content, buttons);
        var card = Ui.Hero(phone ? new ScrollViewer { Content = body, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled } : body,
            phone ? new Thickness(20, 18) : new Thickness(26, 22), 24);
        card.Width = phone ? Math.Min(prompt.Width, ViewSize.Width - 24) : prompt.Width;
        card.MaxHeight = Math.Max(300, ViewSize.Height - 60);
        // Like the Mac's alerts and sheets: a click next to the card does nothing (Esc cancels).
        _promptLayer.Children.Add(StudyChrome.Overlay(card, () => { }));
        // A question over the page: opaque, so the text behind never shows through.
        card.Background = WsTheme.B(p.Dark ? Palette.Hex(0x2E3142) : Palette.Hex(0xFBFBFE));
        if (!replacing) Effects.FadeIn(_promptLayer, Motion.Soft(0.2));
        // Phone: no focus on the button (it would only draw a ring; the keyboard is not there).
        if (focus is not null && !phone) Dispatcher.UIThread.Post(() => focus.Focus(), DispatcherPriority.Input);
    }

    bool HandlePromptKey(KeyEventArgs e)
    {
        if (_model.Prompt is not { } prompt) return false;
        if (prompt.KeyHandler?.Invoke(e) == true) return true;
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
        // A text field in the prompt (a form sheet) gets its keys: deleting, moving, pasting.
        if (FocusManager?.GetFocusedElement() is TextBox box && _promptLayer.IsVisualAncestorOf(box)) return false;
        // Tab and arrows move between the buttons; everything else stays away from the screen behind.
        return e.Key is not (Key.Tab or Key.Left or Key.Right or Key.Space);
    }

    // MARK: Keys

    void OnKeyDownTunnel(object? sender, KeyEventArgs e)
    {
        try { KeyDownTunnel(e); }
        finally
        {
            // Phone: an Esc that did something is the press; the back request Android sends after it is its echo. An Esc
            // nothing handled must let that back request through (else back did not close the drawer, 06.11.2026).
            if (e.Key == Key.Escape && AppDevice.IsPhone && e.Handled) _lastBackAt = DateTime.UtcNow;
        }
    }

    void KeyDownTunnel(KeyEventArgs e)
    {
        // Phone: the system back reaches the app as an Esc key on some phones (Joan's, 06.11.2026), not as a back
        // request: an open drop-down list or menu closes first, the page stays.
        if (e.Key == Key.Escape && AppDevice.IsPhone && ClosePopups())
        {
            e.Handled = true;
            _lastBackAt = DateTime.UtcNow;
            return;
        }
        // Phone: the Esc the keyboard sends along with the system back (see OnBackRequested) is the same press.
        if (e.Key == Key.Escape && BackJustHandled())
        {
            e.Handled = true;
            return;
        }
        bool isRepeat = !_keysDown.Add(e.Key);
        if (e.Key is Key.Enter or Key.Return)
        {
            // A quick second Enter right after one that changed the screen is held back (Mac: KeyActionGate).
            if (DateTime.UtcNow < _enterSettlesAt)
            {
                e.Handled = true;
                return;
            }
            _enterInFlight = !isRepeat;
        }
        if (HandlePromptKey(e))
        {
            e.Handled = true;
            return;
        }
        if (_model.Prompt is not null) return;
        if (_screen is null) return;
        if (_screen.HandleKey(e, isRepeat)) e.Handled = true;
        else if (!isRepeat && (HandleWindowKey(e) || HandleCommand(e))) e.Handled = true;
    }

    /// <summary>
    /// Keys of the window itself: F1 or Ctrl+/ the list of shortcuts (Mac: the menu bar shows them), F11 full screen,
    /// Ctrl+Alt+S the sidebar, Ctrl+Z / Ctrl+Y undo and redo deleting a set (Mac: Bearbeiten › Widerrufen/Wiederholen;
    /// in a text field they stay the field's own).
    /// </summary>
    bool HandleWindowKey(KeyEventArgs e)
    {
        var mods = e.KeyModifiers;
        bool ctrl = mods.HasFlag(KeyModifiers.Control), shift = mods.HasFlag(KeyModifiers.Shift), alt = mods.HasFlag(KeyModifiers.Alt);
        switch (e.Key)
        {
            case Key.F1 when mods == KeyModifiers.None:
            case Key.OemQuestion or Key.Divide when ctrl && !alt:
            case Key.D7 when ctrl && shift && !alt:
                ShortcutsSheet.Show(_model);
                return true;
            case Key.F11 when mods == KeyModifiers.None:
                if (TopLevel.GetTopLevel(this) is not MainWindow window) return false;
                window.ToggleFullScreen();
                return true;
            case Key.S when ctrl && alt && !shift && !TextFieldFocused:
                ToggleSidebar();
                return true;
            case Key.Z when ctrl && !alt && !TextFieldFocused:
                return shift ? _model.Redo() : _model.Undo();
            case Key.Y when ctrl && !alt && !shift && !TextFieldFocused:
                return _model.Redo();
        }
        return false;
    }

    void OnTextInputTunnel(object? sender, TextInputEventArgs e)
    {
        if (_model.Prompt is not null)
        {
            // Typing reaches only a text field in the prompt (a form sheet), never the screen behind it.
            if (e.Source is Visual target && _promptLayer.IsVisualAncestorOf(target)) return;
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
        // On a study screen the set's commands work too (Mac: the Lernset menu); the screen's own keys came first.
        if (editing || _model.CurrentSetId is not { } setId) return false;
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
                // Already there: nothing to do (a new request would restart the screen).
                if (_model.Route is Route.Study { Request: var r } && r.SetId == setId && r.Mode == mode) return true;
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
