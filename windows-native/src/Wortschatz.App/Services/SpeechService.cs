using System.Runtime.InteropServices;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// Read-aloud (Mac: SpeechService.swift with AVSpeechSynthesizer). Windows: the system voices through SAPI
/// (COM "SAPI.SpVoice"), including the newer OneCore voices (Speech_OneCore registry key) – the voice whose
/// language matches the text's is used. Without a voice for the language nothing is read (a German voice reading
/// French sounds wrong); <see cref="MissingVoice"/> tells the app, which explains how to add one.
/// Other systems: silent (development and tests).
/// </summary>
public abstract class SpeechService
{
    public static SpeechService Create() =>
        OperatingSystem.IsWindows() ? (SpeechService?)SapiSpeech.TryCreate() ?? new SilentSpeech() : new SilentSpeech();

    /// <summary>A text could not be read because Windows has no voice for its language.</summary>
    public event Action<Lang>? MissingVoice;

    protected void ReportMissing(Lang lang) => MissingVoice?.Invoke(lang);

    /// <summary>Whether a voice for lang exists.</summary>
    public abstract bool CanSpeak(Lang lang);

    /// <summary>Reads text in lang, cancelling anything still speaking.</summary>
    public abstract void Speak(string text, Lang lang);

    public abstract void Stop();

    /// <summary>The installed voices by language (Einstellungen › Stimmen zum Vorlesen).</summary>
    public abstract IReadOnlyList<(Lang Lang, string Name)> Voices { get; }
}

public sealed class SilentSpeech : SpeechService
{
    public List<(string Text, Lang Lang)> Spoken { get; } = [];
    public override bool CanSpeak(Lang lang) => lang != Lang.Other;
    public override void Speak(string text, Lang lang) => Spoken.Add((text, lang));
    public override void Stop() { }
    public override IReadOnlyList<(Lang Lang, string Name)> Voices => [];
}

/// <summary>SAPI 5 through late-bound COM (no extra packages; works on every Windows 10/11).</summary>
public sealed class SapiSpeech : SpeechService
{
    const int SVSFlagsAsync = 1, SVSFPurgeBeforeSpeak = 2;
    readonly dynamic _voice;
    /// <summary>Voice tokens by language (primary language id → token), OneCore voices first (they sound better).</summary>
    readonly Dictionary<int, object> _tokens = new();
    readonly List<(Lang Lang, string Name)> _voices = [];

    SapiSpeech(dynamic voice)
    {
        _voice = voice;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var category in new[] { @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices", @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech\Voices" })
        {
            try
            {
                dynamic cat = Activator.CreateInstance(Type.GetTypeFromProgID("SAPI.SpObjectTokenCategory")!)!;
                cat.SetId(category, false);
                dynamic tokens = cat.EnumerateTokens();
                for (int i = 0; i < (int)tokens.Count; i++)
                {
                    dynamic token = tokens.Item(i);
                    string language = token.GetAttribute("Language");
                    string name = "";
                    try { name = token.GetAttribute("Name"); }
                    catch (COMException) { }
                    foreach (var part in language.Split(';'))
                    {
                        if (!int.TryParse(part, System.Globalization.NumberStyles.HexNumber, null, out int lcid)) continue;
                        _tokens.TryAdd(lcid & 0x3FF, token); // primary language id
                        if (LangOf(lcid & 0x3FF) is { } lang && name.Length > 0 && seen.Add(Shorten(name))) _voices.Add((lang, Shorten(name)));
                    }
                }
            }
            catch (COMException) { }
            catch (InvalidCastException) { }
            catch (Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { }
        }
    }

    /// <summary>"Microsoft Hedda Desktop - German" → "Microsoft Hedda".</summary>
    static string Shorten(string name)
    {
        var s = name.Split(" - ")[0];
        return s.EndsWith(" Desktop", StringComparison.Ordinal) ? s[..^8] : s;
    }

    public static SapiSpeech? TryCreate()
    {
        try
        {
            var type = Type.GetTypeFromProgID("SAPI.SpVoice");
            return type is null ? null : new SapiSpeech(Activator.CreateInstance(type)!);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Primary language ids (LANGID &amp; 0x3FF) of the app's languages.</summary>
    static int? PrimaryLanguage(Lang lang) => lang switch
    {
        Lang.Fr => 0x0C,
        Lang.En => 0x09,
        Lang.Es => 0x0A,
        Lang.It => 0x10,
        Lang.Ar => 0x01,
        Lang.Zh => 0x04,
        Lang.De => 0x07,
        _ => null,
    };

    static Lang? LangOf(int primary) => primary switch
    {
        0x0C => Lang.Fr,
        0x09 => Lang.En,
        0x0A => Lang.Es,
        0x10 => Lang.It,
        0x01 => Lang.Ar,
        0x04 => Lang.Zh,
        0x07 => Lang.De,
        _ => null,
    };

    public override bool CanSpeak(Lang lang) => PrimaryLanguage(lang) is { } id && _tokens.ContainsKey(id);

    public override IReadOnlyList<(Lang Lang, string Name)> Voices => _voices;

    public override void Speak(string text, Lang lang)
    {
        if (PrimaryLanguage(lang) is not { } id || !_tokens.TryGetValue(id, out var token))
        {
            Stop();
            if (lang != Lang.Other) ReportMissing(lang);
            return;
        }
        try
        {
            _voice.Voice = (dynamic)token;
            _voice.Speak(text, SVSFlagsAsync | SVSFPurgeBeforeSpeak);
        }
        catch (Exception) { }
    }

    public override void Stop()
    {
        try { _voice.Speak("", SVSFlagsAsync | SVSFPurgeBeforeSpeak); }
        catch (Exception) { }
    }
}
