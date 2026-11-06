using System.Runtime.InteropServices;

namespace Wortschatz.App.Services;

/// <summary>
/// Short, quiet interface sounds for studying (Mac: SoundEffects.swift, same notes and timings): a soft two-note chime
/// for a correct answer, a muted low tone for a miss, a rising arpeggio for a streak milestone, a small fanfare after a
/// round and at the end, and for the flashcards a chime or a warm tone with a swish when a card is sorted and a breath
/// of air when it comes back. The tones are synthesized once in memory (no audio files) and played through the
/// Windows waveOut API, one device handle per sound, so a quick second answer does not cut the first chime off.
/// The switch is Einstellungen › Allgemein › "Soundeffekte" (on by default, like the Mac).
/// </summary>
public sealed class SoundEffects
{
    public enum Sound { Correct, Wrong, Streak, RoundDone, Finished, DailyStreak, Know, StillLearning, Undo }

    /// <summary>What a study step recorded, for its sound.</summary>
    public enum StudyAnswer { Correct, Wrong, DontKnow }

    readonly Func<bool> _isEnabled;
    readonly Dictionary<Sound, short[]> _samples = [];
    readonly Lock _lock = new();
    const double Volume = 0.55;

    public SoundEffects(Func<bool> isEnabled)
    {
        _isEnabled = isEnabled;
        // Synthesized in the background right after launch (about 2–20 ms each), so the first chime is not late.
        Task.Run(() =>
        {
            foreach (var s in Enum.GetValues<Sound>()) SamplesOf(s);
        });
    }

    public bool IsEnabled => _isEnabled();

    /// <summary>
    /// The sound of one step of a study screen (Lernen, Schreiben): the fanfare when the session or a round is done,
    /// else the chime of the answer just recorded (a streak milestone gets its own). "Weiss ich nicht" stays quiet.
    /// </summary>
    public void PlayStudyStep(bool finished, bool roundDone, StudyAnswer? answer, bool reachedMilestone)
    {
        if (finished) Play(Sound.Finished);
        else if (roundDone) Play(Sound.RoundDone);
        else if (answer == StudyAnswer.Correct) Play(reachedMilestone ? Sound.Streak : Sound.Correct);
        else if (answer == StudyAnswer.Wrong) Play(Sound.Wrong);
    }

    public void Play(Sound sound, bool force = false)
    {
        if (!force && !IsEnabled) return;
        var player = PlatformPlayer;
        if (player is null && !OperatingSystem.IsWindows()) return;
        var samples = SamplesOf(sound);
        if (samples.Length == 0) return;
        Task.Run(() =>
        {
            if (player is not null) player(samples, Synth.SampleRate);
            else WaveOut.Play(samples, Synth.SampleRate);
        });
    }

    /// <summary>
    /// Plays 16-bit mono samples at a rate on another platform (a phone: AudioTrack); null: Windows' waveOut.
    /// The sounds themselves are made here, the same everywhere.
    /// </summary>
    public static Action<short[], int>? PlatformPlayer { get; set; }

    short[] SamplesOf(Sound sound)
    {
        lock (_lock)
        {
            if (_samples.TryGetValue(sound, out var s)) return s;
        }
        var made = Synth.Render(Notes(sound), Swishes(sound), Volume);
        lock (_lock) _samples[sound] = made;
        return made;
    }

    static Synth.Note[] Notes(Sound sound) => sound switch
    {
        // A5 → E6, light and short.
        Sound.Correct => [new(880.00, 0, 0.20, 0.11), new(1318.51, 0.075, 0.17, 0.13)],
        // E♭4 → B♭3, soft and low, no buzz.
        Sound.Wrong => [new(311.13, 0, 0.26, 0.08, 0.08), new(233.08, 0.09, 0.24, 0.10, 0.08)],
        // C6 E6 G6 C7.
        Sound.Streak => [new(1046.50, 0, 0.14, 0.12), new(1318.51, 0.065, 0.14, 0.12), new(1567.98, 0.13, 0.14, 0.13), new(2093.00, 0.195, 0.12, 0.22)],
        // G5 C6 E6.
        Sound.RoundDone => [new(783.99, 0, 0.16, 0.14), new(1046.50, 0.09, 0.16, 0.14), new(1318.51, 0.18, 0.15, 0.26)],
        // C5 E5 G5, then C6 + E6 together.
        Sound.Finished => [new(523.25, 0, 0.15, 0.14), new(659.25, 0.09, 0.15, 0.14), new(783.99, 0.18, 0.15, 0.16), new(1046.50, 0.28, 0.13, 0.34), new(1318.51, 0.28, 0.10, 0.34)],
        // D5 F♯5 A5 D6.
        Sound.DailyStreak => [new(587.33, 0, 0.15, 0.13), new(739.99, 0.08, 0.15, 0.13), new(880.00, 0.16, 0.15, 0.14), new(1174.66, 0.24, 0.13, 0.28)],
        // The correct chime, a little softer: it is the learner's own verdict.
        Sound.Know => [new(880.00, 0, 0.16, 0.10), new(1318.51, 0.07, 0.14, 0.13)],
        // E5 → D5, warm and quiet: "not yet", not "wrong".
        Sound.StillLearning => [new(659.25, 0, 0.15, 0.09, 0.07), new(587.33, 0.075, 0.13, 0.12, 0.07)],
        _ => [],
    };

    static Synth.Swish[] Swishes(Sound sound) => sound switch
    {
        Sound.Know => [new(1500, 3200, 0.02, 0.22, 0.11)],
        Sound.StillLearning => [new(1500, 800, 0.02, 0.22, 0.14)],
        Sound.Undo => [new(2200, 700, 0, 0.2, 0.13)],
        _ => [],
    };

    /// <summary>A tiny synthesizer: decaying sine partials (a soft bell) and swishes of filtered noise (Mac: Synth).</summary>
    static class Synth
    {
        public const int SampleRate = 44_100;

        public readonly record struct Note(double Frequency, double Start, double Gain, double Decay, double Overtone = 0.18)
        {
            public double End => Start + Decay * 7;
        }

        public readonly record struct Swish(double From, double To, double Start, double Duration, double Gain, double Q = 0.8)
        {
            public double End => Start + Duration;
        }

        public static short[] Render(Note[] notes, Swish[] swishes, double volume)
        {
            double length = notes.Select(n => n.End).Concat(swishes.Select(s => s.End)).DefaultIfEmpty(0).Max() + 0.02;
            int count = (int)(length * SampleRate);
            var samples = new double[count];
            foreach (var s in swishes) Add(s, samples);
            const double attack = 0.004;
            foreach (var note in notes)
            {
                int first = (int)(note.Start * SampleRate), last = Math.Min(count, (int)(note.End * SampleRate));
                for (int i = first; i < last; i++)
                {
                    double t = (double)i / SampleRate - note.Start;
                    double envelope = Math.Min(1, t / attack) * Math.Exp(-t / note.Decay);
                    double phase = 2 * Math.PI * note.Frequency * t;
                    double tone = Math.Sin(phase) + note.Overtone * Math.Sin(2 * phase) * Math.Exp(-t / (note.Decay * 0.5)) + 0.05 * Math.Sin(3 * phase);
                    samples[i] += note.Gain * envelope * tone;
                }
            }
            int fade = Math.Min(count, (int)(0.01 * SampleRate));
            for (int k = 0; k < fade; k++) samples[count - 1 - k] *= (double)k / fade;
            var pcm = new short[count];
            for (int i = 0; i < count; i++) pcm[i] = (short)Math.Round(Math.Clamp(samples[i] * volume, -1, 1) * 32767);
            return pcm;
        }

        /// <summary>White noise (the same every time) through two band-pass stages that glide with the pitch.</summary>
        static void Add(Swish swish, double[] samples)
        {
            int first = (int)(swish.Start * SampleRate), length = (int)(swish.Duration * SampleRate);
            const double peak = 0.35;
            ulong noise = 0x9E3779B97F4A7C15;
            double x1 = 0, x2 = 0, y1 = 0, y2 = 0, z1 = 0, z2 = 0, w1 = 0, w2 = 0;
            for (int i = 0; i < length && first + i < samples.Length; i++)
            {
                double u = (double)i / length;
                double swell = u < peak ? Math.Pow(Math.Sin(Math.PI / 2 * u / peak), 2) : Math.Pow(Math.Cos(Math.PI / 2 * (u - peak) / (1 - peak)), 2);
                double frequency = swish.From * Math.Pow(swish.To / swish.From, u);
                double w0 = 2 * Math.PI * frequency / SampleRate;
                double alpha = Math.Sin(w0) / (2 * swish.Q);
                double b0 = alpha / (1 + alpha), b2 = -alpha / (1 + alpha);
                double a1 = -2 * Math.Cos(w0) / (1 + alpha), a2 = (1 - alpha) / (1 + alpha);
                noise ^= noise << 13;
                noise ^= noise >> 7;
                noise ^= noise << 17;
                double x = (double)(noise >> 11) / (1UL << 53) * 2 - 1;
                double y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2;
                (x2, x1, y2, y1) = (x1, x, y1, y);
                double v = b0 * y + b2 * z2 - a1 * w1 - a2 * w2;
                (z2, z1, w2, w1) = (z1, y, w1, v);
                samples[first + i] += swish.Gain * swell * v;
            }
        }
    }

    /// <summary>Plays 16-bit mono PCM on the default output through winmm (no packages, every Windows).</summary>
    static class WaveOut
    {
        [StructLayout(LayoutKind.Sequential)]
        struct WaveFormatEx
        {
            public ushort wFormatTag, nChannels;
            public uint nSamplesPerSec, nAvgBytesPerSec;
            public ushort nBlockAlign, wBitsPerSample, cbSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WaveHdr
        {
            public IntPtr lpData;
            public uint dwBufferLength, dwBytesRecorded;
            public IntPtr dwUser;
            public uint dwFlags, dwLoops;
            public IntPtr lpNext, reserved;
        }

        [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr hwo, uint device, ref WaveFormatEx format, IntPtr callback, IntPtr instance, uint flags);
        [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr hwo, IntPtr hdr, uint size);
        [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr hwo, IntPtr hdr, uint size);
        [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr hwo, IntPtr hdr, uint size);
        [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr hwo);
        [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr hwo);

        const uint WAVE_MAPPER = 0xFFFFFFFF, WHDR_DONE = 1;

        public static void Play(short[] samples, int rate)
        {
            var format = new WaveFormatEx { wFormatTag = 1, nChannels = 1, nSamplesPerSec = (uint)rate, wBitsPerSample = 16, nBlockAlign = 2, nAvgBytesPerSec = (uint)rate * 2 };
            if (waveOutOpen(out var hwo, WAVE_MAPPER, ref format, IntPtr.Zero, IntPtr.Zero, 0) != 0) return;
            int bytes = samples.Length * 2;
            IntPtr data = Marshal.AllocHGlobal(bytes);
            IntPtr hdr = Marshal.AllocHGlobal(Marshal.SizeOf<WaveHdr>());
            try
            {
                Marshal.Copy(samples, 0, data, samples.Length);
                Marshal.StructureToPtr(new WaveHdr { lpData = data, dwBufferLength = (uint)bytes }, hdr, false);
                uint size = (uint)Marshal.SizeOf<WaveHdr>();
                if (waveOutPrepareHeader(hwo, hdr, size) != 0) return;
                if (waveOutWrite(hwo, hdr, size) == 0)
                {
                    var deadline = DateTime.UtcNow.AddMilliseconds(samples.Length * 1000.0 / rate + 1500);
                    while ((Marshal.PtrToStructure<WaveHdr>(hdr).dwFlags & WHDR_DONE) == 0 && DateTime.UtcNow < deadline) Thread.Sleep(20);
                }
                waveOutReset(hwo);
                waveOutUnprepareHeader(hwo, hdr, size);
            }
            finally
            {
                waveOutClose(hwo);
                Marshal.FreeHGlobal(hdr);
                Marshal.FreeHGlobal(data);
            }
        }
    }
}
