using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Input;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Study;

/// <summary>
/// Keyboard details of the study screens (Mac: LearnKeyRouter.swift, InputSource.swift): text being composed by an
/// input method or a dead key, whether an input method (Pinyin, Kana …) is the current keyboard, and whether the key
/// that typed a text is held down (auto-repeat).
/// </summary>
public static class StudyInput
{
    /// <summary>
    /// The key belongs to a composition (Mac: isComposingText): Windows hands keys an input method processes over as
    /// ImeProcessed (Enter that picks a Pinyin candidate, Esc that cancels it), a dead key (^, ¨, `) as
    /// DeadCharProcessed, and while the focused field shows marked text (preedit) every key is the composition's.
    /// Such keys are never study commands.
    /// </summary>
    public static bool IsComposing(KeyEventArgs e, TopLevel? top)
    {
        if (e.Key is Key.ImeProcessed or Key.DeadCharProcessed) return true;
        return top?.FocusManager?.GetFocusedElement() is TextBox box && HasPreedit(box);
    }

    /// <summary>Whether the text box shows uncommitted text of an input method.</summary>
    public static bool HasPreedit(TextBox box) =>
        box.GetVisualDescendants().OfType<TextPresenter>().FirstOrDefault() is { } presenter && !string.IsNullOrEmpty(presenter.PreeditText);

    /// <summary>
    /// The current keyboard is an input method (Mac: InputSource.isInputMethodActive): a Chinese, Japanese or Korean
    /// keyboard whose layout is that language's own (Microsoft Pinyin, IME Japanese …), not a plain layout added for
    /// that language (e.g. "US" under Chinese). Off Windows: false.
    /// </summary>
    public static bool IsInputMethodActive()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            long hkl = GetKeyboardLayout(0).ToInt64();
            int language = (int)(hkl & 0xFFFF) & 0x3FF, layout = (int)((hkl >> 16) & 0xFFFF);
            static bool Composes(int primary) => primary is 0x04 or 0x11 or 0x12; // zh, ja, ko
            // Old IMM input methods have a device handle 0xE0xx; text services carry the language as their layout.
            return Composes(language) && ((layout & 0xF000) == 0xE000 || Composes(layout & 0x3FF));
        }
        catch (Exception)
        {
            return false;
        }
    }

    [DllImport("user32.dll")]
    static extern IntPtr GetKeyboardLayout(uint threadId);
}

/// <summary>
/// The speaker on the study card moves while something is read aloud (Mac: <c>.symbolEffect(.variableColor.iterative,
/// isActive: speech.isSpeaking)</c>): its icon pulses until the voice is done. The screen hands over the freshly built
/// icon on every render (Attach) and tells when speech started (Started); Reduce Motion: nothing moves.
/// </summary>
public sealed class SpeakingIndicator(Services.SpeechService speech)
{
    /// <summary>How long a start counts as speaking before the voice reports it (SAPI starts asynchronously).</summary>
    const double Grace = 0.6;
    Control? _icon;
    double _startedAt = double.NegativeInfinity;
    bool _running;

    public void Attach(Control icon)
    {
        _icon = icon;
        if (IsActive(DesignSystem.Motion.Now())) Run();
    }

    public void Started()
    {
        _startedAt = DesignSystem.Motion.Now();
        Run();
    }

    bool IsActive(double now) => now - _startedAt < Grace || speech.IsSpeaking;

    void Run()
    {
        if (_running || DesignSystem.Motion.ReduceMotion || _icon is null) return;
        _running = true;
        double checkedAt = double.NegativeInfinity;
        bool active = true;
        DesignSystem.Motion.OnFrames(now =>
        {
            // The voice is asked a few times a second, not on every frame (a COM call).
            if (now - checkedAt > 0.15)
            {
                checkedAt = now;
                active = IsActive(now);
            }
            if (_icon is not { } icon) return _running = false;
            if (!active)
            {
                icon.Opacity = 1;
                return _running = false;
            }
            icon.Opacity = 0.45 + 0.55 * (0.5 + 0.5 * Math.Cos((now - _startedAt) * Math.PI * 2 / 0.9));
            return true;
        });
    }
}

/// <summary>
/// The requests whose study screen was opened once (Mac: AppModel.studySessionStarted + StudyRequest.resuming): when
/// the same route is built again (a theme change rebuilds the window), the screen resumes the stored session instead
/// of starting the requested subset or a new session once more. Keyed by the request object, so a later study request
/// with equal values still starts fresh.
/// </summary>
public static class StudySessions
{
    static readonly ConditionalWeakTable<StudyRequest, object> Started = new();

    /// <summary>The request to start with: resuming (no subset, not forced new) when its screen was opened before.</summary>
    public static StudyRequest Effective(StudyRequest request) =>
        Started.TryGetValue(request, out _) ? request with { Subset = null, ForceNew = false } : request;

    public static void MarkStarted(StudyRequest request) => Started.AddOrUpdate(request, true);

    /// <summary>
    /// "Begriffe hinzufügen" on an empty study screen (Mac: LearnController/WriteController.setEditorClosed): the set
    /// editor opens in place of the screen; when it closes back to the set and the set now has cards to ask, studying
    /// starts right away in <paramref name="mode"/>.
    /// </summary>
    public static void StudyAfterEditing(AppModel model, string setId, StudyMode mode, Func<VocabSet, bool> hasCardsToAsk)
    {
        void Changed()
        {
            if (model.Route is Route.Editor editor && editor.SetId == setId) return;
            model.RouteChanged -= Changed;
            if (model.Route is not Route.SetDetail detail || detail.SetId != setId) return;
            if (model.Store.GetSet(setId) is not { } set || !hasCardsToAsk(set)) return;
            Dispatcher.UIThread.Post(() =>
            {
                if (model.Route is Route.SetDetail d && d.SetId == setId) model.Study(setId, mode);
            });
        }
        model.RouteChanged += Changed;
    }
}
