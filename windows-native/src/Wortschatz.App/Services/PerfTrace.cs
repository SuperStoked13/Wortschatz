using System.Diagnostics;

namespace Wortschatz.App;

/// <summary>
/// Timing for development (off unless the environment variable WORTSCHATZ_TRACE is set): how long a screen takes from
/// the route change to its first layout, appended to %TEMP%\wortschatz-trace.log. Used to measure the app on a real PC.
/// </summary>
public static class PerfTrace
{
    static readonly bool Enabled = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WORTSCHATZ_TRACE"));
    static readonly string LogPath = Path.Combine(Path.GetTempPath(), "wortschatz-trace.log");

    public static long Start() => Enabled ? Stopwatch.GetTimestamp() : 0;

    public static void Log(string text)
    {
        if (!Enabled) return;
        try { File.AppendAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} {text}{Environment.NewLine}"); }
        catch (IOException) { }
    }

    /// <summary>Logs the time from <paramref name="started"/> until the window's next layout pass is done.</summary>
    public static void UntilLayout(Avalonia.Layout.Layoutable window, long started, string what)
    {
        if (!Enabled) return;
        void Done(object? sender, EventArgs e)
        {
            window.LayoutUpdated -= Done;
            Log($"{what}: {Stopwatch.GetElapsedTime(started).TotalMilliseconds:F0} ms bis Layout");
        }
        window.LayoutUpdated += Done;
    }
}
