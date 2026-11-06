using System.Globalization;
using System.Runtime.InteropServices;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// Read-aloud (Mac: SpeechService.swift with AVSpeechSynthesizer, a port of src/lib/speech.js). Windows: the system
/// voices through SAPI (COM "SAPI.SpVoice"), including the newer OneCore voices (Speech_OneCore registry key, they
/// count as the better ones). Like the Mac: the best installed voice per language (fr-FR, de-CH falling back to de-DE,
/// en-GB, es-ES, it-IT, ar, zh-CN but never a Cantonese voice) unless one is chosen in Einstellungen › Allgemein,
/// vocabulary notation made speakable ("beau/belle" → "beau, belle", Chinese without its pinyin: SpeechText), 0.92 ×
/// the user's rate, and every new text cancels the previous one. «Andere» is read with the Windows default voice.
/// Without a voice for the language nothing is read (a German voice reading French sounds wrong);
/// <see cref="MissingVoice"/> tells the app, which explains how to add one. Other systems: silent (development, tests).
/// </summary>
public abstract class SpeechService
{
    public static SpeechService Create() =>
        PlatformFactory?.Invoke()
        ?? (OperatingSystem.IsWindows() ? (SpeechService?)SapiSpeech.TryCreate() ?? new SilentSpeech() : new SilentSpeech());

    /// <summary>Another platform's voices (a phone: the system's text-to-speech), set before the app starts.</summary>
    public static Func<SpeechService?>? PlatformFactory { get; set; }

    /// <summary>A text could not be read because Windows has no voice for its language.</summary>
    public event Action<Lang>? MissingVoice;

    protected void ReportMissing(Lang lang) => MissingVoice?.Invoke(lang);

    readonly Dictionary<Lang, string> _preferred = [];

    /// <summary>The voice chosen per language in the settings (voice ids); missing = automatic (Mac: preferredVoiceIDs).</summary>
    public IReadOnlyDictionary<Lang, string> PreferredVoiceIds => _preferred;

    /// <summary>A voice was chosen or reset (the app stores <see cref="PreferredVoiceIds"/>).</summary>
    public event Action? PreferredVoicesChanged;

    /// <summary>Takes the stored choices (start), without reporting a change.</summary>
    public void LoadPreferredVoices(IEnumerable<KeyValuePair<Lang, string>> ids)
    {
        _preferred.Clear();
        foreach (var (lang, id) in ids) _preferred[lang] = id;
    }

    /// <summary>Stores the voice for lang (null = automatic).</summary>
    public void SetPreferredVoice(Lang lang, string? id)
    {
        if (id is null) _preferred.Remove(lang);
        else _preferred[lang] = id;
        PreferredVoicesChanged?.Invoke();
    }

    /// <summary>Every installed voice of the app's languages (and others), as read at the start.</summary>
    public abstract IReadOnlyList<VoiceInfo> InstalledVoices { get; }

    /// <summary>Whether «Andere» can be read (Windows has a default voice).</summary>
    protected abstract bool HasDefaultVoice { get; }

    /// <summary>The installed voices that fit lang, best first (the settings' voice picker).</summary>
    public List<VoiceInfo> VoicesFor(Lang lang) => SpeechText.Ranked(lang, InstalledVoices);

    /// <summary>The voice "Automatisch" picks for lang (null: none installed).</summary>
    public VoiceInfo? AutomaticVoice(Lang lang) => SpeechText.VoiceFor(lang, InstalledVoices, null);

    /// <summary>The voice used for lang: the chosen one while it is installed, else the best match.</summary>
    public VoiceInfo? VoiceFor(Lang lang) => SpeechText.VoiceFor(lang, InstalledVoices, _preferred.GetValueOrDefault(lang));

    /// <summary>Whether texts in lang are read.</summary>
    public bool CanSpeak(Lang lang) => lang == Lang.Other ? HasDefaultVoice : VoiceFor(lang) is not null;

    /// <summary>Reads text in lang, cancelling anything still speaking. Blank text is ignored.</summary>
    public void Speak(string text, Lang lang)
    {
        var spoken = SpeechText.Speakable(text, lang);
        if (spoken.Length == 0) return;
        if (lang == Lang.Other)
        {
            if (HasDefaultVoice) SpeakWith(null, spoken);
            return;
        }
        if (VoiceFor(lang) is not { } voice)
        {
            Stop();
            ReportMissing(lang);
            return;
        }
        SpeakWith(voice, spoken);
    }

    /// <summary>Speaks prepared text with voice (null: the system's default voice).</summary>
    protected abstract void SpeakWith(VoiceInfo? voice, string text);

    public abstract void Stop();

    /// <summary>Something is being read aloud right now (Mac: SpeechService.isSpeaking; the speaker button moves).</summary>
    public virtual bool IsSpeaking => false;
}

public sealed class SilentSpeech : SpeechService
{
    /// <summary>What would have been read (prepared text), for checks.</summary>
    public List<(string Text, Lang? Lang)> Spoken { get; } = [];
    readonly List<VoiceInfo> _voices;

    public SilentSpeech(IEnumerable<VoiceInfo>? voices = null) => _voices = voices?.ToList() ?? [];

    public override IReadOnlyList<VoiceInfo> InstalledVoices => _voices;
    protected override bool HasDefaultVoice => true;
    protected override void SpeakWith(VoiceInfo? voice, string text) => Spoken.Add((text, voice is null ? null : SpeechText.LangOf(voice.Language)));
    public override void Stop() { }
}

/// <summary>SAPI 5 through late-bound COM (no extra packages; works on every Windows 10/11).</summary>
public sealed class SapiSpeech : SpeechService
{
    const int SVSFlagsAsync = 1, SVSFPurgeBeforeSpeak = 2, SVSFIsNotXML = 16;
    readonly dynamic _voice;
    /// <summary>The voice Windows reads with by default (Einstellungen › Sprachausgabe), for «Andere».</summary>
    readonly object? _defaultToken;
    readonly int _rate;
    readonly Dictionary<string, object> _tokens = new(StringComparer.Ordinal);
    readonly List<VoiceInfo> _voices = [];

    SapiSpeech(dynamic voice)
    {
        _voice = voice;
        try { _defaultToken = (object?)voice.Voice; }
        catch (Exception) { _defaultToken = null; }
        // The user's rate from the Windows settings, a step slower (Mac: 0.92 × the default rate).
        int baseRate = 0;
        try { baseRate = (int)voice.Rate; }
        catch (Exception) { }
        _rate = SpeechText.SapiRate(baseRate);

        // OneCore voices first: of two voices with the same name and language the better one stays.
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (category, quality) in new[]
        {
            (@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices", VoiceQuality.Enhanced),
            (@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech\Voices", VoiceQuality.Standard),
        })
        {
            try
            {
                dynamic cat = Activator.CreateInstance(Type.GetTypeFromProgID("SAPI.SpObjectTokenCategory")!)!;
                cat.SetId(category, false);
                dynamic tokens = cat.EnumerateTokens();
                for (int i = 0; i < (int)tokens.Count; i++)
                {
                    try
                    {
                        dynamic token = tokens.Item(i);
                        string id = token.Id;
                        string language = token.GetAttribute("Language");
                        string name = "";
                        try { name = token.GetAttribute("Name"); }
                        catch (COMException) { }
                        if (TagOf(language) is not { } tag) continue;
                        var shortName = name.Length > 0 ? Shorten(name) : id;
                        if (!seen.Add($"{shortName}|{tag}")) continue;
                        _tokens[id] = token;
                        _voices.Add(new VoiceInfo(id, shortName, tag, quality));
                    }
                    catch (COMException) { }
                    catch (Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { }
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

    /// <summary>The BCP 47 tag of SAPI's Language attribute (hex LCIDs separated by ";", the first counts):
    /// "807" → "de-CH", "C04" → "zh-HK".</summary>
    static string? TagOf(string language)
    {
        foreach (var part in language.Split(';'))
        {
            if (!int.TryParse(part.Trim(), NumberStyles.HexNumber, null, out int lcid)) continue;
            try
            {
                var name = CultureInfo.GetCultureInfo(lcid).Name;
                if (name.Length > 0) return name;
            }
            catch (CultureNotFoundException) { }
            // Without culture data: at least the language (primary language id).
            return (lcid & 0x3FF) switch
            {
                0x0C => "fr",
                0x09 => "en",
                0x0A => "es",
                0x10 => "it",
                0x01 => "ar",
                0x04 => "zh",
                0x07 => "de",
                _ => null,
            };
        }
        return null;
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

    public override IReadOnlyList<VoiceInfo> InstalledVoices => _voices;

    protected override bool HasDefaultVoice => _defaultToken is not null;

    protected override void SpeakWith(VoiceInfo? voice, string text)
    {
        var token = voice is null ? _defaultToken : _tokens.GetValueOrDefault(voice.Id);
        if (token is null) return;
        try
        {
            _voice.Voice = (dynamic)token;
            _voice.Rate = _rate;
            _voice.Speak(text, SVSFlagsAsync | SVSFPurgeBeforeSpeak | SVSFIsNotXML);
        }
        catch (Exception) { }
    }

    public override void Stop()
    {
        try { _voice.Speak("", SVSFlagsAsync | SVSFPurgeBeforeSpeak); }
        catch (Exception) { }
    }

    /// <summary>SpVoice.Status.RunningState is SRSEIsSpeaking (2) while a text is read.</summary>
    public override bool IsSpeaking
    {
        get
        {
            try { return (int)_voice.Status.RunningState == 2; }
            catch (Exception) { return false; }
        }
    }
}
