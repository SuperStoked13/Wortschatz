namespace Wortschatz.App.Features.Learn;

/// <summary>
/// Correct answers in a row on a study screen (Lernen, Schreiben), port of mac/Wortschatz/Features/Learn/AnswerStreak.swift:
/// the flame in the action bar's pill, with a milestone every five. It lives as long as the screen, so every visit starts
/// at zero; the daily streak (Lernserie) is the one that lasts.
/// </summary>
public sealed class AnswerStreak
{
    /// <summary>A milestone every this many correct answers in a row (5, 10, 15 …).</summary>
    public const int MilestoneStep = 5;
    /// <summary>The pill shows the flame from this many on.</summary>
    public const int VisibleFrom = 3;

    public int Current { get; private set; }
    public int Best { get; private set; }
    /// <summary>The last change reached a milestone.</summary>
    public bool ReachedMilestone { get; private set; }
    /// <summary>The streak the last miss ended, given back by "Ich hatte recht".</summary>
    int _endedByMiss;

    /// <summary>An answer was recorded.</summary>
    public void Record(bool correct)
    {
        if (correct)
        {
            Current++;
            _endedByMiss = 0;
        }
        else
        {
            _endedByMiss = Current;
            Current = 0;
        }
        Settle(correct);
    }

    /// <summary>"Ich hatte recht": the miss counts as correct, so the streak it ended goes on.</summary>
    public void OverrideMiss()
    {
        Current = _endedByMiss + 1;
        _endedByMiss = 0;
        Settle(true);
    }

    public static bool IsMilestone(int count) => count > 0 && count % MilestoneStep == 0;

    void Settle(bool grew)
    {
        Best = Math.Max(Best, Current);
        ReachedMilestone = grew && IsMilestone(Current);
    }
}
