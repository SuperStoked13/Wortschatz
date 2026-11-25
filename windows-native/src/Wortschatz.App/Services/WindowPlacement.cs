using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// Keeps the main window usable when the screens change while the app runs (GitHub issue #5: external monitor
/// unplugged, the window stayed at the other monitor's scaling and was cut off on the laptop screen).
///
/// When a monitor goes away, Windows moves the window and sends WM_DPICHANGED with the old size scaled by the DPI ratio,
/// often before it has told anyone the screens changed (WM_DISPLAYCHANGE comes later), so the window can be larger
/// than the remaining screen, partly off it, or (if no DPI message came at all) still drawn at the old scaling. A
/// moment after any screen or scaling change this checks, with fresh numbers from Windows (not Avalonia's cached
/// screens):
/// 1. the window's scaling matches its monitor's; if not, it passes the monitor's DPI on as Windows would have;
/// 2. a maximised window has its monitor's size, else it is maximised again on this monitor;
/// 3. a normal window lies wholly on screens (spread over two is fine); else it is moved, and shrunk if it is larger,
///    into the working area of the monitor it is on (rules in <see cref="WindowFit"/>).
/// It never moves the window while a mouse button is down (the user may be dragging it). Windows only; elsewhere it
/// does nothing.
/// </summary>
sealed class WindowPlacement
{
    readonly Window _window;
    readonly double _usualMinWidth;
    readonly double _usualMinHeight;
    int _waitedForMouse;

    public WindowPlacement(Window window)
    {
        _window = window;
        _usualMinWidth = window.MinWidth;
        _usualMinHeight = window.MinHeight;
        if (!OperatingSystem.IsWindows()) return;
        window.Screens.Changed += (_, _) => CheckSoon();
        window.ScalingChanged += (_, _) => CheckSoon();
        window.Opened += (_, _) => CheckSoon();
    }

    /// <summary>
    /// Checks the window twice: a moment after the change, and again when Windows has surely finished rearranging
    /// (WM_DPICHANGED, moves and WM_DISPLAYCHANGE come in no fixed order). Both checks change nothing when all is right.
    /// </summary>
    public void CheckSoon()
    {
        if (!OperatingSystem.IsWindows()) return;
        DispatcherTimer.RunOnce(Check, TimeSpan.FromMilliseconds(400));
        DispatcherTimer.RunOnce(Check, TimeSpan.FromMilliseconds(1600));
    }

    void Check()
    {
        try { CheckNow(); }
        catch (Exception e) { Trace.WriteLine($"WindowPlacement: {e}"); }
    }

    void CheckNow()
    {
        if (!_window.IsVisible || _window.WindowState == WindowState.Minimized) return;
        if (_window.TryGetPlatformHandle()?.Handle is not { } hwnd || hwnd == IntPtr.Zero) return;
        if (MouseButtonDown())
        {
            // Dragging or resizing: look again once the button is up (give up after a minute).
            if (++_waitedForMouse < 120) DispatcherTimer.RunOnce(Check, TimeSpan.FromMilliseconds(500));
            return;
        }
        _waitedForMouse = 0;

        var monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (monitor == IntPtr.Zero || !TryMonitorInfo(monitor, out var monitorBox, out var workArea)) return;

        // 1. Scaling: Avalonia only learns a new DPI from WM_DPICHANGED; pass it on if Windows did not send one.
        double scaling = _window.RenderScaling;
        if (GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out uint dpi, out _) == 0 && dpi > 0)
        {
            double monitorScaling = dpi / 96.0;
            if (Math.Abs(monitorScaling - scaling) > 0.01 && GetWindowRect(hwnd, out var outer))
            {
                double ratio = monitorScaling / scaling;
                var suggested = new RECT
                {
                    left = outer.left,
                    top = outer.top,
                    right = outer.left + (int)Math.Round((outer.right - outer.left) * ratio),
                    bottom = outer.top + (int)Math.Round((outer.bottom - outer.top) * ratio),
                };
                Trace.WriteLine($"WindowPlacement: scaling {scaling} → {monitorScaling}");
                SendMessage(hwnd, WM_DPICHANGED, (IntPtr)(dpi | (dpi << 16)), ref suggested);
                scaling = _window.RenderScaling;
            }
        }

        // The smallest window must fit this screen (a small screen at a high scaling).
        var (minWidth, minHeight) = WindowFit.MinimumSize(_usualMinWidth, _usualMinHeight, workArea.Width / scaling, workArea.Height / scaling);
        _window.MinWidth = minWidth;
        _window.MinHeight = minHeight;

        if (!GetWindowRect(hwnd, out var rect)) return;
        var outerBox = ToBox(rect);
        // What one sees of the window, without the invisible resize border Windows adds around it.
        var visible = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT frame, Marshal.SizeOf<RECT>()) == 0
            ? ToBox(frame) : outerBox;

        switch (_window.WindowState)
        {
            case WindowState.Maximized:
                // 2. Maximised on the other monitor and only scaled: maximise again here.
                if (WindowFit.MaximizedOverflows(visible, monitorBox, (int)Math.Ceiling(16 * scaling)))
                {
                    Trace.WriteLine("WindowPlacement: maximising again on this screen");
                    _window.WindowState = WindowState.Normal;
                    _window.WindowState = WindowState.Maximized;
                }
                return;
            case WindowState.Normal:
                break;
            default:
                return;
        }

        // 3. A normal window: wholly on screens, else into this monitor's working area.
        if (WindowFit.IsCovered(visible, WorkingAreas())) return;
        var fitted = WindowFit.FitInto(visible, workArea);
        int shrinkWidth = visible.Width - fitted.Width, shrinkHeight = visible.Height - fitted.Height;
        Trace.WriteLine($"WindowPlacement: {visible} → {fitted}");
        if (shrinkWidth > 0) _window.Width = Math.Max(_window.MinWidth, _window.ClientSize.Width - shrinkWidth / scaling);
        if (shrinkHeight > 0) _window.Height = Math.Max(_window.MinHeight, _window.ClientSize.Height - shrinkHeight / scaling);
        _window.Position = new PixelPoint(outerBox.X + fitted.X - visible.X, outerBox.Y + fitted.Y - visible.Y);
    }

    /// <summary>The window's size and place from the last session, made to fit a screen before the window shows.</summary>
    public static (double Width, double Height) FitStartSize(Window window, PixelPoint place, double width, double height)
    {
        var screen = window.Screens.All.FirstOrDefault(sc => sc.WorkingArea.Contains(place + new PixelPoint(40, 20)))
            ?? window.Screens.Primary ?? window.Screens.All.FirstOrDefault();
        if (screen is null || screen.Scaling <= 0) return (width, height);
        double areaWidth = screen.WorkingArea.Width / screen.Scaling, areaHeight = screen.WorkingArea.Height / screen.Scaling;
        // A little room for the window's border and shadow.
        return (Math.Min(width, areaWidth - 16), Math.Min(height, areaHeight - 16));
    }

    static List<PixelBox> WorkingAreas()
    {
        var areas = new List<PixelBox>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, _, _, _) =>
        {
            if (TryMonitorInfo(monitor, out _, out var work)) areas.Add(work);
            return true;
        }, IntPtr.Zero);
        return areas;
    }

    static bool TryMonitorInfo(IntPtr monitor, out PixelBox bounds, out PixelBox workArea)
    {
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        bool ok = GetMonitorInfo(monitor, ref info);
        bounds = ToBox(info.rcMonitor);
        workArea = ToBox(info.rcWork);
        return ok && workArea.Area > 0;
    }

    static bool MouseButtonDown() => (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0 || (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;

    static PixelBox ToBox(RECT r) => new(r.left, r.top, r.right - r.left, r.bottom - r.top);

    // MARK: Win32

    const uint MONITOR_DEFAULTTONEAREST = 2;
    const int MDT_EFFECTIVE_DPI = 0;
    const uint WM_DPICHANGED = 0x02E0;
    const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    const int VK_LBUTTON = 0x01;
    const int VK_RBUTTON = 0x02;

    [StructLayout(LayoutKind.Sequential)]
    struct RECT
    {
        public int left, top, right, bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, ref RECT lParam);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
}
