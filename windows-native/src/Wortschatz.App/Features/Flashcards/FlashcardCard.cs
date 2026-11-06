using System.Globalization;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Automation.Peers;
using Avalonia.Automation.Provider;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Flashcards;

// The flashcard itself (Karteikarten), port of mac/Wortschatz/Features/Flashcards/FlashcardCard.swift: a large card that
// turns over in 3D, with two card edges peeking out below it as the stack.
//
// - Turning over: the card lifts toward you and turns around a nearly horizontal axis, always the same way round (like a
//   card you keep turning over), once, and stops flat (no swing past flat). A streak of light rises across it while it
//   turns and fades out just as it lands. Meanwhile the cards of the stack behind it come into view at their full size,
//   and are back under it once it has landed.
// - Sorting: the verdict lands on the card (it floods green or amber from the side it is going to, a seal settles in
//   behind the text and sends out a ring), then the card glides off to that side, leaning a little and fading, while
//   the next card rises from the stack.
// - "Zurück": a card still in flight glides back along its own path; a card that is gone slides back in from its side,
//   and the current card sinks back under the stack.
// - Swiping (FlashcardSwipe): the card follows two fingers on the touchpad or the mouse sideways, on the same glide as a
//   sorted card (leaning, a little smaller, but not fading), and takes on the colour of the side it is heading for. Past
//   the threshold the verdict's seal settles on it; let go there (or flung) it flies off from where it is, else it
//   springs back.
//
// Glass: on the Mac, Liquid Glass cannot be turned, so a "crystal" stand-in takes over while the card moves. The
// Windows glass is drawn by the app itself and turns with the card, so each side simply carries its own glass.
// Smoothness: every frame of a turn or a glide only recomputes transforms (FaceTurn, GlideEffect); the card's content
// is built once. Reduce Motion: the sides cross-fade, cards fade in and out, nothing turns or glides.

/// <summary>Timings and distances of the card (Mac: FlashcardMotion).</summary>
public static class FlashcardMotion
{
    // MARK: Turning over

    /// <summary>A firm start, through the edge at speed, then it slows down and stops exactly flat.</summary>
    public static Curve Flip => Curve.Bezier(0.36, 0, 0.2, 1, 0.62);
    /// <summary>How much the card grows toward you at the middle of a turn, and how far it rises.</summary>
    public const double FlipLift = 0.045;
    public const double FlipRise = 10;
    /// <summary>The turning axis leans a little off the horizontal, as if the card were turned by hand.</summary>
    public const double FlipAxisLean = 0.12;
    public const double FlipPerspective = 0.45;

    // MARK: Sorting

    /// <summary>The verdict's colour coming onto the card.</summary>
    public static Curve Tint => Curve.EaseOut(0.16);
    /// <summary>The seal settling in behind the text, and the ring it sends out.</summary>
    public static Curve Seal => Motion.Arrive(0.32);
    public static Curve Ripple => Curve.EaseOut(0.6);
    /// <summary>The glide: a beat for the verdict, then the card gathers pace evenly and is gone.</summary>
    public static Curve Glide => Curve.Bezier(0.42, 0, 0.72, 0.72, 0.5).Delayed(0.06);
    /// <summary>A swiped card let go past the threshold: it flies off at once and slows down as it fades.</summary>
    public static Curve Fling => Curve.Bezier(0.2, 0.55, 0.35, 1, 0.42);
    /// <summary>A swiped card let go before the threshold: back to the middle, landing softly and exactly.</summary>
    public static Curve SnapBack => Curve.Bezier(0.2, 0.9, 0.3, 1, 0.36);
    /// <summary>How far a sorted card glides sideways and drops, how much it leans and how much smaller it gets.</summary>
    public const double GlideDistance = 280;
    public const double GlideDrop = 24;
    public const double GlideLean = 6;
    public const double GlideShrink = 0.06;
    /// <summary>The current card going back under the stack ("Zurück").</summary>
    public static Curve Sink => Motion.Depart(0.3);
    /// <summary>How far to the side a card that was gone comes back from ("Zurück").</summary>
    public const double ReturnDistance = 140;

    // MARK: Arriving

    /// <summary>The next card rising from the stack, a card coming back: quick out of the gate, a long soft landing.</summary>
    public const double ArriveDuration = 0.48;
    public static Curve Arrive => Motion.Arrive(ArriveDuration);
    /// <summary>How far the next card rises from the stack, and how small it starts.</summary>
    public const double RiseDistance = 16;
    public const double RiseScale = 0.965;

    // MARK: The turn, frame by frame

    /// <summary>
    /// Where in its turn the card is at <paramref name="angle"/> (180° per half-turn): which side is up, its tilt (a side
    /// going away tilts from 0° to 90°, the next one comes up from -90° to 0°), how far it is lifted (0 flat … 1
    /// edge-on), and the streak of light (strength, and its position in units of the card's height).
    /// </summary>
    public static (bool ShowsBack, double Tilt, double Lift, double Sheen, double SheenPosition) Turn(double angle)
    {
        double remainder = angle % 360;
        double turned = remainder < 0 ? remainder + 360 : remainder;
        bool showsBack = turned > 90 && turned <= 270;
        double tilt = showsBack ? turned - 180 : (turned > 270 ? turned - 360 : turned);
        double lift = Math.Sin(Math.Min(1, Math.Abs(tilt) / 90) * Math.PI / 2);
        // Through this half-turn: 0 at its start, 0.5 edge-on, 1 at its end.
        double through = tilt >= 0 ? tilt / 180 : 1 + tilt / 180;
        return (showsBack, tilt, lift, Math.Abs(Math.Sin(tilt * Math.PI / 180)), 0.9 - 0.8 * through);
    }

    /// <summary>
    /// How much of the stack behind the card shows while it turns at <paramref name="angle"/>: none at rest, all of it
    /// from about 40° on. A swiped card uncovers it too (swipe: 0 … 1 at the threshold). turning: 1 while the card that
    /// turns is the one on the deck.
    /// </summary>
    public static double StackReveal(double angle, double swipe = 0, double turning = 1)
    {
        double reveal = Math.Min(1, Math.Max(Turn(angle).Lift * 1.6 * Motion.Clamp01(turning), swipe * 1.2));
        return reveal * reveal * (3 - 2 * reveal);
    }
}

/// <summary>Sizes of the card and the stack under it (Mac: FlashcardMetrics).</summary>
public static class FlashcardMetrics
{
    /// <summary>How far each card edge of the stack peeks out below the one above it.</summary>
    public const double PeekDrop = 9;
    /// <summary>How much narrower each card edge is, on either side, than the one above it.</summary>
    public const double PeekInset = 18;
    /// <summary>Room below the card for the peeking edges.</summary>
    public const double StackDepth = PeekDrop * 2;
    public const double CornerRadius = 30;

    /// <summary>The card's height for the room the stage has: an index-card shape, between 240 and 440.</summary>
    public static double CardHeight(double width, double availableHeight) => AppDevice.IsPhone
        // Phone: an upright card down to the thumb (one hand), as high as the screen allows.
        ? Math.Max(240, Math.Min(availableHeight, width * 1.45))
        : Math.Max(240, Math.Min(440, Math.Min(width * 0.58, availableHeight)));

    /// <summary>The card edge <paramref name="level"/> steps below the card: drop, inset on each side, opacity.</summary>
    public static (double Drop, double Inset, double Opacity) Edge(int level)
    {
        double depth = level + 1;
        return (PeekDrop * depth, PeekInset * depth, level == 0 ? 1 : 0.62);
    }
}

/// <summary>Colour, symbol, title and direction of a verdict.</summary>
public static class FlashcardVerdictStyle
{
    public static StatusPalette Palette(this FlashcardVerdict v) => v == FlashcardVerdict.Know ? WsTheme.P.Success : WsTheme.P.Learning;
    public static IconName Icon(this FlashcardVerdict v) => v == FlashcardVerdict.Know ? IconName.Check : IconName.Repeat;
    public static string Title(this FlashcardVerdict v) => v == FlashcardVerdict.Know ? "Weiss ich" : "Lerne ich noch";
    /// <summary>Sideways direction of the sorted card: "Weiss ich" to the right, "Lerne ich noch" to the left.</summary>
    public static double Direction(this FlashcardVerdict v) => v == FlashcardVerdict.Know ? 1 : -1;
}

// MARK: - A side

/// <summary>
/// One side of a card (Mac: FlashcardFace plus the parts of FaceTurn drawn on it): its glass, the swipe's colour, the
/// verdict (flood and seal) under the text, the language at the top with the tools, the text large in the middle, the
/// flip hint at the bottom, and the streak of light over everything.
/// </summary>
public sealed class FlashcardFace : Grid
{
    static Palette P => WsTheme.P;

    readonly double _width, _height;
    readonly Border _wash;
    readonly Grid _verdictLayer = new() { IsHitTestVisible = false };
    readonly Border _toolsHost = new();
    readonly Border _sheen;
    readonly LinearGradientBrush _sheenBrush;
    FlashcardVerdict? _verdict;
    Control? _verdictView;

    public bool IsBack { get; }

    public FlashcardFace(FlashcardSide side, double width, double height)
    {
        IsBack = side.IsBack;
        // Clicks anywhere on the side turn the card over (FlashcardView), also where nothing is drawn.
        Background = Brushes.Transparent;
        _width = width;
        _height = height;
        Width = width;
        Height = height;
        var radius = new CornerRadius(FlashcardMetrics.CornerRadius);
        Children.Add(Surface(side.IsBack));
        _wash = new Border { CornerRadius = radius, IsHitTestVisible = false, IsVisible = false };
        Children.Add(_wash);
        Children.Add(_verdictLayer);
        Children.Add(Content(side));
        _sheenBrush = new LinearGradientBrush();
        _sheen = new Border { CornerRadius = radius, ClipToBounds = true, Background = _sheenBrush, IsHitTestVisible = false, IsVisible = false };
        Children.Add(_sheen);
    }

    /// <summary>
    /// The side's glass (Mac: FlashcardGlass / FlashcardCrystal): the hero gradient, a little denser than elsewhere so
    /// the next card does not show through a card that turns or leaves over it (the Mac's glass blurs what is behind
    /// it), with a breath of the accent on the back.
    /// </summary>
    static Control Surface(bool isBack)
    {
        var glass = Ui.Hero(new Border(), new Thickness(0), FlashcardMetrics.CornerRadius);
        glass.Background = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(P.Dark ? Palette.Hex(0x30334A, 0.94) : Palette.Hex(0xFFFFFF, 0.88), 0),
                new GradientStop(P.Dark ? Palette.Hex(0x262838, 0.88) : Palette.Hex(0xF7F7FF, 0.76), 1),
            },
        };
        if (isBack) glass.Child = new Border { CornerRadius = new CornerRadius(FlashcardMetrics.CornerRadius - 1), Background = WsTheme.B(Palette.Hex(Ui.Rgb(P.Accent), 0.10)) };
        glass.IsHitTestVisible = false;
        return glass;
    }

    Control Content(FlashcardSide side)
    {
        var grid = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), Margin = new Thickness(28) };
        var label = Ui.Eyebrow(side.Label);
        label.FontSize = 11.5;
        // Phone too: the buttons stay beside the label (Ui.Row put them under it there).
        var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 12, MinHeight = 32 };
        label.VerticalAlignment = VerticalAlignment.Center;
        top.Children.Add(label);
        Grid.SetColumn(_toolsHost, 1);
        top.Children.Add(_toolsHost);
        grid.Children.Add(top);

        Control text;
        if (!string.IsNullOrWhiteSpace(side.Text))
        {
            double maxWidth = _width - 56 - 40;
            double maxHeight = _height - 56 - 32 - 22 - 24;
            var (size, weight) = FitSize(side.Text, side.Lang, maxWidth, maxHeight);
            var block = StudyText.InLang(side.Text, side.Lang, size, weight, P.Text, WsTheme.Prompt);
            block.TextAlignment = TextAlignment.Center;
            block.HorizontalAlignment = HorizontalAlignment.Center;
            block.VerticalAlignment = VerticalAlignment.Center;
            block.MaxWidth = maxWidth;
            block.MaxLines = 7;
            block.TextTrimming = TextTrimming.CharacterEllipsis;
            block.Margin = new Thickness(20, 0);
            AutomationProperties.SetName(block, $"{side.Label}: {side.Text}");
            text = block;
        }
        else
        {
            var empty = Ui.Text("Keine Angabe", 20, FontWeight.Medium, P.TextTertiary);
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            text = empty;
        }
        Grid.SetRow(text, 1);
        grid.Children.Add(text);

        // Phone: no space bar; a tap turns the card.
        var hint = Ui.H(6, Ui.KeyCap("Leertaste"), Ui.Text(AppDevice.IsPhone ? (side.IsBack ? "Antippen: Vorderseite" : "Antippen zum Umdrehen") : side.IsBack ? "Vorderseite" : "Umdrehen", 12, color: P.TextTertiary));
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        hint.Opacity = 0.85;
        Grid.SetRow(hint, 2);
        grid.Children.Add(hint);
        return grid;
    }

    /// <summary>
    /// The text's size (Mac: Typography.flashcard, a little larger than the study prompt, stepping down for sentences),
    /// then shrunk until it fits the card (Mac: minimumScaleFactor 0.55).
    /// </summary>
    static (double Size, FontWeight Weight) FitSize(string text, Lang lang, double maxWidth, double maxHeight)
    {
        var (size, weight) = text.Length switch
        {
            // Semibold in the rounded font like the Mac (medium for long sentences).
            < 24 => (46.0, FontWeight.SemiBold),
            < 60 => (36.0, FontWeight.SemiBold),
            < 140 => (28.0, FontWeight.SemiBold),
            _ => (22.0, FontWeight.Medium),
        };
        var typeface = new Typeface(WsTheme.Prompt, FontStyle.Normal, weight);
        double min = size * 0.55;
        for (double s = size; s >= min; s -= 2)
        {
            var formatted = new FormattedText(text, CultureInfo.CurrentCulture, lang.IsRTL() ? FlowDirection.RightToLeft : FlowDirection.LeftToRight,
                typeface, s, Brushes.Black) { MaxTextWidth = Math.Max(40, maxWidth), TextAlignment = TextAlignment.Center };
            if (formatted.Height <= maxHeight) return (s, weight);
        }
        return (min, weight);
    }

    /// <summary>🔊 ★ ✎ in the card's corner (built by FlashcardView).</summary>
    public void SetTools(Control tools) => _toolsHost.Child = tools;

    /// <summary>The swipe's colour, growing with the swipe (lean: -1 Lerne ich noch … 1 Weiss ich), strongest on that side.</summary>
    public void SetWash(double lean)
    {
        if (Math.Abs(lean) <= 0.004)
        {
            _wash.IsVisible = false;
            return;
        }
        var verdict = lean >= 0 ? FlashcardVerdict.Know : FlashcardVerdict.StillLearning;
        double strength = Math.Min(1, Math.Abs(lean));
        _wash.IsVisible = true;
        _wash.Background = SideGradient(verdict, 0.34 * strength, 0.08 * strength);
    }

    /// <summary>The streak of light (strength 0 … 1, position in units of the card's height).</summary>
    public void SetSheen(double strength, double position)
    {
        if (strength <= 0.001)
        {
            _sheen.IsVisible = false;
            return;
        }
        double core = P.Dark ? 0.44 : 0.26;
        Color White(double a) => Color.FromArgb((byte)Math.Round(Math.Clamp(a, 0, 1) * 255), 255, 255, 255);
        _sheenBrush.StartPoint = new RelativePoint(0.3, position - 0.5, RelativeUnit.Relative);
        _sheenBrush.EndPoint = new RelativePoint(0.7, position + 0.5, RelativeUnit.Relative);
        if (_sheenBrush.GradientStops.Count == 0)
        {
            foreach (var (a, at) in new[] { (0.0, 0.24), (core * 0.27, 0.4), (core, 0.5), (core * 0.27, 0.6), (0.0, 0.76) })
                _sheenBrush.GradientStops.Add(new GradientStop(White(a), at));
        }
        _sheen.Opacity = strength;
        _sheen.IsVisible = true;
    }

    /// <summary>
    /// The verdict lands on the card (Mac: VerdictFlood + VerdictSeal): it floods green or amber, the seal settles in
    /// from a little larger and clear, and a ring spreads from it. nil: they fade away.
    /// </summary>
    public void SetVerdict(FlashcardVerdict? verdict, bool animated = true)
    {
        if (verdict == _verdict) return;
        _verdict = verdict;
        if (_verdictView is { } old)
        {
            _verdictView = null;
            if (animated)
            {
                Effects.Of(old).Place(new Placement(Opacity: 0), FlashcardMotion.Tint, () => _verdictLayer.Children.Remove(old));
                Effects.Of(old.FindDescendantSeal()).Place(new Placement(Scale: 1.18, Opacity: 0), FlashcardMotion.Seal);
            }
            else _verdictLayer.Children.Remove(old);
        }
        if (verdict is not { } v) return;
        var view = VerdictView(v, animated);
        _verdictView = view;
        _verdictLayer.Children.Add(view);
    }

    Control VerdictView(FlashcardVerdict verdict, bool animated)
    {
        var palette = verdict.Palette();
        var layer = new Grid { IsHitTestVisible = false };
        // The flood: strongest on the side the card is going to, with a rim in the same colour.
        layer.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(FlashcardMetrics.CornerRadius),
            Background = SideGradient(verdict, 0.36, 0.12),
            BorderBrush = WsTheme.B(Palette.Hex(Ui.Rgb(palette.Fill), 0.75)),
            BorderThickness = new Thickness(2),
        });
        // The seal: the verdict's symbol in a ring, large and translucent, with a second ring spreading from it.
        var seal = new Grid { Width = 150, Height = 150, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Name = "seal" };
        var ripple = new Border { CornerRadius = new CornerRadius(75), BorderThickness = new Thickness(2), BorderBrush = WsTheme.B(palette.Fill), Opacity = 0.45 };
        seal.Children.Add(ripple);
        seal.Children.Add(new Border { CornerRadius = new CornerRadius(75), BorderThickness = new Thickness(5), BorderBrush = WsTheme.B(Palette.Hex(Ui.Rgb(palette.Fill), 0.42)) });
        var icon = Icons.Icon(verdict.Icon(), 76, Palette.Hex(Ui.Rgb(palette.Fill), 0.42), 3);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        seal.Children.Add(icon);
        layer.Children.Add(seal);
        if (animated)
        {
            Effects.Of(layer).Enter(new Placement(Opacity: 0), FlashcardMotion.Tint);
            if (Motion.ReduceMotion) ripple.Opacity = 0;
            else
            {
                Effects.Of(seal).Enter(new Placement(Scale: 1.18, Opacity: 0), FlashcardMotion.Seal);
                Effects.Of(ripple).Place(new Placement(Scale: 1.7, Opacity: 0), FlashcardMotion.Ripple.Delayed(0.04));
            }
        }
        else ripple.Opacity = 0;
        return layer;
    }

    /// <summary>The verdict's colour from the side the card goes to (strong) to the other side (weak).</summary>
    static LinearGradientBrush SideGradient(FlashcardVerdict verdict, double toward, double away)
    {
        var fill = Ui.Rgb(verdict.Palette().Fill);
        bool right = verdict == FlashcardVerdict.Know;
        return new LinearGradientBrush
        {
            StartPoint = new RelativePoint(right ? 1 : 0, 0.5, RelativeUnit.Relative),
            EndPoint = new RelativePoint(right ? 0 : 1, 0.5, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Palette.Hex(fill, toward), 0), new GradientStop(Palette.Hex(fill, away), 1) },
        };
    }
}

static class SealLookup
{
    /// <summary>The seal inside a verdict layer (it shrinks back while the flood fades).</summary>
    public static Control FindDescendantSeal(this Control layer) =>
        layer is Panel panel ? panel.Children.FirstOrDefault(c => c.Name == "seal") ?? layer : layer;
}

// MARK: - The card

/// <summary>
/// A card of the deck (Mac: FlashcardView): both sides in one card that turns over when the deck's side changes. The
/// current card turns over on a click (or Space, Enter, ↑↓), follows a mouse drag sideways and has the tools 🔊 ★ ✎ in its
/// corner. A card that is leaving is the same view on its way out: sorted, the verdict lands on it and it glides off to
/// its side; going back under the stack ("Zurück"), it sinks and fades.
/// </summary>
public sealed class FlashcardView : Panel
{
    readonly FlashcardsController _c;
    readonly double _width, _height;
    readonly Panel _glideLayer = new();
    readonly FlashcardFace _front, _back;
    readonly AnimatedValue _angle;
    readonly AnimatedValue _glide = new();
    readonly AnimatedValue _fades = new(1);
    readonly AnimatedValue _crossFade;
    int _turns;
    bool _isFlipped;
    double _lastDirection = 1;
    FlashcardDepartureKind? _leaving;
    bool _starred, _speaking, _toolsBuilt;
    // Pointer: a press that moves at least 6 points is a drag, else a click (turn over).
    Point? _pressAt;
    bool _dragging;

    public Card Card { get; private set; }
    public string EntryId { get; }
    public bool IsCurrent => _leaving is null;

    public FlashcardView(FlashcardsController controller, Card card, string entryId, bool isFlipped, double width, double height)
    {
        _c = controller;
        Card = card;
        EntryId = entryId;
        _width = width;
        _height = height;
        _isFlipped = isFlipped;
        _turns = isFlipped ? 1 : 0;
        _angle = new AnimatedValue(_turns * 180);
        _crossFade = new AnimatedValue(isFlipped ? 1 : 0);
        Width = width;
        Height = height;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Top;
        // Placement (rise from the stack, sink back) scales from the card's bottom edge.
        RenderTransformOrigin = new RelativePoint(0.5, 1, RelativeUnit.Relative);
        _front = new FlashcardFace(controller.SideOf(card, false), width, height);
        _back = new FlashcardFace(controller.SideOf(card, true), width, height);
        _glideLayer.Children.Add(_front);
        _glideLayer.Children.Add(_back);
        Children.Add(_glideLayer);
        Cursor = new Cursor(StandardCursorType.Hand);
        AutomationProperties.SetName(this, "Karteikarte");
        UpdateAccessibility();
        _angle.Changed += ApplyTurn;
        _crossFade.Changed += ApplyTurn;
        _glide.Changed += ApplyGlide;
        _fades.Changed += ApplyGlide;
        BuildTools();
        ApplyTurn();
        ApplyGlide();
    }

    FlashcardVerdict? Verdict => _leaving is FlashcardDepartureKind.Sorted s ? s.Verdict : null;

    bool IsSwiped => IsCurrent && _c.Swipe.CardID == Card.Id;

    /// <summary>The verdict on the card: sorted, or about to be if let go now.</summary>
    FlashcardVerdict? ShownVerdict => Verdict ?? (IsSwiped ? _c.Swipe.Armed : null);

    // MARK: Updates from the deck

    /// <summary>The deck changed: the card's side, whether it is leaving, its tools.</summary>
    public void Update(Card card, bool isFlipped, FlashcardDepartureKind? leaving, bool flung, double releaseOffset)
    {
        Card = card;
        if (isFlipped != _isFlipped)
        {
            _isFlipped = isFlipped;
            TurnOver(isFlipped);
        }
        if (leaving != _leaving)
        {
            var old = _leaving;
            _leaving = leaving;
            Depart(old, leaving, flung, releaseOffset);
        }
        IsHitTestVisible = IsCurrent;
        UpdateAccessibility();
        BuildTools();
        UpdateVerdict();
    }

    // MARK: Accessibility

    /// <summary>
    /// The screen reader's action on the card: "Umdrehen", or "Vorderseite zeigen" on its back (Mac:
    /// accessibilityAction(named:)); a card that is leaving is hidden from it (Mac: accessibilityHidden).
    /// </summary>
    void UpdateAccessibility()
    {
        AutomationProperties.SetHelpText(this, _isFlipped ? "Vorderseite zeigen" : "Umdrehen");
        AutomationProperties.SetAccessibilityView(this, IsCurrent ? AccessibilityView.Default : AccessibilityView.Raw);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new FlashcardViewPeer(this);

    /// <summary>The card as a button for the screen reader: invoking it turns the card over.</summary>
    sealed class FlashcardViewPeer(FlashcardView owner) : ControlAutomationPeer(owner), IInvokeProvider
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;

        public void Invoke()
        {
            if (owner.IsCurrent) owner._c.Flip();
        }
    }

    /// <summary>The swipe moved this (current) card.</summary>
    public void SwipeMoved()
    {
        ApplyGlide();
        var up = _isFlipped ? _back : _front;
        up.SetWash(IsSwiped ? _c.Swipe.Lean : 0);
    }

    public void UpdateVerdict()
    {
        var verdict = ShownVerdict;
        _front.SetVerdict(verdict);
        _back.SetVerdict(verdict);
        if (verdict is { } v) _lastDirection = v.Direction();
    }

    /// <summary>One more half-turn, so that the side <paramref name="showingBack"/> asks for is up.</summary>
    void TurnOver(bool showingBack)
    {
        if (Motion.ReduceMotion)
        {
            _crossFade.Set(showingBack ? 1 : 0, Curve.EaseInOut(0.2));
            _turns = showingBack ? 1 : 0;
            _angle.Jump(_turns * 180);
            return;
        }
        int next = _turns + 1;
        if ((next % 2 == 0) == showingBack) next++;
        _turns = next;
        _angle.Set(next * 180, FlashcardMotion.Flip);
        _crossFade.Jump(showingBack ? 1 : 0);
    }

    /// <summary>
    /// Leaving (sorted: the glide; back to the stack: sinking) or coming back ("Zurück" while it was still in flight:
    /// it glides back along its path).
    /// </summary>
    void Depart(FlashcardDepartureKind? old, FlashcardDepartureKind? leaving, bool flung, double releaseOffset)
    {
        var placement = Effects.Of(this);
        switch (leaving)
        {
            case null:
                // Called back: lands softly where it belongs.
                _glide.Set(0, Motion.ReduceMotion ? Motion.Fade : FlashcardMotion.Arrive);
                _fades.Set(1, null);
                placement.Place(Placement.Identity, Motion.ReduceMotion ? Motion.Fade : FlashcardMotion.Arrive);
                break;
            case FlashcardDepartureKind.Sorted sorted:
                _lastDirection = sorted.Verdict.Direction();
                if (Motion.ReduceMotion)
                {
                    placement.Place(new Placement(Opacity: 0), Motion.Fade);
                    break;
                }
                // It leaves from where the swipe let it go (the swipe itself is already reset).
                _glide.Jump(releaseOffset / FlashcardMotion.GlideDistance);
                _fades.Jump(flung ? 0 : 1);
                var curve = flung ? FlashcardMotion.Fling : FlashcardMotion.Glide;
                _glide.Set(sorted.Verdict.Direction(), curve);
                _fades.Set(1, curve);
                break;
            case FlashcardDepartureKind.BackToStack:
                placement.Place(Motion.ReduceMotion ? new Placement(Opacity: 0) : new Placement(Y: FlashcardMotion.RiseDistance, Scale: FlashcardMotion.RiseScale, Opacity: 0),
                    Motion.ReduceMotion ? Motion.Fade : FlashcardMotion.Sink);
                break;
        }
        _ = old;
    }

    /// <summary>The entrance of a card that comes on screen anew: up from the stack, or back from its side.</summary>
    public void Arrive(FlashcardArrival arrival)
    {
        var placement = Effects.Of(this);
        if (Motion.ReduceMotion)
        {
            placement.Enter(new Placement(Opacity: 0), Curve.EaseOut(0.2));
            return;
        }
        switch (arrival)
        {
            case FlashcardArrival.FromSide side:
                placement.Enter(new Placement(side.Verdict.Direction() * FlashcardMotion.ReturnDistance, FlashcardMotion.RiseDistance, 0.94, 0), FlashcardMotion.Arrive);
                break;
            default:
                placement.Enter(new Placement(0, FlashcardMotion.RiseDistance, FlashcardMotion.RiseScale, 0), FlashcardMotion.Arrive.Delayed(0.04));
                break;
        }
    }

    // MARK: Frames

    /// <summary>Each side at the turn's angle: shown while it is up, tilted, lifted toward you halfway, with the streak of light (Mac: FaceTurn).</summary>
    void ApplyTurn()
    {
        if (Motion.ReduceMotion)
        {
            _front.IsVisible = _crossFade.Value < 0.999;
            _back.IsVisible = _crossFade.Value > 0.001;
            _front.Opacity = 1 - _crossFade.Value;
            _back.Opacity = _crossFade.Value;
            _front.RenderTransform = null;
            _back.RenderTransform = null;
            return;
        }
        var turn = FlashcardMotion.Turn(_angle.Value);
        var up = turn.ShowsBack ? _back : _front;
        var down = turn.ShowsBack ? _front : _back;
        down.IsVisible = false;
        up.IsVisible = true;
        up.Opacity = 1;
        up.RenderTransform = Math.Abs(turn.Tilt) < 0.01 && turn.Lift < 0.0001
            ? null
            : new MatrixTransform(Matrices.Rotate3D(turn.Tilt, (1, FlashcardMotion.FlipAxisLean, 0), FlashcardMotion.FlipPerspective, _width, _height,
                1 + FlashcardMotion.FlipLift * turn.Lift, 0, -FlashcardMotion.FlipRise * turn.Lift));
        up.SetSheen(turn.Sheen, turn.SheenPosition);
        down.SetSheen(0, 0);
        // The swipe's colour belongs to the side that is up.
        down.SetWash(0);
        up.SetWash(IsSwiped ? _c.Swipe.Lean : 0);
    }

    /// <summary>
    /// The card on its way to its side (offset 0 on the deck … 1 gone to the right, -1 to the left): it glides off,
    /// dropping a little, leaning toward its side and getting smaller, and fades from about a third of the way on
    /// (fades: 0 while a swipe holds it, so it never fades under the fingers). Mac: GlideEffect.
    /// </summary>
    void ApplyGlide()
    {
        double swipeOffset = IsSwiped ? _c.Swipe.Offset : 0;
        if (Motion.ReduceMotion)
        {
            _glideLayer.RenderTransform = swipeOffset == 0 ? null : new MatrixTransform(Matrices.Affine(x: swipeOffset));
            return;
        }
        double offset = _glide.Value + swipeOffset / FlashcardMotion.GlideDistance;
        double fades = IsSwiped && _c.Swipe.IsEngaged ? 0 : _fades.Value;
        double p = Math.Abs(offset);
        double fade = Motion.Clamp01((p - 0.3) / 0.65);
        _glideLayer.RenderTransform = offset == 0
            ? null
            : new MatrixTransform(Matrices.Affine(1 - FlashcardMotion.GlideShrink * p, FlashcardMotion.GlideLean * offset,
                FlashcardMotion.GlideDistance * offset, FlashcardMotion.GlideDrop * p * p));
        _glideLayer.Opacity = 1 - Motion.Clamp01(fades) * fade * fade * (3 - 2 * fade);
    }

    // MARK: Tools

    /// <summary>🔊 ★ ✎ on both sides; only the current card's side that is up takes clicks (Mac: FlashcardTools).</summary>
    void BuildTools()
    {
        bool speaking = IsCurrent && _c.IsSpeaking;
        if (_toolsBuilt && _starred == Card.Starred && _speaking == speaking) return;
        bool starToggled = _toolsBuilt && _starred != Card.Starred;
        _toolsBuilt = true;
        _starred = Card.Starred;
        _speaking = speaking;
        foreach (var face in new[] { _front, _back })
        {
            var p = WsTheme.P;
            var speak = Ui.IconButton(IconName.Speaker, "Vorlesen (Ctrl+R)", _c.SpeakVisibleSide, 32, ButtonKind.Plain, speaking ? p.Accent : p.TextSecondary);
            var star = Ui.IconButton(Card.Starred ? IconName.StarFilled : IconName.Star, Card.Starred ? "Markierung entfernen (Ctrl+D)" : "Markieren (Ctrl+D)",
                _c.ToggleStar, 32, ButtonKind.Plain, Card.Starred ? p.Star : p.TextSecondary);
            var edit = Ui.IconButton(IconName.Pencil, "Karte bearbeiten (Ctrl+E)", () => EditRequested?.Invoke(), 32, ButtonKind.Plain);
            foreach (var b in new[] { speak, star, edit }) b.Focusable = false;
            if (speaking) Pulse(speak);
            if (starToggled) Effects.Pop(star, 1.25);
            face.SetTools(Ui.H(4, speak, star, edit));
        }
    }

    /// <summary>The speaker glows while it reads (Mac: the symbol's variable-colour effect).</summary>
    void Pulse(Control speaker)
    {
        if (Motion.ReduceMotion) return;
        double start = Motion.Now();
        Motion.OnFrames(now =>
        {
            if (!_speaking || speaker.Parent is null) return false;
            speaker.Opacity = 0.55 + 0.45 * (0.5 + 0.5 * Math.Cos((now - start) * Math.PI * 2 / 0.9));
            return true;
        });
    }

    /// <summary>✎ was clicked.</summary>
    public event Action? EditRequested;

    // MARK: Pointer

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!IsCurrent || e.Handled || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _pressAt = e.GetPosition(null);
        _dragging = false;
        e.Pointer.Capture(this);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (_pressAt is not { } start) return;
        var delta = e.GetPosition(null) - start;
        if (!_dragging && Math.Sqrt(delta.X * delta.X + delta.Y * delta.Y) < 6) return;
        _dragging = true;
        _c.Drag(new FlashcardDrag.Changed(delta.X, Motion.Now()));
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (_pressAt is null) return;
        _pressAt = null;
        e.Pointer.Capture(null);
        if (_dragging)
        {
            _dragging = false;
            _c.Drag(new FlashcardDrag.Ended(Motion.Now()));
        }
        else if (IsCurrent) _c.Flip();
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        if (_pressAt is null) return;
        _pressAt = null;
        if (_dragging)
        {
            _dragging = false;
            _c.SwipeCancelled();
        }
    }
}

// MARK: - The stack

/// <summary>
/// The next cards of the stack under the current one (Mac: FlashcardStackPeeks + StackReveal). At rest only their edges
/// peek out below it: under the glass, a whole card would cloud it. While the card turns over (or is swiped aside), the
/// cards come into view at their full size behind it.
/// </summary>
public sealed class FlashcardStackPeeks : Control
{
    readonly double _cardHeight;
    readonly AnimatedValue[] _levels = [new(), new()];
    double _reveal;

    public FlashcardStackPeeks(double cardHeight)
    {
        _cardHeight = cardHeight;
        Height = cardHeight + FlashcardMetrics.StackDepth;
        IsHitTestVisible = false;
        foreach (var l in _levels) l.Changed += InvalidateVisual;
    }

    /// <summary>How many cards wait under the current one (0 … 2), faded in and out.</summary>
    public void SetCount(int count, bool animated)
    {
        for (int level = 0; level < 2; level++)
        {
            double target = level < count ? FlashcardMetrics.Edge(level).Opacity : 0;
            if (Math.Abs(_levels[level].Target - target) > 0.001) _levels[level].Set(target, animated ? Curve.EaseOut(0.3) : null);
        }
    }

    /// <summary>How much of the stack behind the card shows (FlashcardMotion.StackReveal).</summary>
    public void SetReveal(double reveal)
    {
        if (Math.Abs(reveal - _reveal) < 0.0005) return;
        _reveal = reveal;
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        var p = WsTheme.P;
        double width = Bounds.Width;
        var fill = WsTheme.B(Palette.Hex(Ui.Rgb(p.SolidSurface), 0.55));
        var pen = new Pen(WsTheme.B(p.Hairline), 1);
        RoundedRect Shape(int level)
        {
            var edge = FlashcardMetrics.Edge(level);
            return new RoundedRect(new Rect(edge.Inset, edge.Drop, Math.Max(0, width - 2 * edge.Inset), _cardHeight), FlashcardMetrics.CornerRadius);
        }
        void Draw(DrawingContext ctx)
        {
            for (int level = 1; level >= 0; level--)
            {
                double opacity = _levels[level].Value;
                if (opacity <= 0.001) continue;
                using var _ = ctx.PushOpacity(opacity);
                if (level == 1 && _levels[0].Value > 0.001)
                {
                    // A card hides the one behind it, so their tints never add up.
                    var outside = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(new Rect(-50, -50, width + 100, _cardHeight + 120)),
                        new RectangleGeometry(Shape(0).Rect, FlashcardMetrics.CornerRadius, FlashcardMetrics.CornerRadius));
                    using var clip = ctx.PushGeometryClip(outside);
                    ctx.DrawRectangle(fill, pen, Shape(level));
                }
                else ctx.DrawRectangle(fill, pen, Shape(level));
            }
        }
        // Behind the card only as far as its turn or swipe uncovers it; below it always.
        using (context.PushClip(new Rect(-50, _cardHeight, width + 100, FlashcardMetrics.StackDepth + 20))) Draw(context);
        if (_reveal > 0.001)
        {
            using var clip = context.PushClip(new Rect(-50, -50, width + 100, _cardHeight + 50));
            using var opacity = context.PushOpacity(_reveal);
            Draw(context);
        }
    }
}

// MARK: - The deck

/// <summary>
/// The current card on the stack, with the cards still leaving over it (Mac: FlashcardDeckView). Every card is one view
/// for as long as it is on screen (keyed by its id and the deck's round): the current card becomes a leaving one when
/// it is sorted, and turns back into the current one when "Zurück" brings it back in time. A card that comes on screen
/// anew rises from the stack (the next card) or slides back in from its side ("Zurück" after it was gone).
/// </summary>
public sealed class FlashcardDeckView : Panel
{
    readonly FlashcardsController _c;
    readonly double _width, _height;
    readonly FlashcardStackPeeks _stack;
    readonly Dictionary<string, FlashcardView> _views = [];
    /// <summary>180° for every turn of the current card (the stack behind it shows meanwhile).</summary>
    readonly AnimatedValue _stackAngle = new();
    readonly AnimatedValue _turning = new();
    string? _turnCardID;
    (string? CardID, bool IsFlipped) _turnKey;

    public event Action? EditRequested;

    public FlashcardDeckView(FlashcardsController controller, double width, double height)
    {
        _c = controller;
        _width = width;
        _height = height;
        Width = width;
        Height = height + FlashcardMetrics.StackDepth;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Top;
        _stack = new FlashcardStackPeeks(height) { Width = width };
        Children.Add(_stack);
        _stackAngle.Changed += ApplyStack;
        _turning.Changed += ApplyStack;
        _c.Swipe.Moved += OnSwipeMoved;
        _c.Swipe.ArmedChanged += OnArmedChanged;
        _turnKey = (_c.Deck.CurrentCardID, _c.Deck.IsFlipped);
        Update(animated: false);
    }

    /// <summary>Stops following the controller (the screen rebuilt its stage).</summary>
    public void Detach()
    {
        _c.Swipe.Moved -= OnSwipeMoved;
        _c.Swipe.ArmedChanged -= OnArmedChanged;
    }

    record Entry(Card Card, bool ShowsBack, FlashcardDepartureKind? Leaving, bool Flung, double ReleaseOffset, int Generation)
    {
        public string Id => $"{Generation}:{Card.Id}";
    }

    /// <summary>The current card first, the leaving ones over it (latest on top).</summary>
    List<Entry> Entries()
    {
        var entries = new List<Entry>();
        int generation = _c.DeckGeneration;
        if (_c.CurrentCard is { } card) entries.Add(new Entry(card, _c.Deck.IsFlipped, null, false, 0, generation));
        foreach (var d in _c.Departures)
            if (d.Generation != generation || d.Card.Id != _c.Deck.CurrentCardID)
                entries.Add(new Entry(d.Card, d.ShowsBack, d.Kind, d.Flung, d.ReleaseOffset, d.Generation));
        return entries;
    }

    /// <summary>The controller changed: cards come, turn, leave and go.</summary>
    public void Update(bool animated = true)
    {
        var deck = _c.Deck;
        // A turn of the current card: the stack shows behind it, on the card's own curve.
        var key = (deck.CurrentCardID, deck.IsFlipped);
        if (key.CurrentCardID == _turnKey.CardID && key.IsFlipped != _turnKey.IsFlipped && !Motion.ReduceMotion)
        {
            _turnCardID = key.CurrentCardID;
            _stackAngle.Set(_stackAngle.Target + 180, FlashcardMotion.Flip);
        }
        _turnKey = key;
        double turning = deck.CurrentCardID is not null && deck.CurrentCardID == _turnCardID ? 1 : 0;
        if (Math.Abs(_turning.Target - turning) > 0.001) _turning.Set(turning, animated ? FlashcardMotion.Arrive : null);
        _stack.SetCount(Math.Min(2, deck.UpcomingCardIDs.Count), animated);

        var entries = Entries();
        var wanted = entries.Select(e => e.Id).ToHashSet();
        foreach (var gone in _views.Keys.Where(k => !wanted.Contains(k)).ToList())
        {
            Children.Remove(_views[gone]);
            _views.Remove(gone);
        }
        int z = 1;
        foreach (var entry in entries)
        {
            if (!_views.TryGetValue(entry.Id, out var view))
            {
                view = new FlashcardView(_c, entry.Card, entry.Id, entry.ShowsBack, _width, _height);
                view.EditRequested += () => EditRequested?.Invoke();
                _views[entry.Id] = view;
                Children.Add(view);
                view.Update(entry.Card, entry.ShowsBack, entry.Leaving, entry.Flung, entry.ReleaseOffset);
                if (animated && entry.Leaving is null) view.Arrive(_c.Arrival);
            }
            else view.Update(entry.Card, entry.ShowsBack, entry.Leaving, entry.Flung, entry.ReleaseOffset);
            view.ZIndex = z++;
        }
        ApplyStack();
    }

    void OnSwipeMoved()
    {
        foreach (var view in _views.Values)
            if (view.IsCurrent) view.SwipeMoved();
        ApplyStack();
    }

    void OnArmedChanged()
    {
        // A tick when the swipe crosses the threshold to a verdict (Mac: FlashcardSwipe.update).
        if (_c.Swipe.Armed is not null) Services.Haptics.Selection();
        foreach (var view in _views.Values)
            if (view.IsCurrent) view.UpdateVerdict();
    }

    void ApplyStack()
    {
        double swipe = Motion.ReduceMotion ? 0 : Math.Abs(_c.Swipe.Lean);
        _stack.SetReveal(FlashcardMotion.StackReveal(Motion.ReduceMotion ? 0 : _stackAngle.Value, swipe, _turning.Value));
    }
}
