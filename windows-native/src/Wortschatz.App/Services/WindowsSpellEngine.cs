using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// The Windows spell checker (Spell Checking API, ISpellCheckerFactory, since Windows 8; offline, with the dictionaries of
/// the installed languages) behind <see cref="ISpellEngine"/> (Mac: NSSpellChecker in VocabSpellChecker.swift).
/// Null on other systems or when the factory is missing.
/// </summary>
public sealed class WindowsSpellEngine : ISpellEngine
{
    readonly ISpellCheckerFactory _factory;
    readonly Dictionary<string, ISpellChecker?> _checkers = new(StringComparer.OrdinalIgnoreCase);
    List<string>? _supported;

    WindowsSpellEngine(ISpellCheckerFactory factory) => _factory = factory;

    public static WindowsSpellEngine? TryCreate()
    {
        if (!OperatingSystem.IsWindows()) return null;
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC"));
            return type is not null && Activator.CreateInstance(type) is ISpellCheckerFactory factory ? new WindowsSpellEngine(factory) : null;
        }
        catch (Exception e) when (e is COMException or InvalidCastException or NotSupportedException or TypeLoadException)
        {
            return null;
        }
    }

    /// <summary>The installed dictionaries ("de-CH", "fr-FR" …).</summary>
    public IReadOnlyList<string> Supported => _supported ??= ReadSupported();

    List<string> ReadSupported()
    {
        var list = new List<string>();
        try
        {
            _factory.get_SupportedLanguages(out var tags);
            var one = new string[1];
            while (tags.Next(1, one, IntPtr.Zero) == 0) list.Add(one[0]);
        }
        catch (COMException) { }
        return list;
    }

    public string? Language(IReadOnlyList<string> candidates)
    {
        foreach (var candidate in candidates)
        {
            var exact = Supported.FirstOrDefault(t => t.Equals(candidate, StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return exact;
            if (!candidate.Contains('-'))
            {
                var regional = Supported.FirstOrDefault(t => t.StartsWith(candidate + "-", StringComparison.OrdinalIgnoreCase));
                if (regional is not null) return regional;
            }
        }
        return null;
    }

    ISpellChecker? Checker(string language)
    {
        if (_checkers.TryGetValue(language, out var checker)) return checker;
        try { _factory.CreateSpellChecker(language, out checker); }
        catch (COMException) { checker = null; }
        _checkers[language] = checker;
        return checker;
    }

    public IReadOnlyList<(int Start, int Length)> Check(string text, string language)
    {
        var list = new List<(int, int)>();
        if (Checker(language) is not { } checker || text.Length == 0) return list;
        try
        {
            checker.Check(text, out var errors);
            while (errors.Next(out var error) == 0 && error is not null)
            {
                error.get_StartIndex(out uint start);
                error.get_Length(out uint length);
                error.get_CorrectiveAction(out var action);
                // GET_SUGGESTIONS and REPLACE are misspellings; DELETE is a repeated word ("vous vous" can be right).
                if (action is CorrectiveAction.GetSuggestions or CorrectiveAction.Replace) list.Add(((int)start, (int)length));
                Marshal.ReleaseComObject(error);
            }
            Marshal.ReleaseComObject(errors);
        }
        catch (COMException) { }
        return list;
    }

    public IReadOnlyList<string> Suggest(string word, string language)
    {
        var list = new List<string>();
        if (Checker(language) is not { } checker) return list;
        try
        {
            checker.Suggest(word, out var words);
            var one = new string[1];
            while (list.Count < 12 && words.Next(1, one, IntPtr.Zero) == 0) list.Add(one[0]);
            Marshal.ReleaseComObject(words);
        }
        catch (COMException) { }
        return list;
    }

    // MARK: COM (spellcheck.h)

    enum CorrectiveAction { None = 0, GetSuggestions = 1, Replace = 2, Delete = 3 }

    [ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellCheckerFactory
    {
        void get_SupportedLanguages(out IEnumString value);
        void IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag, out int value);
        void CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag, out ISpellChecker value);
    }

    [ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellChecker
    {
        void get_LanguageTag([MarshalAs(UnmanagedType.LPWStr)] out string value);
        void Check([MarshalAs(UnmanagedType.LPWStr)] string text, out IEnumSpellingError value);
        void Suggest([MarshalAs(UnmanagedType.LPWStr)] string word, out IEnumString value);
    }

    [ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IEnumSpellingError
    {
        [PreserveSig] int Next(out ISpellingError? value);
    }

    [ComImport, Guid("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellingError
    {
        void get_StartIndex(out uint value);
        void get_Length(out uint value);
        void get_CorrectiveAction(out CorrectiveAction value);
    }
}
