using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// A short vibration for answers and verdicts (Mac: Haptics.swift on the trackpad). Windows has no haptics for apps:
/// silent there. A phone host sets <see cref="PlatformPerformer"/> (the phone's haptic feedback, which follows the
/// system's "Vibration bei Berührung" setting).
/// </summary>
public static class Haptics
{
    public enum Feedback { Success, Failure, Selection }

    /// <summary>The platform's haptics (null: none).</summary>
    public static Action<Feedback>? PlatformPerformer { get; set; }

    public static void Success() => Play(Feedback.Success);
    public static void Failure() => Play(Feedback.Failure);

    /// <summary>A light tick: a card sorted, a swipe crossing its threshold.</summary>
    public static void Selection() => Play(Feedback.Selection);

    /// <summary>The flows' haptic effect (Lernen, Schreiben).</summary>
    public static void Play(HapticKind kind) => Play(kind == HapticKind.Success ? Feedback.Success : Feedback.Failure);

    static void Play(Feedback feedback)
    {
        try { PlatformPerformer?.Invoke(feedback); }
        catch (Exception) { }
    }
}
