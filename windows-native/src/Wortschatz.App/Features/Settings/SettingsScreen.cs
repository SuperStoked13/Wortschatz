using Avalonia;
using Avalonia.Automation;
using Avalonia.Collections;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Settings;

/// <summary>
/// Einstellungen (Mac: SettingsView.swift with SettingsGeneralTab, SettingsStudyTabs, SettingsDataTab): appearance,
/// sounds and the voice per language; the study defaults of every set (Lernen, Schreiben, Toleranz); backups (export,
/// import with a preview and the choice to merge or replace – the same file format as the web and Mac apps, so sets move
/// between them, also by dropping a file on the Daten tab), where the data lives, and deleting everything. The open tab
/// is remembered (Mac: @AppStorage settings.selectedTab).
/// </summary>
public sealed class SettingsScreen(AppModel model, MainView window) : Screen(model, window)
{
    static readonly string[] Tabs = ["Allgemein", "Lernen", "Schreiben", "Toleranz", "Daten"];

    int Tab
    {
        get => Math.Clamp(Model.Preferences.SettingsTab, 0, Tabs.Length - 1);
        set => Model.Preferences.SettingsTab = value;
    }

    protected override Control Build()
    {
        var content = new StackPanel { Spacing = 18, Margin = new Thickness(34, 14, 34, 24), MaxWidth = 820, HorizontalAlignment = HorizontalAlignment.Left };
        int tab = Tab;
        var tabs = new WsSegmented(Tabs, tab, AppDevice.IsPhone ? 96 : 112) { HorizontalAlignment = HorizontalAlignment.Left };
        tabs.SelectionChanged += i =>
        {
            // A sample still being read stops with its tab (Mac: onDisappear of the Allgemein tab).
            Model.Speech.Stop();
            Tab = i;
            Refresh();
        };
        // Phone: the five tabs share the width (WsSegmented shrinks them; in a sideways scroller «Toleranz» and «Daten»
        // were cut off without a hint that there is more); the title is in the bar on top.
        Control tabRow = tabs;
        if (AppDevice.IsPhone)
        {
            tabs.HorizontalAlignment = HorizontalAlignment.Stretch;
            content.Margin = new Thickness(8, 4, 8, 24);
            content.HorizontalAlignment = HorizontalAlignment.Stretch;
            content.Children.Add(tabRow);
        }
        else content.Children.Add(Ui.V(14, Ui.V(4, Ui.Eyebrow("Wortschatz"), Ui.Title("Einstellungen")), tabRow));
        foreach (var section in tab switch
        {
            1 => LearnTab(),
            2 => WriteTab(),
            3 => ToleranceTab(),
            4 => DataTab(),
            _ => GeneralTab(),
        })
            content.Children.Add(section);
        var scroll = Ui.Scroll(content);
        return tab == 4 ? BackupDropTarget(scroll) : scroll;
    }

    public override void Deactivate() => Model.Speech.Stop();

    /// <summary>Writes a global default (Mac: SettingsWriter.update): a failure shows a toast.</summary>
    void UpdateSettings(SettingsPatch patch)
    {
        try
        {
            Model.Store.UpdateSettings(patch);
            Model.Store.Save();
        }
        catch (LibraryStoreError e)
        {
            Model.ShowToast(new ToastMessage(e.Message.Length > 0 ? e.Message : "Die Einstellung konnte nicht gespeichert werden.", ToastTone.Danger, DurationMs: 6000));
        }
        catch (Exception)
        {
            Model.ShowToast(new ToastMessage("Die Einstellung konnte nicht gespeichert werden.", ToastTone.Danger, DurationMs: 6000));
        }
    }

    void UpdateStudy(StudyOptionsPatch patch) => UpdateSettings(new SettingsPatch(Study: patch));

    // MARK: Allgemein

    IEnumerable<Control> GeneralTab()
    {
        var settings = Model.Store.GetSettings();
        var theme = AppearancePicker(settings.Theme, v =>
        {
            UpdateSettings(new SettingsPatch(v));
            Window.Rebuild();
        });
        yield return Section("Darstellung", Row("Erscheinungsbild", theme, settings.Theme switch
        {
            ThemeSetting.Light => "Immer helles Design.",
            ThemeSetting.Dark => "Immer dunkles Design – angenehm am Abend.",
            _ => $"Folgt {AppDevice.SystemName} – zurzeit {(Application.Current?.ActualThemeVariant == Avalonia.Styling.ThemeVariant.Dark ? "dunkel" : "hell")}.",
        }));

        var sounds = new WsSwitch(Model.Preferences.SoundEffects, "Soundeffekte");
        sounds.Toggled += on =>
        {
            Model.Preferences.SoundEffects = on;
            if (on) Model.Sounds.Play(Services.SoundEffects.Sound.Correct);
        };
        yield return Section("Töne", Row("Soundeffekte", sounds, "Leise Töne für richtige und falsche Antworten, Serien und geschaffte Runden."));

        var rows = new List<Control>();
        foreach (var lang in VoiceLanguages) rows.Add(VoiceRow(lang));
        var open = Ui.Secondary($"{AppDevice.SystemName}-Einstellungen öffnen", OpenSpeechSettings, IconName.Gear, height: 36);
        rows.Add(Row("Weitere Stimmen", open, AppDevice.IsPhone
            ? "Weitere Stimmen lädst du in den Android-Einstellungen unter Sprache › Sprachausgabe (Text-in-Sprache) herunter. Danach Wortschatz neu starten."
            : "Weitere Stimmen fügst du in den Windows-Einstellungen unter Zeit und Sprache › Sprachausgabe › Stimmen hinzufügen. Danach Wortschatz neu starten."));
        yield return Section("Stimmen zum Vorlesen", [.. rows]);
    }

    /// <summary>The languages with a voice choice, in the order of the language pickers (without «Andere»).</summary>
    public static readonly Lang[] VoiceLanguages = Labels.LANG_ORDER.Where(l => l != Lang.Other).ToArray();

    /// <summary>
    /// One language's voice: "Automatisch (Microsoft Karsten)" or a chosen installed voice, best first, plus a sample to
    /// listen to (Mac: SettingsVoiceRow). A chosen voice that is no longer installed shows as automatic.
    /// </summary>
    Control VoiceRow(Lang lang)
    {
        var p = WsTheme.P;
        var name = Labels.LangName(lang);
        var speech = Model.Speech;
        var options = speech.VoicesFor(lang);
        var automatic = speech.AutomaticVoice(lang);
        var chosenId = speech.PreferredVoiceIds.GetValueOrDefault(lang);
        int selected = Math.Max(0, options.FindIndex(v => v.Id == chosenId) + 1);
        var picker = new ComboBox { MinWidth = 260, MaxWidth = 340, IsEnabled = options.Count > 0 };
        picker.Items.Add(new ComboBoxItem { Content = automatic is null ? "Keine Stimme installiert" : $"Automatisch ({automatic.Name})" });
        foreach (var voice in options) picker.Items.Add(new ComboBoxItem { Content = SpeechText.DisplayName(voice) });
        picker.SelectedIndex = selected;
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedIndex < 0 || picker.SelectedIndex == selected) return;
            selected = picker.SelectedIndex;
            speech.SetPreferredVoice(lang, selected == 0 ? null : options[selected - 1].Id);
        };
        AutomationProperties.SetName(picker, $"Stimme für {name}");
        var sample = Ui.IconButton(IconName.Speaker, "Probe hören", () => speech.Speak(VoiceSample(lang), lang), 34);
        AutomationProperties.SetName(sample, $"Probe hören auf {name}");
        sample.IsEnabled = options.Count > 0;
        Control control;
        if (!AppDevice.IsPhone) control = Ui.H(8, picker, sample);
        else
        {
            // Phone: the list takes the width beside the speaker button.
            picker.MinWidth = 0;
            picker.MaxWidth = double.PositiveInfinity;
            picker.HorizontalAlignment = HorizontalAlignment.Stretch;
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 8 };
            row.Children.Add(picker);
            Grid.SetColumn(sample, 1);
            row.Children.Add(sample);
            row.HorizontalAlignment = HorizontalAlignment.Stretch;
            control = row;
        }
        var voiceRow = Row(name, control, options.Count == 0 ? "Keine Stimme installiert – wird nicht vorgelesen." : null);
        if (options.Count == 0 && voiceRow is Panel { Children: [StackPanel { Children: [_, TextBlock hint] }, ..] }) hint.Foreground = WsTheme.B(p.Warning.Text);
        if (AppDevice.IsPhone && voiceRow is StackPanel stacked && stacked.Children.Count > 1) stacked.Children[1].HorizontalAlignment = HorizontalAlignment.Stretch;
        return voiceRow;
    }

    /// <summary>A short sentence to listen to a voice with (Mac: SettingsVoiceCatalog.sample).</summary>
    public static string VoiceSample(Lang lang) => lang switch
    {
        Lang.Fr => "Bonjour ! Aujourd'hui, nous apprenons de nouveaux mots.",
        Lang.En => "Hello! Today we're learning some new words.",
        Lang.Es => "¡Hola! Hoy aprendemos palabras nuevas.",
        Lang.It => "Ciao! Oggi impariamo parole nuove.",
        Lang.Ar => "مرحبًا! اليوم نتعلّم كلمات جديدة.",
        Lang.Zh => "你好！今天我们学习新词。",
        _ => "Hallo! Heute lernen wir neue Wörter.",
    };

    void OpenSpeechSettings()
    {
        if (AppDevice.OpenSpeechSettings is { } open)
        {
            try { open(); }
            catch (Exception) { Model.ShowToast(new ToastMessage("Die Einstellungen konnten nicht geöffnet werden.", ToastTone.Warning)); }
            return;
        }
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

    static Control Switch(bool value, Action<bool> set, bool enabled = true, string? disabledTip = null)
    {
        var s = new WsSwitch(value, "");
        s.Toggled += set;
        s.IsEnabled = enabled;
        if (!enabled && disabledTip is not null) ToolTip.SetTip(s, disabledTip);
        return s;
    }

    /// <summary>Lernen: question types, terms per round, the answer direction, the copy step and read-aloud.</summary>
    IEnumerable<Control> LearnTab()
    {
        var options = Model.Store.GetSettings().Study;
        var learn = options.Learn;
        var names = LearnOptionsCopy.SideNames(Lang.Other, SharedDefLang(Model.Sets));
        bool mcLocked = learn.Mc && !learn.Written, writtenLocked = learn.Written && !learn.Mc;
        yield return Form.Section("Fragetypen",
        [
            Form.Row("Multiple Choice", Switch(learn.Mc, v => UpdateStudy(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Mc: v))), !mcLocked, LearnOptionsCopy.LockHint),
                "Vier Antworten zur Auswahl"),
            Form.Row("Schriftlich", Switch(learn.Written, v => UpdateStudy(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Written: v))), !writtenLocked, LearnOptionsCopy.LockHint),
                "Antwort selbst eintippen"),
        ], LearnOptionsCopy.QuestionTypesHint(learn));
        yield return Form.Section("Abfrage",
        [
            Form.Row(LearnOptionsCopy.RoundSizeLabel, StudyChrome.Choice<int>(LearnOptionsCopy.RoundSizes(learn.RoundSize).Select(s => (s, $"{s}")).ToList(), learn.RoundSize,
                v => UpdateStudy(new StudyOptionsPatch(Learn: new LearnOptionsPatch(RoundSize: v)))), LearnOptionsCopy.RoundSizeNote),
            Form.Row("Antworten auf", StudyChrome.Choice<AnswerWith>([(AnswerWith.Term, names.Term.Label), (AnswerWith.Definition, names.Definition.Label), (AnswerWith.Both, "Beides")],
                options.AnswerWith, v => UpdateStudy(new StudyOptionsPatch(AnswerWith: v)))),
        ], DirectionText(options.AnswerWith, names));
        yield return Form.Section(null,
        [
            Form.Row("Richtige Antwort abtippen", Switch(learn.Retype, v => UpdateStudy(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Retype: v)))),
                "Nach einem Fehler bei einer schriftlichen Frage tippst du die Lösung einmal ab."),
            Form.Row("Vorlesen", Switch(options.Audio, v => UpdateStudy(new StudyOptionsPatch(Audio: v))),
                "Begriffe in der Lernsprache automatisch vorlesen. Gilt auch für Schreiben."),
        ]);
        // Wiederholungsfragen and Nachkontrolle hold for every set (also switchable in the options while learning).
        var preferences = Model.Preferences;
        yield return Form.Section("Wiederholung",
        [
            Form.Row(LearnOptionsCopy.ReviewLabel, Switch(preferences.LearnReview, v => preferences.LearnReview = v), LearnOptionsCopy.ReviewNote),
            Form.Row(LearnOptionsCopy.RecheckLabel, Switch(preferences.LearnRecheck, v => preferences.LearnRecheck = v), LearnOptionsCopy.RecheckNote),
        ], LearnOptionsCopy.GlobalSwitchesFooter);
        var d = StudyOptions.Default;
        yield return DefaultsFooter(options.AnswerWith == d.AnswerWith && options.Audio == d.Audio && options.Learn == d.Learn,
            new StudyOptionsPatch(AnswerWith: d.AnswerWith, Audio: d.Audio,
                Learn: new LearnOptionsPatch(d.Learn.RoundSize, d.Learn.Mc, d.Learn.Written, d.Learn.Retype)), "Lernen");
    }

    /// <summary>Schreiben: shuffling, the copy step after a miss and auto-advance.</summary>
    IEnumerable<Control> WriteTab()
    {
        var options = Model.Store.GetSettings().Study;
        yield return Form.Section("Jede Karte schriftlich",
        [
            Form.Row("Mischen", Switch(options.Shuffle, v => UpdateStudy(new StudyOptionsPatch(Shuffle: v))), "Karten in zufälliger Reihenfolge abfragen."),
            Form.Row("Richtige Antwort abtippen", Switch(options.CopyAnswer, v => UpdateStudy(new StudyOptionsPatch(CopyAnswer: v))), "Nach einem Fehler tippst du die Lösung einmal ab."),
            Form.Row("Automatisch weiter", Switch(options.AutoAdvance, v => UpdateStudy(new StudyOptionsPatch(AutoAdvance: v))), "Nach einer richtigen Antwort geht es von selbst weiter."),
        ]);
        var d = StudyOptions.Default;
        yield return DefaultsFooter(options.Shuffle == d.Shuffle && options.CopyAnswer == d.CopyAnswer && options.AutoAdvance == d.AutoAdvance,
            new StudyOptionsPatch(Shuffle: d.Shuffle, CopyAnswer: d.CopyAnswer, AutoAdvance: d.AutoAdvance), "Schreiben");
    }

    /// <summary>Toleranz: the seven grading switches, each with an example in the language all sets are learned in.</summary>
    IEnumerable<Control> ToleranceTab()
    {
        var options = Model.Store.GetSettings().Study;
        var termLangs = Model.Sets.Select(s => s.TermLang).Distinct().ToList();
        var termLang = termLangs.Count == 1 ? termLangs[0] : Lang.Other;
        yield return Form.Section("Was trotzdem als richtig zählt",
            LearnOptionsCopy.ToleranceItems(termLang).Select(item =>
                Form.Row(item.Label, Switch(item.Get(options.Tolerance), v => UpdateStudy(new StudyOptionsPatch(Tolerance: item.Patch(v)))), item.Example)).ToList());
        var d = StudyOptions.Default.Tolerance;
        yield return DefaultsFooter(options.Tolerance == d,
            new StudyOptionsPatch(Tolerance: new TolerancePatch(d.Articles, d.Abbreviations, d.MultipleAnswers, d.Parentheses, d.IgnoreCase, d.IgnoreAccents, d.Typos)), "Toleranz");
    }

    /// <summary>
    /// The note under the study tabs with "Standard wiederherstellen", disabled while the tab already shows the defaults
    /// (Mac: SettingsDefaultsFooter, SettingsWriter.restoreDefaults).
    /// </summary>
    Control DefaultsFooter(bool isDefault, StudyOptionsPatch defaults, string scope)
    {
        var p = WsTheme.P;
        var note = Ui.Text("Gilt für alle Lernsets. Was du in den Optionen eines Lernsets umstellst, gilt nur für dieses Lernset."
            + OwnOptionsText(), 13, color: p.TextSecondary, wrap: TextWrapping.Wrap);
        note.VerticalAlignment = VerticalAlignment.Center;
        var restore = Ui.Secondary("Standard wiederherstellen", () =>
        {
            try
            {
                Model.Store.UpdateSettings(new SettingsPatch(Study: defaults));
                Model.Store.Save();
                Model.ShowToast(new ToastMessage($"{scope}: Standardwerte wiederhergestellt", ToastTone.Success));
            }
            catch (Exception)
            {
                Model.ShowToast(new ToastMessage("Die Standardwerte konnten nicht wiederhergestellt werden.", ToastTone.Danger, DurationMs: 6000));
            }
        }, IconName.RotateCcw, height: 34);
        restore.IsEnabled = !isDefault;
        ToolTip.SetTip(restore, isDefault ? "Es sind bereits die Standardwerte eingestellt." : "Setzt die Einstellungen dieses Bereichs auf die Standardwerte zurück.");
        ToolTip.SetShowOnDisabled(restore, true);
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16, Margin = new Thickness(14, 0) };
        row.Children.Add(note);
        Grid.SetColumn(restore, 1);
        row.Children.Add(restore);
        return row;
    }

    /// <summary>
    /// " Eigene Optionen haben: «Unité 3», «Unité 4»." – the sets whose options differ from the standard (they keep their
    /// own when the standard changes; the set's options show what differs and can reset it). Empty when there are none.
    /// </summary>
    string OwnOptionsText()
    {
        var standard = Model.Store.GetSettings().Study;
        var own = Model.Sets
            .Where(set => set.StudyOptions is not null && LearnOptionsCopy.Deviations(Model.Store.GetStudyOptions(set.Id), standard,
                LearnOptionsCopy.SideNames(set.TermLang, set.DefLang), set.TermLang).Count > 0)
            .Select(set => $"«{AppModel.ShortTitle(set.Title)}»")
            .ToList();
        if (own.Count == 0) return "";
        var list = own.Count <= 3 ? string.Join(", ", own) : $"{string.Join(", ", own.Take(3))} und {own.Count - 3} weitere";
        return $" Eigene Optionen haben: {list}.";
    }

    /// <summary>The translation side is named by its language only when all sets share it (an empty library counts as
    /// Deutsch); otherwise "Übersetzung" (Mac: SettingsCopy.sharedDefLang).</summary>
    static Lang SharedDefLang(List<VocabSet> sets)
    {
        var langs = sets.Select(s => s.DefLang).Distinct().ToList();
        return langs.Count == 0 ? Lang.De : langs.Count == 1 ? langs[0] : Lang.Other;
    }

    /// <summary>What the learner sees and answers (Mac: SettingsCopy.directionText; "Beides" names both modes).</summary>
    static string DirectionText(AnswerWith answerWith, (LearnOptionsCopy.Side Term, LearnOptionsCopy.Side Definition) names) => answerWith == AnswerWith.Both
        ? "Schreiben fragt jede Karte in beide Richtungen ab, Lernen wechselt die Richtung zufällig."
        : LearnOptionsCopy.DirectionText(answerWith, names);

    // MARK: Daten

    IEnumerable<Control> DataTab()
    {
        var p = WsTheme.P;
        var sets = Model.Sets;
        int? bytes = null;
        try { bytes = Backup.JsonData(Model.Store.ExportAll()).Length; }
        catch (Exception) { }
        yield return Section("Backup",
        [
            Row("Backup exportieren", Ui.Secondary("Exportieren …", () => _ = ExportBackup(Model, Window), IconName.Upload),
                "Alle Lernsets, dein Fortschritt und deine Einstellungen als Datei."),
            Row("Backup importieren", Ui.Secondary("Importieren …", () => _ = BackupImportSheet.Choose(Model, Window), IconName.Download),
                AppDevice.IsPhone ? "Eine Backup-Datei (.json) wählen." : "Eine Backup-Datei (.json) wählen oder hierher ziehen."),
        ], LibrarySummary(sets, bytes));

        var file = Model.Store.Backend is FileBackend f ? f.Path : null;
        var reveal = Ui.Secondary("Im Explorer zeigen", RevealLibrary);
        reveal.IsEnabled = file is not null;
        AutomationProperties.SetName(reveal, "Speicherort im Explorer zeigen");
        var folder = file is null ? "Diese Bibliothek liegt nur im Arbeitsspeicher und wird nicht gesichert." : System.IO.Path.GetDirectoryName(file) ?? file;
        // Phone: the app's own folder, which no file manager shows; backups go through «Backup exportieren».
        var location = AppDevice.IsPhone
            ? Row("Speicherort", new Border(), "Im Speicher der App auf diesem Gerät. Sichere deine Lernsets mit «Backup exportieren».")
            : Row("Speicherort", reveal, folder);
        if (file is not null) ToolTip.SetTip(location, file);
        yield return Section(AppDevice.IsPhone ? "Auf diesem Gerät" : "Auf diesem Computer",
            location,
            Row("Neu beginnen", Ui.Danger("Alle Daten löschen …", () => SettingsWipeSheet.Show(Model, Window)), "Entfernt Lernsets, Fortschritt, Statistik und Einstellungen."));
        yield return Section("Info",
            Row("Version", Ui.Text(typeof(SettingsScreen).Assembly.GetName().Version?.ToString(3) ?? "", 14, FontWeight.SemiBold), AppDevice.AppLabel));
    }

    /// <summary>"Gespeichert: 3 Lernsets · 120 Begriffe · ca. 24 KB" (Mac: SettingsCopy.librarySummary, the size of a backup).</summary>
    public static string LibrarySummary(IReadOnlyList<VocabSet> sets, int? bytes)
    {
        if (sets.Count == 0) return "Noch keine Lernsets gespeichert.";
        var parts = new List<string> { Labels.Plural(sets.Count, "Lernset", "Lernsets"), Labels.Plural(sets.Sum(s => s.Cards.Count), "Begriff", "Begriffe") };
        if (bytes is { } b) parts.Add(FormatBytes(b));
        return "Gespeichert: " + string.Join(" · ", parts);
    }

    /// <summary>"unter 1 KB", "ca. 24 KB", "ca. 1,2 MB" (Mac: SettingsCopy.formatBytes).</summary>
    public static string FormatBytes(int bytes)
    {
        if (bytes < 1024) return "unter 1 KB";
        if (bytes < 1024 * 1024) return $"ca. {(int)Math.Round(bytes / 1024.0, MidpointRounding.AwayFromZero)} KB";
        var megabytes = Math.Round(bytes / (1024.0 * 1024) * 10, MidpointRounding.AwayFromZero) / 10;
        return "ca. " + megabytes.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture).Replace('.', ',') + " MB";
    }

    /// <summary>Shows the library file in the Explorer (its folder if nothing was saved yet). Mac: revealLibrary.</summary>
    void RevealLibrary()
    {
        if (Model.Store.Backend is not FileBackend f) return;
        Model.Flush();
        try
        {
            var start = File.Exists(f.Path)
                ? new System.Diagnostics.ProcessStartInfo("explorer.exe", $"/select,\"{f.Path}\"")
                : new System.Diagnostics.ProcessStartInfo(System.IO.Path.GetDirectoryName(f.Path)!) { UseShellExecute = true };
            System.Diagnostics.Process.Start(start);
        }
        catch (Exception)
        {
            Model.ShowToast(new ToastMessage("Der Speicherort konnte nicht geöffnet werden.", ToastTone.Warning));
        }
    }

    /// <summary>
    /// The Daten tab takes a dropped backup file (Mac: dropDestination with SettingsDropHighlight): while a file is over
    /// it, a dashed frame says "Backup hier ablegen".
    /// </summary>
    Control BackupDropTarget(Control content)
    {
        var p = WsTheme.P;
        var label = new Border
        {
            Child = Ui.H(8, Icons.Icon(IconName.Download, 17, p.AccentText, 2), Ui.Text("Backup hier ablegen", 15, FontWeight.SemiBold, p.AccentText)),
            Background = WsTheme.B(p.GlassStrong),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(16, 8),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var frame = new Rectangle
        {
            Stroke = WsTheme.B(p.Accent),
            StrokeThickness = 2,
            StrokeDashArray = new AvaloniaList<double> { 4, 3 },
            RadiusX = 22,
            RadiusY = 22,
            Fill = WsTheme.B(p.AccentSoft),
        };
        var highlight = new Grid { Margin = new Thickness(12), IsHitTestVisible = false, IsVisible = false };
        highlight.Children.Add(frame);
        highlight.Children.Add(label);
        var host = new Grid { Background = Brushes.Transparent };
        host.Children.Add(content);
        host.Children.Add(highlight);
        DragDrop.SetAllowDrop(host, true);
        host.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            bool files = e.DataTransfer.Contains(DataFormat.File);
            e.DragEffects = files ? DragDropEffects.Copy : DragDropEffects.None;
            highlight.IsVisible = files;
        });
        host.AddHandler(DragDrop.DragLeaveEvent, (_, _) => highlight.IsVisible = false);
        host.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            highlight.IsVisible = false;
            if (e.DataTransfer.TryGetFiles()?.OfType<IStorageFile>().FirstOrDefault() is not { } file) return;
            e.Handled = true;
            _ = BackupImportSheet.Prepare(Model, Window, file);
        });
        return host;
    }

    /// <summary>
    /// "Wie Windows", "Hell", "Dunkel" as little window sketches with an accent ring on the chosen one (Mac:
    /// SettingsAppearancePicker; "Wie Windows" is half light, half dark along the diagonal).
    /// </summary>
    static Control AppearancePicker(ThemeSetting selected, Action<ThemeSetting> choose)
    {
        var p = WsTheme.P;
        var row = Ui.H(16);
        foreach (var (theme, label) in new[] { (ThemeSetting.System, AppDevice.IsPhone ? "Wie System" : "Wie Windows"), (ThemeSetting.Light, "Hell"), (ThemeSetting.Dark, "Dunkel") })
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
            AutomationProperties.SetItemStatus(option, isSelected ? "ausgewählt" : "");
            ToolTip.SetTip(option, theme switch
            {
                ThemeSetting.System => $"Folgt der {AppDevice.SystemName}-Einstellung (Hell oder Dunkel)",
                ThemeSetting.Light => "Immer helles Design.",
                _ => "Immer dunkles Design – angenehm am Abend.",
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

    static Control Section(string title, params Control[] rows) => Section(title, rows, null);

    /// <summary>A titled glass panel with rows; the footer (with an info symbol) under the rows (Mac: Section footer).</summary>
    static Control Section(string title, Control[] rows, string? footer)
    {
        var p = WsTheme.P;
        var stack = Ui.V(14, Ui.Text(title, 17, FontWeight.Bold));
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(Ui.Divider());
            stack.Children.Add(rows[i]);
        }
        if (footer is not null)
        {
            stack.Children.Add(Ui.Divider());
            stack.Children.Add(Ui.H(8, Icons.Icon(IconName.Info, 15, p.TextTertiary), Ui.Text(footer, 13, color: p.TextSecondary, wrap: TextWrapping.Wrap)));
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

    // MARK: Files (also used by the overview, the set page and the window's save prompt)

    /// <summary>"Backup exportieren …": the save dialog, then "Backup gespeichert: wortschatz-backup-2026-11-03.json".</summary>
    public static async Task ExportBackup(AppModel model, MainView window)
    {
        byte[] data;
        try
        {
            data = Backup.JsonData(model.Store.ExportAll());
        }
        catch (Exception)
        {
            model.ShowToast(new ToastMessage("Das Backup konnte nicht erstellt werden.", ToastTone.Danger, DurationMs: 6000));
            return;
        }
        try
        {
            var file = await window.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Backup exportieren",
                SuggestedFileName = Backup.BackupFileName(timeZone: model.Store.TimeZone),
                DefaultExtension = "json",
                FileTypeChoices = [new FilePickerFileType("Wortschatz-Backup") { Patterns = ["*.json"] }],
            });
            if (file is null) return;
            await using (var stream = await file.OpenWriteAsync())
            {
                if (stream.CanSeek) stream.SetLength(0);
                await stream.WriteAsync(data);
            }
            model.ShowToast(new ToastMessage($"Backup gespeichert: {file.Name}", ToastTone.Success));
        }
        catch (Exception)
        {
            model.ShowToast(new ToastMessage("Das Backup konnte nicht gespeichert werden.", ToastTone.Danger, DurationMs: 6000));
        }
    }

    /// <summary>"Backup laden": the file chooser, then the import sheet with its preview (BackupImportSheet).</summary>
    public static Task ImportBackup(AppModel model, MainView window) => BackupImportSheet.Choose(model, window);

    /// <summary>"Als Text exportieren …": the sheet with separators, preview, "Kopieren" and "Sichern …".</summary>
    public static Task ExportText(AppModel model, MainView window, VocabSet set)
    {
        SetDetail.TextExportSheet.Show(model, window, set);
        return Task.CompletedTask;
    }
}
