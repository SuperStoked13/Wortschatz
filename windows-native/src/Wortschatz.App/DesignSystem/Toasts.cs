using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// The toasts of the window (Mac: ToastOverlay / ToastCapsule in Toasts.swift): glass capsules stacked at the bottom,
/// each with its tone's symbol, the message, an optional action ("Rückgängig") and, when it stays until closed, a
/// close button. A toast rises in on a curve that lands exactly (no scaling, so text and glass stay crisp) and leaves
/// quicker; its timer pauses while the pointer is over it (at least 0.8 s are left afterwards, like the web app).
/// Above a study screen's floating action bar (BottomClearance), else at the usual margin.
/// </summary>
public sealed class ToastOverlay : StackPanel
{
    readonly AppModel _model;
    readonly Dictionary<Guid, Entry> _entries = [];

    sealed class Entry(Control view, DispatcherTimer? timer, TimeSpan remaining, DateTime deadline)
    {
        public Control View = view;
        public DispatcherTimer? Timer = timer;
        public TimeSpan Remaining = remaining;
        public DateTime Deadline = deadline;
    }

    public ToastOverlay(AppModel model)
    {
        _model = model;
        Spacing = 8;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Bottom;
        Margin = new Thickness(20, 0, 20, 24);
        model.ToastShown += Show;
        model.ToastDismissed += Remove;
        foreach (var t in model.Toasts) Show(t);
        if (AppDevice.IsPhone) LayoutUpdated += (_, _) => { if (Children.Count > 0) FitAboveBar(); };
    }

    double _clearance = 24;

    /// <summary>Room at the bottom for a floating bar (the study screens' action bar).</summary>
    public double BottomClearance
    {
        set
        {
            _clearance = Math.Max(24, value);
            Margin = new Thickness(20, 0, 20, _clearance);
        }
    }

    /// <summary>
    /// Phone: right above the study screen's action bar, however many lines it has now (one button, or the feedback
    /// over two) – a fixed room lay over the fourth answer when the bar was low, and on the bar when it was high.
    /// </summary>
    void FitAboveBar()
    {
        double bottom = _clearance;
        if (Parent is Visual host && Features.Study.StudyActionBarView.ShownPhoneBar() is { } bar && bar.TranslatePoint(default, host) is { } top)
            bottom = Math.Max(24, host.Bounds.Height - top.Y + 10);
        if (Math.Abs(Margin.Bottom - bottom) > 1) Margin = new Thickness(20, 0, 20, bottom);
    }

    /// <summary>Stops following the model (the window rebuilt its chrome).</summary>
    public void Detach()
    {
        _model.ToastShown -= Show;
        _model.ToastDismissed -= Remove;
        foreach (var e in _entries.Values) e.Timer?.Stop();
    }

    void Show(ToastMessage toast)
    {
        var view = Capsule(toast);
        DispatcherTimer? timer = null;
        var remaining = TimeSpan.FromMilliseconds(toast.DurationMs ?? 0);
        var entry = new Entry(view, null, remaining, DateTime.UtcNow + remaining);
        if (toast.DurationMs is { } ms)
        {
            timer = Timer(toast.Id, TimeSpan.FromMilliseconds(ms));
            entry.Timer = timer;
        }
        _entries[toast.Id] = entry;
        view.PointerEntered += (_, _) => Pause(toast.Id);
        view.PointerExited += (_, _) => Resume(toast.Id);
        Children.Add(view);
        if (Motion.ReduceMotion) Effects.Of(view).Enter(new Placement(Opacity: 0), Curve.EaseOut(0.2));
        else Effects.Of(view).Enter(new Placement(Y: 18, Opacity: 0), Motion.Arrive(0.5));
    }

    DispatcherTimer Timer(Guid id, TimeSpan after)
    {
        var timer = new DispatcherTimer { Interval = after };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            _model.DismissToast(id);
        };
        timer.Start();
        if (_entries.TryGetValue(id, out var e)) e.Deadline = DateTime.UtcNow + after;
        return timer;
    }

    /// <summary>Pointer over the toast: its timer stops.</summary>
    void Pause(Guid id)
    {
        if (!_entries.TryGetValue(id, out var e) || e.Timer is null) return;
        e.Timer.Stop();
        e.Timer = null;
        var left = e.Deadline - DateTime.UtcNow;
        e.Remaining = left < TimeSpan.FromMilliseconds(800) ? TimeSpan.FromMilliseconds(800) : left;
    }

    /// <summary>Pointer left: the timer goes on with what was left.</summary>
    void Resume(Guid id)
    {
        if (!_entries.TryGetValue(id, out var e) || e.Timer is not null || e.Remaining <= TimeSpan.Zero) return;
        e.Timer = Timer(id, e.Remaining);
        e.Deadline = DateTime.UtcNow + e.Remaining;
    }

    void Remove(Guid id)
    {
        if (!_entries.Remove(id, out var e)) return;
        e.Timer?.Stop();
        var view = e.View;
        view.IsHitTestVisible = false;
        var to = Motion.ReduceMotion ? new Placement(Opacity: 0) : new Placement(Y: 8, Opacity: 0);
        Effects.Of(view).Place(to, Motion.ReduceMotion ? Motion.Fade : Motion.Depart(0.2), () => Children.Remove(view));
    }

    Control Capsule(ToastMessage toast)
    {
        var p = WsTheme.P;
        var (icon, color) = toast.Tone switch
        {
            ToastTone.Success => (IconName.CheckCircle, p.Success.Fill),
            ToastTone.Warning => (IconName.Warning, p.Warning.Fill),
            ToastTone.Danger => (IconName.Octagon, p.Failure.Fill),
            ToastTone.Streak => (IconName.Flame, p.Flame),
            _ => (IconName.Info, p.Accent),
        };
        if (toast.Icon is { } own) icon = own;
        var text = Ui.Text(toast.Text, 14, FontWeight.Medium, wrap: TextWrapping.Wrap);
        text.MaxLines = AppDevice.IsPhone ? 3 : 2;
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        if (!AppDevice.IsPhone) text.MaxWidth = 420;
        // Phone: the text takes what the screen leaves (a stack would let it run off the edge).
        Panel row = AppDevice.IsPhone ? new ToastRow { Spacing = 12 } : Ui.H(12);
        var symbol = Icons.Icon(icon, 17, color, 2.2);
        symbol.VerticalAlignment = VerticalAlignment.Center;
        text.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(symbol);
        row.Children.Add(text);
        if (toast.ActionLabel is { } label && toast.Action is { } action)
        {
            var button = Ui.PlainButton(label, () =>
            {
                action();
                _model.DismissToast(toast.Id);
            }, color: p.AccentText, height: 28);
            ((TextBlock)((StackPanel)button.Chrome.Child!).Children[^1]).FontWeight = FontWeight.SemiBold;
            row.Children.Add(button);
        }
        if (toast.DurationMs is null)
        {
            var close = Ui.IconButton(IconName.X, "Schliessen", () => _model.DismissToast(toast.Id), 22, ButtonKind.Plain);
            row.Children.Add(close);
        }
        bool plain = toast.ActionLabel is null && toast.DurationMs is not null;
        var capsule = Ui.Glass(row, 999, new Thickness(16, 10, plain ? 20 : 12, 10), strong: true);
        // Denser than the panels: the Mac's toast glass blurs what lies under it, ours does not.
        capsule.Background = WsTheme.B(p.Dark ? Palette.Hex(0x2E3142, 0.95) : Palette.Hex(0xFFFFFF, 0.93));
        capsule.MaxWidth = 520;
        capsule.HorizontalAlignment = HorizontalAlignment.Center;
        if (AppDevice.IsPhone)
        {
            capsule.Margin = new Thickness(12, 0);
            capsule.CornerRadius = new CornerRadius(22);
        }
        AutomationProperties.SetName(capsule, toast.ActionLabel is { } a ? $"{toast.Text}. {a} möglich." : toast.Text);
        AutomationProperties.SetLiveSetting(capsule, toast.Tone == ToastTone.Danger ? AutomationLiveSetting.Assertive : AutomationLiveSetting.Polite);
        return capsule;
    }
}

/// <summary>
/// A toast's row on a phone: symbol, text, then any buttons, left to right; the text gets the width the others leave and
/// wraps there (a horizontal stack would give it all it wants and push the rest off the screen).
/// </summary>
sealed class ToastRow : Panel
{
    public double Spacing { get; set; }

    protected override Size MeasureOverride(Size availableSize)
    {
        double fixedWidth = 0, height = 0;
        TextBlock? text = null;
        foreach (var child in Children)
        {
            if (child is TextBlock t && text is null) { text = t; continue; }
            child.Measure(new Size(double.PositiveInfinity, availableSize.Height));
            fixedWidth += child.DesiredSize.Width;
            height = Math.Max(height, child.DesiredSize.Height);
        }
        double spacing = Spacing * Math.Max(0, Children.Count - 1);
        double room = double.IsInfinity(availableSize.Width) ? double.PositiveInfinity : Math.Max(0, availableSize.Width - fixedWidth - spacing);
        if (text is not null)
        {
            text.Measure(new Size(room, availableSize.Height));
            height = Math.Max(height, text.DesiredSize.Height);
            fixedWidth += text.DesiredSize.Width;
        }
        return new Size(fixedWidth + spacing, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0;
        double others = Children.Where(c => c is not TextBlock).Sum(c => c.DesiredSize.Width) + Spacing * Math.Max(0, Children.Count - 1);
        foreach (var child in Children)
        {
            double width = child is TextBlock ? Math.Max(0, finalSize.Width - others) : child.DesiredSize.Width;
            double y = (finalSize.Height - child.DesiredSize.Height) / 2;
            child.Arrange(new Rect(x, Math.Max(0, y), width, child.DesiredSize.Height));
            x += width + Spacing;
        }
        return finalSize;
    }
}
