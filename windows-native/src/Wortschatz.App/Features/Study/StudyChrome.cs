using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

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
        var b = new WsButton(Ui.H(4, Icons.Icon(IconName.ChevronLeft, 18, P.Text, 2), Ui.Text(title, 14, FontWeight.SemiBold)), ButtonKind.Glass, 38,
            padding: new Thickness(10, 0, 16, 0));
        b.Click += (_, _) => onBack();
        b.MaxWidth = 340;
        ToolTip.SetTip(b, "Zurück zum Lernset (Esc)");
        Avalonia.Automation.AutomationProperties.SetName(b, "Zurück zum Lernset");
        return b;
    }

    /// <summary>The progress capsule: bar (mastered/learning) and "18 Neu · 12 Am Lernen · 22 Gemeistert".</summary>
    public static Control ProgressCapsule(int fresh, int learning, int mastered, int total)
    {
        var text = new TextBlock { FontFamily = WsTheme.UI, FontSize = 13, Foreground = WsTheme.B(P.TextSecondary), VerticalAlignment = VerticalAlignment.Center };
        void Part(string n, string label, bool last = false)
        {
            text.Inlines!.Add(new Avalonia.Controls.Documents.Run(n) { FontWeight = FontWeight.Bold, Foreground = WsTheme.B(P.Text) });
            text.Inlines.Add(new Avalonia.Controls.Documents.Run($" {label}{(last ? "" : " · ")}"));
        }
        text.Inlines = new Avalonia.Controls.Documents.InlineCollection();
        Part($"{fresh}", "Neu");
        Part($"{learning}", "Am Lernen");
        Part($"{mastered}", "Gemeistert", true);
        var row = Ui.H(14, Ui.StatusBar(mastered, learning, total, 7, 200), text);
        var capsule = Ui.Glass(row, 999, new Thickness(18, 0), strong: true, shadow: false);
        capsule.Height = 40;
        Avalonia.Automation.AutomationProperties.SetName(capsule, $"Fortschritt: {mastered} von {total} gemeistert, {learning} am Lernen, {fresh} neu");
        return capsule;
    }

    /// <summary>The top row of a study screen: left, centre and right parts.</summary>
    public static Control TopRow(Control left, Control? center, Control? right)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,*"), Margin = new Thickness(24, 6, 24, 0) };
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

    /// <summary>The floating glass bar at the bottom centre with the step's actions.</summary>
    public static Control ActionBar(params Control?[] items)
    {
        var row = Ui.H(10, items);
        row.VerticalAlignment = VerticalAlignment.Center;
        var bar = Ui.Glass(row, 999, new Thickness(8), strong: true);
        bar.HorizontalAlignment = HorizontalAlignment.Center;
        bar.VerticalAlignment = VerticalAlignment.Bottom;
        bar.Margin = new Thickness(0, 0, 0, 26);
        return bar;
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
    /// Esc cancels.
    /// </summary>
    public static Control CardEditor(VocabSet set, Card card, Action<string, string> onSave, Action onCancel, out Action save)
    {
        var (termLabel, defLabel) = WriteFlow.EditorLabels(set.TermLang, set.DefLang);
        var term = Ui.Field(termLabel, card.Term);
        var def = Ui.Field(defLabel, card.Definition);
        if (set.TermLang.IsRTL()) term.FlowDirection = FlowDirection.RightToLeft;
        if (set.DefLang.IsRTL()) def.FlowDirection = FlowDirection.RightToLeft;
        Action doSave = () => onSave(term.Text ?? "", def.Text ?? "");
        save = doSave;
        var buttons = Ui.H(10, Ui.Secondary("Abbrechen", onCancel, keyHint: "Esc"), Ui.Primary("Sichern", doSave, "↵", height: 40));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        var c = Ui.Hero(Ui.V(14, Ui.Text("Karte bearbeiten", 20, FontWeight.Bold), Ui.Eyebrow(termLabel), term, Ui.Eyebrow(defLabel), def, buttons), new Thickness(26, 22), 24);
        c.Width = 480;
        Avalonia.Threading.Dispatcher.UIThread.Post(() => term.Focus(), Avalonia.Threading.DispatcherPriority.Input);
        return c;
    }

    /// <summary>"🔥 6 richtig in Folge".</summary>
    public static Control StreakChip(int count)
    {
        var chip = new Border
        {
            Height = 38,
            Padding = new Thickness(14, 0),
            CornerRadius = new CornerRadius(999),
            Background = WsTheme.B(Palette.Hex(Ui.Rgb(P.Flame), 0.12)),
            Child = Ui.H(7, Icons.Icon(IconName.Flame, 16, P.Flame), Ui.Text($"{count} richtig in Folge", 13.5, FontWeight.SemiBold, P.FlameText)),
        };
        return chip;
    }

    /// <summary>A status chip in the action bar ("✓ Super!", "✗ Nicht ganz …").</summary>
    public static Control StatusChip(string text, StatusPalette palette, IconName icon)
    {
        return new Border
        {
            Height = 38,
            Padding = new Thickness(14, 0),
            CornerRadius = new CornerRadius(999),
            Background = WsTheme.B(palette.Soft),
            Child = Ui.H(8, Icons.Icon(icon, 17, palette.Text, 2.2), Ui.Text(text, 14, FontWeight.SemiBold, palette.Text)),
        };
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

    /// <summary>A labelled row for the options panel.</summary>
    static Control OptionRow(string label, Control control, string? note = null)
    {
        var left = Ui.V(2, Ui.Text(label, 14, FontWeight.Medium), note is null ? null : Ui.Text(note, 12.5, color: P.TextTertiary, wrap: TextWrapping.Wrap));
        var row = Ui.Row(left, control, 16);
        return row;
    }

    /// <summary>An on/off switch in the Glas look (Mac: Toggle in the options popover).</summary>
    public static Control Toggle(bool value, Action<bool> changed)
    {
        var t = new WsSwitch(value, "");
        t.Toggled += changed;
        return t;
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
    public static Control OptionsPanel(AppModel model, string setId, StudyMode mode, Action<StudyOptions> changed, Action onClose, Action? onRestart = null)
    {
        var set = model.Set(setId);
        var names = LearnOptionsCopy.SideNames(set?.TermLang ?? Lang.Other, set?.DefLang ?? Lang.Other);
        var rows = new StackPanel { Spacing = 18 };
        void Render()
        {
            var options = model.Store.GetStudyOptions(setId);
            void Patch(StudyOptionsPatch patch)
            {
                model.Store.UpdateStudyOptions(setId, patch);
                model.SaveSoon();
                changed(model.Store.GetStudyOptions(setId));
                Render();
            }
            rows.Children.Clear();
            foreach (var section in StudyOptionSections(options, names, set?.TermLang ?? Lang.Other, mode, Patch,
                mode == StudyMode.Learn ? (model.Preferences.LearnReview, v =>
                {
                    model.Preferences.LearnReview = v;
                    changed(model.Store.GetStudyOptions(setId));
                }) : null))
                rows.Children.Add(section);
        }
        Render();
        var footer = Ui.H(10, onRestart is null ? null : Ui.Secondary("Neu starten", onRestart, IconName.Undo), Ui.Primary("Fertig", onClose, "Esc", height: 40));
        footer.HorizontalAlignment = HorizontalAlignment.Right;
        var scroll = Ui.Scroll(rows);
        var body = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), RowSpacing = 14 };
        body.Children.Add(Ui.Text("Optionen", 20, FontWeight.Bold));
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
    /// The sections of the study options (Mac: LearnOptionsPanel / WriteOptionsPanel; also the defaults in
    /// Einstellungen › Lernen/Schreiben/Toleranz): Abfrage, Fragetypen, Runde, Wiederholung, Toleranz with examples.
    /// </summary>
    public static IEnumerable<Control> StudyOptionSections(StudyOptions options, (LearnOptionsCopy.Side Term, LearnOptionsCopy.Side Definition) names, Lang termLang,
        StudyMode? mode, Action<StudyOptionsPatch> patch, (bool Value, Action<bool> Set)? review = null, bool includeTolerance = true)
    {
        Control Switch(bool value, Action<bool> set, bool enabled = true)
        {
            var s = new WsSwitch(value, "");
            s.Toggled += set;
            s.IsEnabled = enabled;
            return s;
        }
        var direction = Choice<AnswerWith>([(AnswerWith.Term, names.Term.Label), (AnswerWith.Definition, names.Definition.Label), (AnswerWith.Both, "Beides")],
            options.AnswerWith, v => patch(new StudyOptionsPatch(AnswerWith: v)));
        if (mode == StudyMode.Learn)
        {
            var learn = options.Learn;
            yield return Form.Section("Abfrage", [Form.Row("Antworten auf", direction)], LearnOptionsCopy.DirectionText(options.AnswerWith, names));
            yield return Form.Section("Fragetypen",
            [
                Form.Row("Multiple Choice", Switch(learn.Mc, v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Mc: v))), !(learn.Mc && !learn.Written)), "Vier Antworten zur Auswahl"),
                Form.Row("Schriftlich", Switch(learn.Written, v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Written: v))), !(learn.Written && !learn.Mc)), "Antwort selbst eintippen"),
            ], LearnOptionsCopy.QuestionTypesHint(learn));
            yield return Form.Section(null,
            [
                Form.Row("Begriffe pro Runde", Choice<int>(LearnOptionsCopy.RoundSizes(learn.RoundSize).Select(s => (s, $"{s}")).ToList(), learn.RoundSize,
                    v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(RoundSize: v))))),
                Form.Row("Richtige Antwort abtippen", Switch(learn.Retype, v => patch(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Retype: v)))),
                    "Nach einem Fehler bei einer schriftlichen Frage tippst du die Lösung einmal ab."),
                Form.Row("Vorlesen", Switch(options.Audio, v => patch(new StudyOptionsPatch(Audio: v))), "Begriffe in der Lernsprache automatisch vorlesen."),
            ]);
            if (review is { } r)
                yield return Form.Section("Wiederholung",
                [
                    Form.Row("Wiederholungsfragen", Switch(r.Value, r.Set),
                        "Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen."),
                ], "Gilt für alle Lernsets.");
        }
        else if (mode == StudyMode.Write)
        {
            yield return Form.Section("Abfrage",
            [
                Form.Row("Antworten auf", direction),
                Form.Row("Mischen", Switch(options.Shuffle, v => patch(new StudyOptionsPatch(Shuffle: v))), "Karten in zufälliger Reihenfolge abfragen."),
                Form.Row("Richtige Antwort abtippen", Switch(options.CopyAnswer, v => patch(new StudyOptionsPatch(CopyAnswer: v))), "Nach einem Fehler tippst du die Lösung einmal ab."),
                Form.Row("Automatisch weiter", Switch(options.AutoAdvance, v => patch(new StudyOptionsPatch(AutoAdvance: v))), "Nach einer richtigen Antwort geht es von selbst weiter."),
                Form.Row("Vorlesen", Switch(options.Audio, v => patch(new StudyOptionsPatch(Audio: v))), "Begriffe in der Lernsprache automatisch vorlesen."),
            ]);
        }
        if (includeTolerance)
            yield return Form.Section("Toleranz",
                LearnOptionsCopy.ToleranceItems(termLang).Select(item =>
                    Form.Row(item.Label, Switch(item.Get(options.Tolerance), v => patch(new StudyOptionsPatch(Tolerance: item.Patch(v)))), item.Example)).ToList(),
                "Was trotzdem als richtig zählt");
    }

    /// <summary>
    /// A list of terms with a status (Mac: LearnTermList; checkpoint "In dieser Runde", finish "Am häufigsten falsch"):
    /// the title with its count, the rows on a quiet rounded panel separated by hairlines, term over definition.
    /// </summary>
    public static Control TermList(string title, IEnumerable<(string Term, string Definition, Control? Trailing)> rows)
    {
        var list = new StackPanel();
        int n = 0;
        foreach (var (term, def, trailing) in rows)
        {
            if (n++ > 0) list.Children.Add(new Border { Height = 1, Background = WsTheme.B(P.Hairline), Margin = new Thickness(20, 0, 0, 0) });
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16, Margin = new Thickness(20, 12) };
            g.Children.Add(Ui.V(2, Ui.Text(term, 14.5, FontWeight.SemiBold, wrap: TextWrapping.Wrap), Ui.Text(def, 14, color: P.TextSecondary, wrap: TextWrapping.Wrap)));
            if (trailing is not null)
            {
                Grid.SetColumn(trailing, 1);
                trailing.VerticalAlignment = VerticalAlignment.Center;
                g.Children.Add(trailing);
            }
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

    /// <summary>"✓ Gemeistert" etc. as a small tinted chip (Mac: StatusChip / TintedChip, size .small).</summary>
    public static Control SmallChip(string text, StatusPalette palette, IconName? icon = null) => Ui.Chip(text, palette, icon);
}
