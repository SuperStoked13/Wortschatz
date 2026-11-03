using Avalonia;
using Avalonia.Controls.Primitives;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Settings;

/// <summary>
/// Einstellungen (Mac: SettingsView.swift with SettingsGeneralTab, SettingsDataTab): appearance, backups (export,
/// import with merge or replace – the same file format as the web and Mac apps, so sets move between them), delete
/// all data, and where the data lives. The study options are set per set in the study screens ("Optionen").
/// </summary>
public sealed class SettingsScreen(AppModel model, MainWindow window) : Screen(model, window)
{
    static readonly string[] Tabs = ["Allgemein", "Lernen", "Schreiben", "Toleranz", "Daten"];
    /// <summary>The open tab (kept while the app runs, like the Mac's settings window).</summary>
    static int _tab;

    protected override Control Build()
    {
        var content = new StackPanel { Spacing = 18, Margin = new Thickness(34, 14, 34, 24), MaxWidth = 820, HorizontalAlignment = HorizontalAlignment.Left };
        var tabs = new WsSegmented(Tabs, _tab, 112) { HorizontalAlignment = HorizontalAlignment.Left };
        tabs.SelectionChanged += i =>
        {
            _tab = i;
            Refresh();
        };
        content.Children.Add(Ui.V(14, Ui.V(4, Ui.Eyebrow("Wortschatz"), Ui.Title("Einstellungen")), tabs));
        foreach (var section in _tab switch
        {
            1 => StudyTab(StudyMode.Learn),
            2 => StudyTab(StudyMode.Write),
            3 => StudyTab(null),
            4 => DataTab(),
            _ => GeneralTab(),
        })
            content.Children.Add(section);
        return Ui.Scroll(content);
    }

    // MARK: Allgemein

    IEnumerable<Control> GeneralTab()
    {
        var p = WsTheme.P;
        var settings = Model.Store.GetSettings();
        var theme = AppearancePicker(settings.Theme, v =>
        {
            Model.Store.UpdateSettings(new SettingsPatch(v));
            Model.Store.Save();
            Window.Rebuild();
        });
        yield return Section("Darstellung", Row("Erscheinungsbild", theme, settings.Theme switch
        {
            ThemeSetting.Light => "Immer helles Design.",
            ThemeSetting.Dark => "Immer dunkles Design – angenehm am Abend.",
            _ => $"Folgt Windows – zurzeit {(Application.Current?.ActualThemeVariant == Avalonia.Styling.ThemeVariant.Dark ? "dunkel" : "hell")}.",
        }));

        var sounds = new WsSwitch(Model.Preferences.SoundEffects, "Soundeffekte");
        sounds.Toggled += on =>
        {
            Model.Preferences.SoundEffects = on;
            if (on) Model.Sounds.Play(Services.SoundEffects.Sound.Correct);
        };
        yield return Section("Töne", Row("Soundeffekte", sounds, "Leise Töne für richtige und falsche Antworten, Serien und geschaffte Runden."));

        var voices = Model.Speech.Voices;
        var rows = new List<Control>();
        foreach (var lang in Labels.LANG_ORDER.Where(l => l != Lang.Other))
        {
            var names = voices.Where(v => v.Lang == lang).Select(v => v.Name).ToList();
            var note = names.Count > 0 ? string.Join(", ", names) : "Keine Stimme installiert – wird nicht vorgelesen.";
            var sample = Ui.Secondary("Probe hören", () => Model.Speech.Speak(SampleText(lang), lang), IconName.Speaker, height: 34);
            sample.IsEnabled = names.Count > 0;
            var row = Row(Labels.LangName(lang), sample, note);
            if (names.Count == 0 && row is Grid { Children: [StackPanel { Children: [_, TextBlock hint] }, ..] }) hint.Foreground = WsTheme.B(p.Warning.Text);
            rows.Add(row);
        }
        var open = Ui.Secondary("Windows-Einstellungen öffnen", OpenSpeechSettings, IconName.Gear, height: 36);
        rows.Add(Row("Weitere Stimmen", open,
            "In Windows unter Einstellungen › Zeit und Sprache › Sprachausgabe › Stimmen hinzufügen. Danach Wortschatz neu starten."));
        yield return Section("Stimmen zum Vorlesen", [.. rows]);
    }

    static string SampleText(Lang lang) => lang switch
    {
        Lang.Fr => "Bonjour, je lis tes mots à haute voix.",
        Lang.En => "Hello, I read your words aloud.",
        Lang.Es => "Hola, leo tus palabras en voz alta.",
        Lang.It => "Ciao, leggo ad alta voce le tue parole.",
        Lang.Ar => "مرحبا، أقرأ كلماتك بصوت عال.",
        Lang.Zh => "你好，我来朗读你的单词。",
        _ => "Hallo, ich lese deine Wörter vor.",
    };

    void OpenSpeechSettings()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:speech") { UseShellExecute = true });
        }
        catch (Exception)
        {
            Model.ShowToast(new ToastMessage("Die Windows-Einstellungen konnten nicht geöffnet werden.", ToastTone.Warning));
        }
    }

    // MARK: Lernen, Schreiben, Toleranz (the defaults of every set, Mac: SettingsStudyTabs)

    IEnumerable<Control> StudyTab(StudyMode? mode)
    {
        var p = WsTheme.P;
        var settings = Model.Store.GetSettings();
        var sets = Model.Sets;
        var defLangs = sets.Select(s => s.DefLang).Distinct().ToList();
        var termLangs = sets.Select(s => s.TermLang).Distinct().ToList();
        var sharedDef = defLangs.Count == 0 ? Lang.De : defLangs.Count == 1 ? defLangs[0] : Lang.Other;
        var sharedTerm = termLangs.Count == 1 ? termLangs[0] : Lang.Other;
        var names = LearnOptionsCopy.SideNames(Lang.Other, sharedDef);
        void Patch(StudyOptionsPatch patch)
        {
            Model.Store.UpdateSettings(new SettingsPatch(Study: patch));
            Model.Store.Save();
        }
        var lead = Ui.Text("Gilt für alle Lernsets. Was du in den Optionen eines Lernsets umstellst, gilt nur für dieses Lernset.", 14, color: p.TextSecondary, wrap: TextWrapping.Wrap);
        yield return lead;
        var sections = StudyChrome.StudyOptionSections(settings.Study, names, sharedTerm, mode, Patch,
            mode == StudyMode.Learn ? (Model.Preferences.LearnReview, v => Model.Preferences.LearnReview = v) : null, includeTolerance: mode is null).ToList();
        foreach (var s in sections) yield return s;

        var d = StudyOptions.Default;
        var o = settings.Study;
        bool isDefault = mode switch
        {
            StudyMode.Learn => o.AnswerWith == d.AnswerWith && o.Audio == d.Audio && o.Learn == d.Learn,
            StudyMode.Write => o.Shuffle == d.Shuffle && o.CopyAnswer == d.CopyAnswer && o.AutoAdvance == d.AutoAdvance,
            _ => o.Tolerance == d.Tolerance,
        };
        if (!isDefault)
        {
            var restore = Ui.PlainButton("Standard wiederherstellen", () =>
            {
                Patch(mode switch
                {
                    StudyMode.Learn => new StudyOptionsPatch(AnswerWith: d.AnswerWith, Audio: d.Audio,
                        Learn: new LearnOptionsPatch(d.Learn.RoundSize, d.Learn.Mc, d.Learn.Written, d.Learn.Retype)),
                    StudyMode.Write => new StudyOptionsPatch(Shuffle: d.Shuffle, CopyAnswer: d.CopyAnswer, AutoAdvance: d.AutoAdvance),
                    _ => new StudyOptionsPatch(Tolerance: new TolerancePatch(d.Tolerance.Articles, d.Tolerance.Abbreviations, d.Tolerance.MultipleAnswers,
                        d.Tolerance.Parentheses, d.Tolerance.IgnoreCase, d.Tolerance.IgnoreAccents, d.Tolerance.Typos)),
                });
                Model.ShowToast(new ToastMessage($"Standard für «{Tabs[_tab]}» wiederhergestellt", ToastTone.Success));
            }, IconName.RotateCcw, p.AccentText);
            yield return restore;
        }
    }

    // MARK: Daten

    IEnumerable<Control> DataTab()
    {
        var p = WsTheme.P;
        var sets = Model.Sets;
        long? bytes = null;
        try
        {
            if (File.Exists(Model.DataPath)) bytes = new FileInfo(Model.DataPath).Length;
        }
        catch (IOException) { }
        yield return Section("Backup",
            Row("Backup exportieren", Ui.Secondary("Exportieren …", () => _ = ExportBackup(Model, Window), IconName.Download),
                "Alle Lernsets, dein Fortschritt und deine Einstellungen als Datei. Sie lässt sich auch in der Web- und der Mac-App laden."),
            Row("Backup importieren", Ui.Secondary("Laden …", () => _ = ImportBackup(Model, Window), IconName.Upload),
                "Lernsets aus einer Backup-Datei (.json) hinzufügen – vorhandene bleiben erhalten."));
        yield return Section("Auf diesem Computer",
            Row("Speicherort", Ui.Text(Model.DataPath, 12.5, color: p.TextTertiary, wrap: TextWrapping.Wrap), LibrarySummary(sets, bytes)),
            Row("Neu beginnen", Ui.Danger("Alle Daten löschen …", AskDeleteAll), "Entfernt Lernsets, Fortschritt, Statistik und Einstellungen."));
        yield return Section("Info",
            Row("Version", Ui.Text(typeof(SettingsScreen).Assembly.GetName().Version?.ToString(3) ?? "", 14, FontWeight.SemiBold), "Windows-App"));
    }

    /// <summary>"Gespeichert: 3 Lernsets · 120 Begriffe · ca. 24 KB" (Mac: SettingsCopy.librarySummary).</summary>
    static string LibrarySummary(List<VocabSet> sets, long? bytes)
    {
        if (sets.Count == 0) return "Noch keine Lernsets gespeichert.";
        var parts = new List<string> { Labels.Plural(sets.Count, "Lernset", "Lernsets"), Labels.Plural(sets.Sum(s => s.Cards.Count), "Begriff", "Begriffe") };
        if (bytes is { } b)
            parts.Add(b < 1024 ? "unter 1 KB" : b < 1024 * 1024 ? $"ca. {Math.Round(b / 1024.0)} KB" : $"ca. {(b / (1024.0 * 1024)).ToString("0.0", System.Globalization.CultureInfo.GetCultureInfo("de-CH")).Replace('.', ',')} MB");
        return "Gespeichert: " + string.Join(" · ", parts);
    }

    /// <summary>
    /// "Wie Windows", "Hell", "Dunkel" as little window sketches with an accent ring on the chosen one (Mac:
    /// SettingsAppearancePicker; "Wie Windows" is half light, half dark along the diagonal).
    /// </summary>
    static Control AppearancePicker(ThemeSetting selected, Action<ThemeSetting> choose)
    {
        var p = WsTheme.P;
        var row = Ui.H(16);
        foreach (var (theme, label) in new[] { (ThemeSetting.System, "Wie Windows"), (ThemeSetting.Light, "Hell"), (ThemeSetting.Dark, "Dunkel") })
        {
            bool isSelected = theme == selected;
            var sketch = new AppearanceSketch(theme) { Width = 72, Height = 48 };
            var frame = new Border
            {
                Child = new Border { Child = sketch, CornerRadius = new CornerRadius(7), ClipToBounds = true, BorderBrush = WsTheme.B(p.Hairline), BorderThickness = new Thickness(1) },
                Padding = new Thickness(3),
                CornerRadius = new CornerRadius(10),
                BorderBrush = WsTheme.B(isSelected ? p.Accent : Colors.Transparent),
                BorderThickness = new Thickness(3),
            };
            var text = Ui.Text(label, 13.5, isSelected ? FontWeight.SemiBold : FontWeight.Normal, isSelected ? p.Text : p.TextSecondary);
            text.HorizontalAlignment = HorizontalAlignment.Center;
            var option = Ui.Clickable(Ui.V(6, frame, text), () => choose(theme), label, 12, padding: new Thickness(4));
            option.HorizontalAlignment = HorizontalAlignment.Left;
            option.Focusable = true;
            ToolTip.SetTip(option, theme switch
            {
                ThemeSetting.System => "Folgt der Windows-Einstellung (Hell oder Dunkel)",
                ThemeSetting.Light => "Immer hell",
                _ => "Immer dunkel",
            });
            row.Children.Add(option);
        }
        return row;
    }

    /// <summary>A tiny window: backdrop, a floating sidebar and a card (Mac: WindowSketch).</summary>
    sealed class AppearanceSketch(ThemeSetting theme) : Control
    {
        public override void Render(DrawingContext context)
        {
            var size = Bounds.Size;
            if (theme == ThemeSetting.System)
            {
                Draw(context, size, Palette.Light);
                var half = new StreamGeometry();
                using (var g = half.Open())
                {
                    g.BeginFigure(new Point(size.Width, 0), true);
                    g.LineTo(new Point(size.Width, size.Height));
                    g.LineTo(new Point(0, size.Height));
                    g.EndFigure(true);
                }
                using (context.PushGeometryClip(half)) Draw(context, size, Palette.DarkPalette);
            }
            else Draw(context, size, theme == ThemeSetting.Dark ? Palette.DarkPalette : Palette.Light);
        }

        static void Draw(DrawingContext context, Size size, Palette p)
        {
            context.FillRectangle(new SolidColorBrush(p.Backdrop), new Rect(size));
            context.FillRectangle(new SolidColorBrush(p.BackdropBlobs[0]), new Rect(0, 0, size.Width * 0.6, size.Height * 0.5));
            context.DrawRectangle(new SolidColorBrush(p.GlassStrong), null, new RoundedRect(new Rect(4, 4, 18, size.Height - 8), 4));
            context.DrawRectangle(new SolidColorBrush(p.GlassStrong), null, new RoundedRect(new Rect(26, 8, size.Width - 31, 18), 4));
            context.DrawRectangle(new SolidColorBrush(p.Accent), null, new RoundedRect(new Rect(26, 31, 16, 6), 3));
            context.DrawRectangle(new SolidColorBrush(p.Card), null, new RoundedRect(new Rect(45, 31, size.Width - 50, 6), 3));
        }
    }

    static Control Section(string title, params Control[] rows)
    {
        var stack = Ui.V(14, Ui.Text(title, 17, FontWeight.Bold));
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(Ui.Divider());
            stack.Children.Add(rows[i]);
        }
        return Ui.Glass(stack, 22, new Thickness(22, 18), strong: true);
    }

    static Control Row(string label, Control control, string? note)
    {
        var p = WsTheme.P;
        var left = Ui.V(3, Ui.Text(label, 14.5, FontWeight.SemiBold), note is null ? null : Ui.Text(note, 13, color: p.TextTertiary, wrap: TextWrapping.Wrap));
        control.VerticalAlignment = VerticalAlignment.Center;
        return Ui.Row(left, control, 20);
    }

    void AskDeleteAll()
    {
        var sets = Model.Sets;
        var terms = Labels.Plural(sets.Sum(s => s.Cards.Count), "Begriff", "Begriffen");
        var message = sets.Count switch
        {
            0 => "Deine Statistik und deine Einstellungen werden von diesem Computer gelöscht.",
            1 => $"Dein Lernset mit {terms}, dein Lernfortschritt, deine Statistik und deine Einstellungen werden von diesem Computer gelöscht.",
            _ => $"Alle {sets.Count} Lernsets mit {terms}, dein Lernfortschritt, deine Statistik und deine Einstellungen werden von diesem Computer gelöscht.",
        };
        Model.Ask(PromptRequest.Confirm("Alle Daten löschen?", message + " Exportiere vorher ein Backup, wenn du sie behalten willst.", "Alles löschen", () =>
        {
            Model.Store.ClearAll();
            Model.Store.Save();
            Model.ShowToast(new ToastMessage("Alle Daten gelöscht", ToastTone.Success));
        }, destructive: true));
    }

    // MARK: Files (also used by the overview and the set page)

    public static async Task ExportBackup(AppModel model, Window window)
    {
        var file = await window.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Backup exportieren",
            SuggestedFileName = Backup.BackupFileName(),
            DefaultExtension = "json",
            FileTypeChoices = [new FilePickerFileType("Wortschatz-Backup") { Patterns = ["*.json"] }],
        });
        if (file is null) return;
        await using var stream = await file.OpenWriteAsync();
        var data = Backup.JsonData(model.Store.ExportAll());
        await stream.WriteAsync(data);
        model.ShowToast(new ToastMessage("Backup gespeichert", ToastTone.Success));
    }

    public static async Task ImportBackup(AppModel model, Window window)
    {
        var files = await window.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Backup laden",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Wortschatz-Backup") { Patterns = ["*.json"] }, FilePickerFileTypes.All],
        });
        if (files.Count == 0) return;
        try
        {
            await using var stream = await files[0].OpenReadAsync();
            using var memory = new MemoryStream();
            await stream.CopyToAsync(memory);
            var json = Backup.ReadJSON(memory.ToArray());
            var summary = model.Store.ImportAll(json, ImportMode.Merge);
            model.Store.Save();
            var parts = new List<string>();
            if (summary.SetsAdded > 0) parts.Add($"{Labels.Plural(summary.SetsAdded, "Lernset", "Lernsets")} hinzugefügt");
            if (summary.SetsUpdated > 0) parts.Add($"{Labels.Plural(summary.SetsUpdated, "Lernset", "Lernsets")} aktualisiert");
            model.ShowToast(new ToastMessage(parts.Count > 0 ? string.Join(", ", parts) : "Nichts Neues im Backup", ToastTone.Success));
            model.ShowOverview();
        }
        catch (LibraryStoreError e)
        {
            model.ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 5000));
        }
        catch (Exception)
        {
            model.ShowToast(new ToastMessage(StoreMessages.NotBackup, ToastTone.Warning, DurationMs: 5000));
        }
    }

    public static async Task ExportText(AppModel model, Window window, VocabSet set)
    {
        var file = await window.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Als Text exportieren",
            SuggestedFileName = Backup.TextFileName(set.Title),
            DefaultExtension = "txt",
            FileTypeChoices = [new FilePickerFileType("Text (Tabulator getrennt)") { Patterns = ["*.txt"] }],
        });
        if (file is null) return;
        await using var stream = await file.OpenWriteAsync();
        await using var writer = new StreamWriter(stream);
        await writer.WriteAsync(Backup.SetToText(set));
        model.ShowToast(new ToastMessage("Als Text gespeichert", ToastTone.Success));
    }
}
