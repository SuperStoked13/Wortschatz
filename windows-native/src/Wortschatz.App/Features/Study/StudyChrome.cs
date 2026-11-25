using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Study;

/// <summary>
/// The parts every study screen shares (Mac: StudyChrome in LearnScreen/WriteScreen, LearnActionBar.swift,
/// KeyHint.swift): the top row (back pill with the set's title, the progress capsule, speaker and options buttons),
/// the floating action bar at the bottom, the dialog layer and the options panel.
/// </summary>
public static class StudyChrome
{
    static Palette P => WsTheme.P;

    /// <summary>"‹ Unité 3 – Les personnes" (Esc).</summary>
    public static Control BackPill(string title, Action onBack)
    {
        // Phone: only the chevron (the title would take the room of the progress capsule).
        if (AppDevice.IsPhone)
        {
            var back = Ui.IconButton(IconName.ChevronLeft, L("Zurück zum Lernset"), onBack, 40, ButtonKind.Glass, P.Text);
            return back;
        }
        var b = new WsButton(Ui.H(4, Icons.Icon(IconName.ChevronLeft, 18, P.Text, 2), Ui.Text(title, 14, FontWeight.SemiBold)), ButtonKind.Glass, 38,
            padding: new Thickness(10, 0, 16, 0));
        b.Click += (_, _) => onBack();
        b.MaxWidth = 340;
        ToolTip.SetTip(b, L("Zurück zum Lernset (Esc)"));
        Avalonia.Automation.AutomationProperties.SetName(b, L("Zurück zum Lernset"));
        return b;
    }

    /// <summary>The top row of a study screen: left, centre and right parts.</summary>
    public static Control TopRow(Control left, Control? center, Control? right)
    {
        // Phone: the centre takes what the sides leave (no room for equal sides).
        var g = AppDevice.IsPhone
            ? new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 6, Margin = new Thickness(0, 6, 0, 0) }
            : new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,*"), Margin = new Thickness(24, 6, 24, 0) };
        // Phone: a capsule wider than the room left shrinks a little instead of running under the buttons.
        if (AppDevice.IsPhone && center is not null)
            center = new Viewbox { Child = center, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Center };
        left.HorizontalAlignment = HorizontalAlignment.Left;
        g.Children.Add(left);
        if (center is not null)
        {
            Grid.SetColumn(center, 1);
            g.Children.Add(center);
        }
        if (right is not null)
        {
            right.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(right, 2);
            g.Children.Add(right);
        }
        return g;
    }

    /// <summary>
    /// A button floating on the backdrop (Mac: <c>.buttonStyle(.glass)</c> in the study action bars): its glass casts a
    /// soft shadow, so it stands on its own instead of sitting in a shared bar.
    /// </summary>
    public static WsButton Floating(WsButton button)
    {
        if (button.Chrome.BoxShadow.Count == 0)
            button.Chrome.BoxShadow = BoxShadows.Parse($"0 6 18 -8 {WsButton.Hex(P.Shadow, Math.Min(1, P.Shadow.A / 255.0 * 1.1))}");
        return button;
    }

    /// <summary>A round glass icon button for the action bar (↶ Zurück).</summary>
    public static WsButton FloatingIconButton(IconName icon, string tooltip, Action onClick) =>
        Floating(Ui.IconButton(icon, tooltip, onClick, 44, ButtonKind.Glass, P.Text));

    /// <summary>
    /// "Karte bearbeiten" (Mac: LearnCardEditor / WriteCardEditor): both sides of a card in text fields; Enter saves,
    /// Esc cancels. <paramref name="focus"/>: the side that gets the keyboard first (Schreiben: the side the learner had
    /// to type, usually the one to fix).
    /// </summary>
    public static Control CardEditor(VocabSet set, Card card, Action<string, string> onSave, Action onCancel, out Action save, AskSide focus = AskSide.Term)
    {
        var (termLabel, defLabel) = WriteFlow.EditorLabels(set.TermLang, set.DefLang);
        var term = Ui.Field(termLabel, card.Term);
        var def = Ui.Field(defLabel, card.Definition);
        if (set.TermLang.IsRTL()) term.FlowDirection = FlowDirection.RightToLeft;
        if (set.DefLang.IsRTL()) def.FlowDirection = FlowDirection.RightToLeft;
        // A side may not be empty: a hint under the field and "Sichern" is disabled until both are filled.
        var termError = Ui.Text(L("Bitte gib den Begriff ein."), 13, FontWeight.Medium, P.Failure.Text);
        var defError = Ui.Text(L("Bitte gib die Definition ein."), 13, FontWeight.Medium, P.Failure.Text);
        bool Valid() => JSCompat.Trim(term.Text ?? "").Length > 0 && JSCompat.Trim(def.Text ?? "").Length > 0;
        Action doSave = () =>
        {
            if (Valid()) onSave(term.Text ?? "", def.Text ?? "");
        };
        save = doSave;
        var saveButton = Ui.Primary(L("Sichern"), doSave, "↵", height: 40);
        void Update()
        {
            termError.IsVisible = JSCompat.Trim(term.Text ?? "").Length == 0;
            defError.IsVisible = JSCompat.Trim(def.Text ?? "").Length == 0;
            saveButton.IsEnabled = Valid();
            saveButton.Opacity = saveButton.IsEnabled ? 1 : 0.45;
        }
        term.TextChanged += (_, _) => Update();
        def.TextChanged += (_, _) => Update();
        Update();
        var buttons = Ui.H(10, Ui.Secondary(L("Abbrechen"), onCancel, keyHint: "Esc"), saveButton);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        var c = Ui.Hero(Ui.V(14, Ui.Text(L("Karte bearbeiten"), 20, FontWeight.Bold), Ui.Eyebrow(termLabel), term, termError, Ui.Eyebrow(defLabel), def, defError, buttons), new Thickness(26, 22), 24);
        c.Width = 480;
        var first = focus == AskSide.Definition ? def : term;
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            first.Focus();
            first.CaretIndex = first.Text?.Length ?? 0;
        }, Avalonia.Threading.DispatcherPriority.Input);
        return c;
    }

    /// <summary>A dimmed layer with a centred glass card (prompts, panels). Click outside = cancel.</summary>
    public static Control Overlay(Control card, Action onCancel)
    {
        var dim = new Border { Background = WsTheme.B(P.Dark ? Palette.Hex(0x000000, 0.45) : Palette.Hex(0x1C1D26, 0.18)) };
        dim.PointerPressed += (_, e) =>
        {
            if (e.Source == dim) onCancel();
        };
        card.HorizontalAlignment = HorizontalAlignment.Center;
        card.VerticalAlignment = VerticalAlignment.Center;
        // A sheet over the screen: nearly opaque, so the card under it does not show through (the Mac's sheets blur).
        if (card is Border sheet) sheet.Background = WsTheme.B(P.Dark ? Palette.Hex(0x2E3142, 0.97) : Palette.Hex(0xFBFBFE, 0.96));
        var g = new Grid();
        g.Children.Add(dim);
        g.Children.Add(card);
        return g;
    }

    /// <summary>A yes/no question (Mac: alert). Enter confirms (cancels when destructive), Esc cancels.</summary>
    public static Control PromptCard(string title, string message, string confirm, string cancel, bool destructive, Action<bool> answer)
    {
        var buttons = Ui.H(10,
            destructive ? Ui.Danger(confirm, () => answer(true), null) : Ui.Primary(confirm, () => answer(true), "↵", height: 40),
            Ui.Secondary(cancel, () => answer(false), keyHint: destructive ? "↵" : "Esc"));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        var body = Ui.V(14, Ui.Text(title, 20, FontWeight.Bold), Ui.Text(message, 14.5, color: P.TextSecondary, wrap: TextWrapping.Wrap), buttons);
        var card = Ui.Hero(body, new Thickness(26, 22), 24);
        card.Width = 480;
        return card;
    }

    /// <summary>A choice among a few values as a segmented control (Mac: <c>.pickerStyle(.segmented)</c>).</summary>
    public static Control Choice<T>(IReadOnlyList<(T Value, string Label)> items, T selected, Action<T> changed)
    {
        int index = Math.Max(0, items.ToList().FindIndex(i => EqualityComparer<T>.Default.Equals(i.Value, selected)));
        double width = Math.Max(48, Math.Min(110, items.Max(i => i.Label.Length) * 8.5 + 24));
        var control = new WsSegmented(items.Select(i => i.Label).ToList(), index, width);
        control.SelectionChanged += i => changed(items[i].Value);
        return control;
    }

    /// <summary>
    /// The study options (Mac: LearnOptionsPanel.swift / WriteOptions): direction, the mode's own options, tolerance and
    /// read-aloud. Each change is stored for the set right away and reported (the flows decide what needs a restart).
    /// </summary>
    /// <param name="runningNote">The session on screen runs with other settings than the options show (LearnFlow/WriteFlow.RunningSettingsNote).</param>
    public static Control OptionsPanel(AppModel model, string setId, StudyMode mode, Action<StudyOptions> changed, Action onClose, Action? onRestart = null,
        string doneKey = "Esc", string? runningNote = null)
    {
        var (rows, _) = OptionsBody(model, setId, () => mode, changed);
        WsButton? restart = null;
        if (onRestart is not null)
        {
            restart = Ui.Secondary(L("Neu starten"), onRestart, IconName.Undo);
            ToolTip.SetTip(restart, L("Die Runde mit diesen Optionen neu beginnen"));
        }
        var footer = Ui.H(10, restart, Ui.Primary(L("Fertig"), onClose, doneKey, height: 40));
        footer.HorizontalAlignment = HorizontalAlignment.Right;
        var scroll = Ui.Scroll(rows);
        var body = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), RowSpacing = 14 };
        Control title = Ui.Text(L("Optionen"), 20, FontWeight.Bold);
        if (runningNote is not null)
            title = Ui.V(6, title, Tagged(Ui.Text(runningNote, 13, color: WsTheme.P.TextSecondary, wrap: TextWrapping.Wrap), RunningNoteClass));
        body.Children.Add(title);
        Grid.SetRow(scroll, 1);
        body.Children.Add(scroll);
        Grid.SetRow(footer, 2);
        body.Children.Add(footer);
        var card = Ui.Hero(body, new Thickness(24, 20), 24);
        card.Width = 560;
        card.MaxHeight = 680;
        return card;
    }

    /// <summary>
    /// The options of a set for a mode, as in the options panel: first what this set does differently from the standard
    /// (Einstellungen) with "Auf Standard zurücksetzen", then the sections. Each change is stored for the set right
    /// away and reported. Render() builds it again (for a different mode).
    /// </summary>
    public static (StackPanel View, Action Render) OptionsBody(AppModel model, string setId, Func<StudyMode> mode, Action<StudyOptions> changed)
    {
        var set = model.Set(setId);
        var termLang = set?.TermLang ?? Lang.Other;
        var names = LearnOptionsCopy.SideNames(termLang, set?.DefLang ?? Lang.Other);
        var rows = new StackPanel { Spacing = 18 };
        void Render()
        {
            var options = model.Store.GetStudyOptions(setId);
            void Patch(StudyOptionsPatch patch)
            {
                try
                {
                    // An option set back to the standard is no longer the set's own (#8).
                    model.Store.UpdateOwnStudyOptions(setId, patch);
                }
                catch (LibraryStoreError)
                {
                    // Mac: model.report(error, fallback: …).
                    model.ShowToast(new ToastMessage(L("Die Option konnte nicht gespeichert werden."), ToastTone.Danger, DurationMs: 6000));
                    return;
                }
                model.SaveSoon();
                changed(model.Store.GetStudyOptions(setId));
                Render();
            }
            void Reset()
            {
                try
                {
                    // An empty patch clears the set's own options: it follows the standard again.
                    model.Store.UpdateSet(setId, new SetPatch(StudyOptions: new StudyOptionsPatch()));
                }
                catch (LibraryStoreError)
                {
                    model.ShowToast(new ToastMessage(L("Die Optionen konnten nicht zurückgesetzt werden."), ToastTone.Danger, DurationMs: 6000));
                    return;
                }
                model.SaveSoon();
                model.ShowToast(new ToastMessage(L("Dieses Lernset folgt wieder dem Standard"), ToastTone.Success));
                changed(model.Store.GetStudyOptions(setId));
                Render();
            }
            rows.Children.Clear();
            var m = mode();
            rows.Children.Add(StandardNote(LearnOptionsCopy.Deviations(options, model.Store.GetSettings().Study, names, termLang), Reset));
            foreach (var section in StudyOptionSections(options, names, termLang, m, Patch,
                m == StudyMode.Learn ? LearnSwitches(model, () => changed(model.Store.GetStudyOptions(setId))) : null, defLang: set?.DefLang ?? Lang.Other,
                sound: SoundSwitch(model, setId), synonyms: SynonymSwitch(model, setId)))
                rows.Children.Add(section);
        }
        Render();
        return (rows, Render);
    }

    /// <summary>
    /// The note at the top of a set's options: the options this set has of its own (they differ from the standard in
    /// Einstellungen) with "Auf Standard zurücksetzen", or that changes here only apply to this set.
    /// </summary>
    static Control StandardNote(IReadOnlyList<string> deviations, Action reset)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 10 };
        var icon = Icons.Icon(deviations.Count > 0 ? IconName.Sliders : IconName.Info, 16, deviations.Count > 0 ? P.AccentText : P.TextTertiary);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 1, 0, 0);
        grid.Children.Add(icon);
        Control content;
        if (deviations.Count == 0)
        {
            content = Ui.Text(L("Was du hier umstellst, gilt nur für dieses Lernset. Den Standard für alle Lernsets legst du in den Einstellungen fest."),
                13, color: P.TextSecondary, wrap: TextWrapping.Wrap);
        }
        else
        {
            var text = Ui.Text(L($"Dieses Lernset hat eigene Optionen: {string.Join(" · ", deviations)}."), 13, FontWeight.Medium, P.Text, wrap: TextWrapping.Wrap);
            var button = Ui.Secondary(L("Auf Standard zurücksetzen"), reset, IconName.RotateCcw, height: 32);
            button.HorizontalAlignment = HorizontalAlignment.Left;
            ToolTip.SetTip(button, L("Alle Optionen dieses Lernsets wieder wie in den Einstellungen"));
            content = Ui.V(10, text, button);
        }
        Grid.SetColumn(content, 1);
        grid.Children.Add(content);
        if (deviations.Count == 0) return grid;
        return new Border { Child = grid, Background = WsTheme.B(P.AccentSoft), CornerRadius = new CornerRadius(14), Padding = new Thickness(14, 12) };
    }

    /// <summary>The Learn switches that hold for every set (Wiederholungsfragen, Nachkontrolle), read from and written to the preferences.</summary>
    public sealed record GlobalLearnSwitches(bool Review, Action<bool> SetReview, bool Recheck, Action<bool> SetRecheck);

    public static GlobalLearnSwitches LearnSwitches(AppModel model, Action? after = null) => new(
        model.Preferences.LearnReview, v =>
        {
            model.Preferences.LearnReview = v;
            after?.Invoke();
        },
        model.Preferences.LearnRecheck, v =>
        {
            model.Preferences.LearnRecheck = v;
            after?.Invoke();
        });

    /// <summary>
    /// "Soundeffekte" of a set (Mac: SetSoundEffectsToggle): a preference of this device, not a study option, so it is
    /// not among the set's own options and "Auf Standard zurücksetzen" leaves it. Off in Einstellungen: off and locked.
    /// </summary>
    public sealed record SetSoundSwitch(bool On, bool Enabled, Action<bool> Set);

    /// <summary>
    /// "Synonyme ausserhalb des Sets erlauben" of a set (Mac: SetExtendedSynonymsToggle, under Toleranz): words with the
    /// same meaning that are not in the set. A preference of this device like SetSoundSwitch; off in Einstellungen
    /// ("Weitere Synonyme erkennen"): off and locked. Synonym cards of the set count either way.
    /// </summary>
    public sealed record SetSynonymSwitch(bool On, bool Enabled, Action<bool> Set);

    /// <summary>Style classes of option rows a screen scrolls to (the recheck hint's "Optionen", the snapshots).</summary>
    public const string RecheckOptionClass = "option-recheck";
    public const string SoundOptionClass = "option-sound";
    public const string SynonymOptionClass = "option-synonyms";
    /// <summary>Style class of the note that the session runs with other settings (snapshot checks).</summary>
    public const string RunningNoteClass = "options-running-note";

    static Control Tagged(Control row, string cls)
    {
        row.Classes.Add(cls);
        return row;
    }

    public static SetSynonymSwitch SynonymSwitch(AppModel model, string setId) => new(
        model.Preferences.ExtendedSynonymsFor(setId), model.Preferences.ExtendedSynonyms, on =>
        {
            model.Preferences.SaveSetExtendedSynonyms(setId, on);
            if (on) model.PreloadSynonyms(model.Set(setId));
        });

    public static SetSoundSwitch SoundSwitch(AppModel model, string setId) => new(
        model.Preferences.SoundEffectsFor(setId), model.Preferences.SoundEffects, on =>
        {
            model.Preferences.SaveSetSoundEffects(setId, on);
            // A taste of what comes back, like the switch in Einstellungen.
            if (on) model.Sounds.Play(Services.SoundEffects.Sound.Correct);
        });

    /// <summary>
    /// The options of a set outside a study session (the set page's "Optionen"): Lernen or Schreiben, as in the study
    /// screens. Changes apply when that mode starts next.
    /// </summary>
    public static void ShowSetOptions(AppModel model, string setId)
    {
        var mode = StudyMode.Learn;
        var (rows, render) = OptionsBody(model, setId, () => mode, _ => { });
        var tabs = new WsSegmented([L("Lernen"), L("Schreiben")], 0, 120) { HorizontalAlignment = HorizontalAlignment.Left };
        tabs.SelectionChanged += i =>
        {
            mode = i == 0 ? StudyMode.Learn : StudyMode.Write;
            render();
        };
        AutomationProperties.SetName(tabs, L("Optionen für"));
        var scroll = Ui.Scroll(rows);
        scroll.MaxHeight = 540;
        model.Ask(new PromptRequest(L("Optionen"), "", [new PromptButton(L("Fertig"), IsDefault: true, IsCancel: true)])
        {
            Width = 580,
            Content = Ui.V(16, tabs, scroll),
        });
    }

    /// <summary>
    /// The sections of the study options (Mac: LearnOptionsPanel / WriteOptionsPanel; also the defaults in
    /// Einstellungen › Lernen/Schreiben/Toleranz): Abfrage, Fragetypen, Runde, Wiederholung, Toleranz with examples.
    /// </summary>
    public static IEnumerable<Control> StudyOptionSections(StudyOptions options, (LearnOptionsCopy.Side Term, LearnOptionsCopy.Side Definition) names, Lang termLang,
        StudyMode? mode, Action<StudyOptionsPatch> patch, GlobalLearnSwitches? globals = null, bool includeTolerance = true, Lang? defLang = null,
        SetSoundSwitch? sound = null, SetSynonymSwitch? synonyms = null)
    {
        Control Switch(bool value, Action<bool> set, bool enabled = true, string? disabledTip = null)
        {
            var s = new WsSwitch(value, "");
            s.Toggled += set;
            s.IsEnabled = enabled;
            // Why it cannot be switched off (Mac: .help(LearnOptionsCopy.lockHint)).
            if (!enabled && disabledTip is not null)
            {
                ToolTip.SetTip(s, disabledTip);
                ToolTip.SetShowOnDisabled(s, true);
            }
            return s;
        }
        // "Soundeffekte" of the set, after "Vorlesen" (only in a set's options).
        IEnumerable<Control> SoundRow() => sound is { } snd
            ? [Tagged(Form.Row(LearnOptionsCopy.SoundLabel, Switch(snd.On, snd.Set, snd.Enabled, LearnOptionsCopy.SoundOffEverywhere),
                snd.Enabled ? LearnOptionsCopy.SoundNote : LearnOptionsCopy.SoundOffEverywhere), SoundOptionClass)]
            : [];
        var direction = Choice<AnswerWith>([(AnswerWith.Term, names.Term.Label), (AnswerWith.Definition, names.Definition.Label), (AnswerWith.Both, L("Beides"))],
            options.AnswerWith, v => patch(new StudyOptionsPatch(AnswerWith: v)));
        if (mode == StudyMode.Learn)
        {
            var learn = options.Learn;
            yield return Form.Section(L("Abfrage"), [Form.Row(L("Antworten auf"), direction)], LearnOptionsCopy.DirectionText(options.AnswerWith, names));
            yield return Form.Section(L("Fragetypen"),
            [
                Form.Row(L("Multiple Choice"), Switch(learn.Mc, v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Mc: v))), !(learn.Mc && !learn.Written),
                    LearnOptionsCopy.LockHint), L("Vier Antworten zur Auswahl")),
                Form.Row(L("Schriftlich"), Switch(learn.Written, v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Written: v))), !(learn.Written && !learn.Mc),
                    LearnOptionsCopy.LockHint), L("Antwort selbst eintippen")),
            ], LearnOptionsCopy.QuestionTypesHint(learn));
            yield return Form.Section(null,
            [
                Form.Row(LearnOptionsCopy.RoundSizeLabel, Choice<int>(LearnOptionsCopy.RoundSizes(learn.RoundSize).Select(s => (s, $"{s}")).ToList(), learn.RoundSize,
                    v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(RoundSize: v)))), LearnOptionsCopy.RoundSizeNote),
                Form.Row(L("Richtige Antwort abtippen"), Switch(learn.Retype, v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Retype: v)))),
                    L("Nach einem Fehler bei einer schriftlichen Frage tippst du die Lösung einmal ab.")),
                Form.Row(L("Vorlesen"), Switch(options.Audio, v => patch(new StudyOptionsPatch(Audio: v))), L("Begriffe in der Lernsprache automatisch vorlesen.")),
                .. SoundRow(),
            ]);
            if (globals is { } g)
                yield return Form.Section(L("Wiederholung"),
                [
                    Form.Row(LearnOptionsCopy.ReviewLabel, Switch(g.Review, g.SetReview), LearnOptionsCopy.ReviewNote),
                    Tagged(Form.Row(LearnOptionsCopy.RecheckLabel, Switch(g.Recheck, g.SetRecheck), LearnOptionsCopy.RecheckNote), RecheckOptionClass),
                ], LearnOptionsCopy.GlobalSwitchesFooter);
        }
        else if (mode == StudyMode.Write)
        {
            yield return Form.Section(L("Abfrage"),
            [
                // "Du siehst Deutsch und schreibst Französisch." under the choice (Mac: WriteOptionsPanel).
                Form.Row(L("Antworten auf"), direction, defLang is { } d ? WriteOptionsCopy.DirectionText(options.AnswerWith, termLang, d) : null),
                Form.Row(L("Mischen"), Switch(options.Shuffle, v => patch(new StudyOptionsPatch(Shuffle: v))), L("Karten in zufälliger Reihenfolge abfragen.")),
                Form.Row(L("Richtige Antwort abtippen"), Switch(options.CopyAnswer, v => patch(new StudyOptionsPatch(CopyAnswer: v))), L("Nach einem Fehler tippst du die Lösung einmal ab.")),
                Form.Row(L("Automatisch weiter"), Switch(options.AutoAdvance, v => patch(new StudyOptionsPatch(AutoAdvance: v))), L("Nach einer richtigen Antwort geht es von selbst weiter.")),
                Form.Row(L("Vorlesen"), Switch(options.Audio, v => patch(new StudyOptionsPatch(Audio: v))), L("Begriffe in der Lernsprache automatisch vorlesen.")),
                .. SoundRow(),
            ]);
        }
        if (includeTolerance)
        {
            var tolerance = LearnOptionsCopy.ToleranceItems(termLang).Select(item =>
                Form.Row(item.Label, Switch(item.Get(options.Tolerance), v => patch(new StudyOptionsPatch(Tolerance: item.Patch(v)))), item.Example)).ToList();
            // "Synonyme ausserhalb des Sets erlauben" of the set, last (only in a set's options; Mac: SetExtendedSynonymsToggle).
            if (synonyms is { } syn)
                tolerance.Add(Tagged(Form.Row(LearnOptionsCopy.SynonymsLabel, Switch(syn.On, syn.Set, syn.Enabled, LearnOptionsCopy.SynonymsOffEverywhere),
                    syn.Enabled ? LearnOptionsCopy.SynonymsNote : LearnOptionsCopy.SynonymsOffEverywhere), SynonymOptionClass));
            yield return Form.Section(L("Toleranz"), tolerance, L("Was trotzdem als richtig zählt"));
        }
    }

    /// <summary>
    /// A row of a term list: term over definition, each in its card's language (right to left for Arabic; Mac:
    /// cardTextLine), with a marker in front (Schreiben's ✓/✗) and/or a status at the end.
    /// </summary>
    public sealed record TermRow(string Term, string Definition, Lang TermLang = Lang.Other, Lang DefLang = Lang.Other, Control? Leading = null, Control? Trailing = null);

    /// <summary>
    /// A list of terms with a status (Mac: LearnTermList; checkpoint "In dieser Runde", finish "Am häufigsten falsch"):
    /// the title with its count, the rows on a quiet rounded panel separated by hairlines, term over definition.
    /// </summary>
    public static Control TermList(string title, IEnumerable<TermRow> rows)
    {
        var list = new StackPanel();
        int n = 0;
        foreach (var row in rows)
        {
            if (n++ > 0) list.Children.Add(new Border { Height = 1, Background = WsTheme.B(P.Hairline), Margin = new Thickness(row.Leading is null ? 20 : 52, 0, 0, 0) });
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Margin = new Thickness(20, 12) };
            var texts = Ui.V(2, StudyText.InLang(row.Term, row.TermLang, 14.5, FontWeight.SemiBold), StudyText.InLang(row.Definition, row.DefLang, 14, color: P.TextSecondary));
            Grid.SetColumn(texts, 1);
            g.Children.Add(texts);
            if (row.Leading is { } leading)
            {
                leading.VerticalAlignment = VerticalAlignment.Center;
                leading.Margin = new Thickness(0, 0, 10, 0);
                g.Children.Add(leading);
            }
            if (row.Trailing is { } trailing)
            {
                Grid.SetColumn(trailing, 2);
                trailing.VerticalAlignment = VerticalAlignment.Center;
                trailing.Margin = new Thickness(16, 0, 0, 0);
                g.Children.Add(trailing);
            }
            AutomationProperties.SetName(g, $"{row.Term}, {row.Definition}");
            list.Children.Add(g);
        }
        var count = new Border
        {
            Child = Ui.Text($"{n}", 13, FontWeight.SemiBold, P.TextSecondary),
            Background = WsTheme.B(P.KeyCap),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 2),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(count, Labels.Plural(n, "Begriff", "Begriffe"));
        var panel = new Border
        {
            Child = list,
            CornerRadius = new CornerRadius(20),
            Background = WsTheme.B(P.Dark ? Palette.Hex(0x1C1E28, 0.6) : Palette.Hex(0xFFFFFF, 0.6)),
            BorderBrush = WsTheme.B(P.Hairline),
            BorderThickness = new Thickness(1),
        };
        return Ui.V(12, Ui.H(8, Ui.Text(title, 20, FontWeight.Bold, font: WsTheme.Prompt), count), panel);
    }

    /// <summary>
    /// A written answer was wrong for the card but is the answer of another card with the same word («etw. entführen»
    /// → «to hijack sth», written «to kidnap sb», the answer of «jmdn. entführen»; Joan 10.11.2026): shows both cards
    /// and asks what the answer counts as – right (like "Ich hatte recht"), for the other card (this one stays wrong
    /// and comes again, the other gets a right answer in its progress) or wrong (Enter and Esc: a slip never counts
    /// by accident).
    /// </summary>
    public static void AskSameTerm(AppModel model, string setId, Card asked, Card other, AskSide ask, Lang promptLang, Lang answerLang,
        string given, Action countRight)
    {
        var otherPrompt = Synonyms.PromptSide(other, ask);
        Control Row(string label, Card card, bool highlight)
        {
            var texts = Ui.V(2,
                Ui.Text(label, 12, FontWeight.SemiBold, P.TextTertiary),
                StudyText.InLang(Synonyms.PromptSide(card, ask), promptLang, 15, FontWeight.SemiBold),
                StudyText.InLang(Synonyms.AnswerSide(card, ask), answerLang, 14.5, color: highlight ? P.Success.Text : P.TextSecondary));
            return new Border
            {
                Child = texts,
                Padding = new Thickness(16, 12),
                CornerRadius = new CornerRadius(14),
                Background = WsTheme.B(highlight ? P.Success.Soft : (P.Dark ? Palette.Hex(0x1C1E28, 0.6) : Palette.Hex(0xFFFFFF, 0.6))),
                BorderBrush = WsTheme.B(P.Hairline),
                BorderThickness = new Thickness(1),
            };
        }
        var askedPrompt = Synonyms.PromptSide(asked, ask);
        var choices = SameTermCards.Choices(askedPrompt, otherPrompt);
        // What each button does, in a sentence each (Joan: «Für … zählen» alone left open what happens).
        var legend = Ui.V(6, choices.Select(c => (Control)Ui.Text($"{c.Button}: {c.Explanation}", 13, color: P.TextSecondary, wrap: TextWrapping.Wrap)).ToArray());
        legend.Margin = new Thickness(2, 4, 2, 0);
        var content = Ui.V(10, Row(L("Gefragt war"), asked, false), Row(L("Deine Antwort gehört zu"), other, true), legend);
        model.Ask(new PromptRequest(SameTermCards.Title, SameTermCards.Message(given, askedPrompt, otherPrompt),
            [
                new PromptButton(choices[0].Button, countRight),
                new PromptButton(choices[1].Button, () =>
                {
                    try { model.Store.RecordAnswer(setId, other.Id, correct: true); }
                    catch (Exception) { return; }
                    model.SaveNow();
                    model.ShowToast(new ToastMessage(SameTermCards.CountedForOther(askedPrompt, otherPrompt), ToastTone.Success, DurationMs: 5000));
                }),
                new PromptButton(choices[2].Button, IsDefault: true, IsCancel: true),
            ]) { Content = content, Width = 660 });
    }

    /// <summary>
    /// The ★ toggle of a card in "Am häufigsten falsch" (Mac: StarToggle): marks it right there for "Nur markierte",
    /// the same mark as everywhere else. The symbol changes in place, the list stays as it is.
    /// </summary>
    public static Control StarToggle(AppModel model, string setId, string cardId)
    {
        bool Starred() => model.Set(setId)?.Cards.FirstOrDefault(c => c.Id == cardId)?.Starred ?? false;
        static string Tip(bool on) => on ? L("Markierung entfernen") : L("Markieren");
        bool starred = Starred();
        WsButton? star = null;
        star = Ui.IconButton(starred ? IconName.StarFilled : IconName.Star, Tip(starred), () =>
        {
            model.ToggleStar(setId, cardId);
            bool on = Starred();
            if (star?.Chrome.Child is Border holder) holder.Child = Icons.Icon(on ? IconName.StarFilled : IconName.Star, 18, on ? P.Star : P.TextTertiary);
            ToolTip.SetTip(star!, Tip(on));
            AutomationProperties.SetName(star!, Tip(on));
        }, 32, ButtonKind.Plain, starred ? P.Star : P.TextTertiary);
        return star;
    }

    /// <summary>A tolerance note under a correct answer ("Akzent fehlt"; Mac: NoteChip, the info colours with ⓘ).</summary>
    public static Control NoteChip(string text)
    {
        var chip = Ui.Chip(text, P.Info, IconName.Info);
        AutomationProperties.SetName(chip, L($"Hinweis: {text}"));
        return chip;
    }

    /// <summary>A synonym from the set accepted in Schreiben ("Synonym"; Mac: TintedChip with equal.circle in the accent colours).</summary>
    public static Control SynonymChip(string text)
    {
        var chip = Ui.Chip(text, null, IconName.EqualCircle);
        AutomationProperties.SetName(chip, L($"Hinweis: {text}"));
        return chip;
    }

}
