using System.Runtime.CompilerServices;
using Avalonia.Controls;
using Avalonia.Media;

namespace Wortschatz.App.DesignSystem;

// Port of mac/Wortschatz/DesignSystem/Effects.swift (shake, pop, the swap transitions) and of the movement parts of
// StudyEntrance.swift (entranceShift): small motions any control can play. Each control gets one MotionState that
// composes its placement (offset, scale, opacity), the shake and the pop into one RenderTransform, so effects never
// overwrite each other. Under Reduce Motion nothing moves: placements only fade, shake and pop do nothing.

/// <summary>Where a control is drawn relative to its layout slot: moved, scaled (around RenderTransformOrigin) and faded.</summary>
public readonly record struct Placement(double X = 0, double Y = 0, double Scale = 1, double Opacity = 1)
{
    // Not `new()`: a record struct's parameterless constructor ignores the defaults (scale and opacity would be 0).
    public static readonly Placement Identity = new(0, 0, 1, 1);
}

/// <summary>The animated transform of one control (Effects.Of).</summary>
public sealed class MotionState
{
    readonly Control _control;
    readonly AnimatedValue _x = new(), _y = new(), _scale = new(1), _opacity = new(1);
    readonly AnimatedValue _shake = new(), _pop = new(1);
    int _shakeSerial, _popSerial;

    internal MotionState(Control control)
    {
        _control = control;
        foreach (var v in new[] { _x, _y, _scale, _opacity, _shake, _pop }) v.Changed += Apply;
    }

    public Placement Current => new(_x.Value, _y.Value, _scale.Value, _opacity.Value);

    /// <summary>Moves to <paramref name="to"/> along <paramref name="curve"/> (null: at once).</summary>
    public void Place(Placement to, Curve? curve = null, Action? completed = null)
    {
        if (Motion.ReduceMotion && curve is not null)
        {
            // Fade only: something appearing is in place at once; something fading out stays where it is.
            if (to.Opacity >= _opacity.Value)
            {
                _x.Jump(to.X);
                _y.Jump(to.Y);
                _scale.Jump(to.Scale);
            }
            _opacity.Set(to.Opacity, Motion.Fade, completed);
            return;
        }
        _x.Set(to.X, curve);
        _y.Set(to.Y, curve);
        _scale.Set(to.Scale, curve);
        _opacity.Set(to.Opacity, curve, completed);
    }

    /// <summary>Starts at <paramref name="from"/> and moves to the identity (an insertion transition).</summary>
    public void Enter(Placement from, Curve curve, Action? completed = null)
    {
        Place(from);
        Place(Placement.Identity, curve, completed);
    }

    /// <summary>A gentle horizontal shake (Mac: ShakeEffect, wrong answers).</summary>
    public void Shake(double amplitude = 8)
    {
        if (Motion.ReduceMotion) return;
        int serial = ++_shakeSerial;
        (double To, double Duration)[] keys = [(-amplitude, 0.07), (amplitude * 0.85, 0.09), (-amplitude * 0.55, 0.09), (amplitude * 0.3, 0.08), (0, 0.08)];
        void Step(int i)
        {
            if (serial != _shakeSerial || i >= keys.Length) return;
            _shake.Set(keys[i].To, Curve.EaseInOut(keys[i].Duration), () => Step(i + 1));
        }
        Step(0);
    }

    /// <summary>A short scale "pop" (Mac: PopEffect: a number that just went up, a finished badge).</summary>
    public void Pop(double scale = 1.035)
    {
        if (Motion.ReduceMotion) return;
        int serial = ++_popSerial;
        _pop.Set(scale, Curve.SpringDuration(0.14, 0), () =>
        {
            if (serial == _popSerial) _pop.Set(1, Curve.SpringDuration(0.3, 0.2));
        });
    }

    void Apply()
    {
        double scale = _scale.Value * _pop.Value;
        double x = _x.Value + _shake.Value, y = _y.Value;
        _control.RenderTransform = scale == 1 && x == 0 && y == 0 ? null : new MatrixTransform(Matrices.Affine(scale, 0, x, y));
        _control.Opacity = Math.Clamp(_opacity.Value, 0, 1);
    }
}

public static class Effects
{
    static readonly ConditionalWeakTable<Control, MotionState> States = new();

    /// <summary>The motion state of <paramref name="control"/> (created on first use).</summary>
    public static MotionState Of(Control control) => States.GetValue(control, c => new MotionState(c));

    /// <summary>Shakes the control horizontally (Reduce Motion: nothing).</summary>
    public static void Shake(Control control, double amplitude = 8) => Of(control).Shake(amplitude);

    /// <summary>Briefly scales the control up (Reduce Motion: nothing).</summary>
    public static void Pop(Control control, double scale = 1.035) => Of(control).Pop(scale);

    /// <summary>
    /// Content that takes the place of other content in the same spot (Mac: AnyTransition.answerSwap): fades in a
    /// moment after the old content went.
    /// </summary>
    public static void AnswerSwapIn(Control control) =>
        Of(control).Enter(new Placement(Opacity: 0), Curve.EaseOut(0.22).Delayed(0.08));

    /// <summary>
    /// The prompt of the next question (Mac: AnyTransition.promptSwap): glides in from the right a moment later, on the
    /// spring the card moves with. Reduce Motion: AnswerSwapIn.
    /// </summary>
    public static void PromptSwapIn(Control control)
    {
        if (Motion.ReduceMotion) AnswerSwapIn(control);
        else Of(control).Enter(new Placement(X: StudyEntrance.PromptShift, Opacity: 0), Motion.Gentle.Delayed(0.06));
    }

    /// <summary>Glides into place from (x, y) while its screen fades in (Mac: entranceShift). Reduce Motion: nothing.</summary>
    public static void EntranceShift(Control control, double x = 0, double y = 0)
    {
        if (Motion.ReduceMotion) return;
        Of(control).Enter(new Placement(x, y), Motion.Glide);
    }

    /// <summary>Fades in (a screen's reveal, a summary appearing).</summary>
    public static void FadeIn(Control control, Curve curve) => Of(control).Enter(new Placement(Opacity: StudyEntrance.HiddenOpacity), curve);
}

/// <summary>
/// How a study screen comes in (Mac: StudyEntrance.swift): it is built once, invisibly, then fades in as one piece;
/// inside, the prompt glides in from the right and the answer tiles from below, exactly as every later question does.
/// Whole screens only fade (scaled or moved, their text would re-render every frame); only content glides, by a few
/// points. Reduce Motion keeps short fades without movement.
/// </summary>
public static class StudyEntrance
{
    /// <summary>How far the prompt glides in from the right, and the answer tiles from below.</summary>
    public const double PromptShift = 18;
    public const double TileShift = 12;

    /// <summary>Opacity of content that is built but not shown yet (not zero: some renderers skip invisible content).</summary>
    public const double HiddenOpacity = 0.001;

    /// <summary>The fade-in of a study screen or a page.</summary>
    public static Curve Reveal => Motion.ReduceMotion ? Curve.EaseOut(0.2) : Motion.Soft(0.6);

    /// <summary>A study screen's content fades in where it stands (the window keeps its keys from the first frame).</summary>
    public static void RevealScreen(Control content) => Effects.FadeIn(content, Reveal);
}
