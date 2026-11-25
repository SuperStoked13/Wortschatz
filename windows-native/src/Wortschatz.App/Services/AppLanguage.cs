using System.Globalization;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>Einstellungen › Allgemein › Sprache: what decides the language of the app's texts.</summary>
public enum AppLanguageChoice
{
    /// <summary>The language of Windows (Android: of the phone): English → English, anything else → German.</summary>
    System,
    De,
    En,
}

/// <summary>
/// The language of the app's texts (Mac: AppLanguage.swift): German (the source language, Swiss spelling) or English
/// (<see cref="CoreText"/>, <see cref="TextTable"/>). Unlike the Mac, where macOS picks the language when the app starts,
/// a change applies at once: the window is built again in the new language.
/// </summary>
public static class AppLanguage
{
    /// <summary>For the snapshot tool and tests: the system language they pretend to have (null = the real one).</summary>
    public static string? SystemLanguageOverride { get; set; }

    /// <summary>The language of the texts on screen now: "de" or "en".</summary>
    public static string Current => CoreText.Language;

    /// <summary>The language «System» leads to: the display language of Windows or the phone.</summary>
    public static string SystemLanguage =>
        SystemLanguageOverride ?? (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "en" ? "en" : "de");

    /// <summary>The language <paramref name="choice"/> leads to.</summary>
    public static string LanguageFor(AppLanguageChoice choice) => choice switch
    {
        AppLanguageChoice.De => "de",
        AppLanguageChoice.En => "en",
        _ => SystemLanguage,
    };

    /// <summary>Switches the texts to the language of <paramref name="choice"/>; the caller rebuilds what is on screen.</summary>
    public static void Install(AppLanguageChoice choice)
    {
        CoreText.Table = LanguageFor(choice) == "en" ? TextTable.English : null;
        _formatting = null;
    }

    static CultureInfo? _formatting;

    /// <summary>
    /// Dates and numbers in the texts: Swiss German, or with English the system's own format when it is English too
    /// (else British English) – Mac: AppLanguage.formattingLocale.
    /// </summary>
    public static CultureInfo FormattingCulture => _formatting ??= Current != "en"
        ? CultureInfo.GetCultureInfo("de-CH")
        : CultureInfo.CurrentCulture.TwoLetterISOLanguageName == "en" ? CultureInfo.CurrentCulture : CultureInfo.GetCultureInfo("en-GB");
}
