using Avalonia;
using Avalonia.Headless;
using Avalonia.Threading;
using Wortschatz.App;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Services;
using Wortschatz.Core;

// Renders the app's screens to PNG with Avalonia headless (Skia) – the Windows app's design checks without
// Windows (Mac: the snapshot harness, DebugSnapshot.swift). Usage:
//   dotnet run --project tools/Wortschatz.Snapshots -- <out-dir> [phone] [dark] [en] [big|huge] [reduce] [contrast] [solid] [--only=learn|write|flashcards|editor|exam|settings|shell|recheck|updates]
var outDir = args.Length > 0 ? args[0] : "snapshots";
bool dark = args.Contains("dark");
// "reduce": as with Windows' animation effects switched off (Mac: Reduce Motion).
if (args.Contains("reduce")) Wortschatz.App.DesignSystem.Motion.ReduceMotion = true;
// "contrast": a Windows contrast theme (Mac: increased contrast); "solid": transparency effects off (Reduce Transparency).
if (args.Contains("contrast") || args.Contains("solid")) WsTheme.ForceAccessibility(args.Contains("contrast"), args.Contains("solid"));
Directory.CreateDirectory(outDir);
// A clock that moves on by a second per reading: the flows' input locks (280 ms) never block the scripted steps.
double fakeNow = 1_762_100_000_000;
TimeUtil.Clock = () => fakeNow += 1000;
// The same questions every run (the study engines' random choices): two runs draw the same pictures.
Rand.Fixed = Rand.Mulberry32(20261125u);
// The animation clock only moves when a step says so: Advance renders the frames in between (60 per second), Shot
// first lets every running animation finish unless it is asked for a frozen moment.
double motionNow = 0;
Motion.Now = () => motionNow;
Motion.IsSnapshot = true;

AppBuilder.Configure<App>()
    .UseSkia()
    .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false })
    .SetupWithoutStarting();

// "phone": the Android app's layout on a phone screen (390 × 844 like a common Android phone, without the system bars).
bool phone = args.Contains("phone");
AppDevice.IsPhone = phone;
// "en": the app in English (Einstellungen › Allgemein › Sprache); without it German, whatever this computer's language.
Wortschatz.App.Services.AppLanguage.SystemLanguageOverride = args.Contains("en") ? "en" : "de";
var model = Samples.Model(dark);
Avalonia.Controls.Window host;
MainView window;
if (phone)
{
    window = new MainView(model);
    host = new Avalonia.Controls.Window { Width = 390, Height = 844, Content = window };
}
else
{
    // big: a large monitor (2560 × 1440), huge: 8K at 100 % (7680 × 4320) – the study screens grow (MainView.StudyScale).
    var main = args.Contains("huge") ? new MainWindow(model) { Width = 7680, Height = 4320 }
        : args.Contains("big") ? new MainWindow(model) { Width = 2560, Height = 1440 } : new MainWindow(model) { Width = 1280, Height = 800 };
    host = main;
    window = main.View;
}
host.Show();

void Advance(double seconds)
{
    for (double t = 0; t < seconds - 1e-9; t += 1 / 60.0)
    {
        motionNow += Math.Min(1 / 60.0, seconds - t);
        Motion.RunFrame();
        Dispatcher.UIThread.RunJobs();
    }
}

var timing = Environment.GetEnvironmentVariable("SNAP_TIMING") is not null;
var stepClock = System.Diagnostics.Stopwatch.StartNew();

void Shot(string name, bool settle = true)
{
    long before = stepClock.ElapsedMilliseconds;
    if (settle) Advance(3);
    long settled = stepClock.ElapsedMilliseconds;
    for (int i = 0; i < 3; i++)
    {
        Dispatcher.UIThread.RunJobs();
        AvaloniaHeadlessPlatform.ForceRenderTimerTick();
    }
    if (Environment.GetEnvironmentVariable("SNAP_DEBUG") is not null && window.CurrentScreen is { } scr)
    {
        var v = scr.View;
        Console.Error.WriteLine($"{name}: anims={Motion.ActiveAnimations} now={motionNow} screen={scr.GetType().Name} content={(v as Avalonia.Controls.ContentControl)?.Content?.GetType().Name} bounds={v.Bounds} opacity={(((v as Avalonia.Controls.ContentControl)?.Content as Avalonia.Controls.Control)?.Opacity)}");
        foreach (var d in Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(v).Take(12)) Console.Error.WriteLine($"   {d.GetType().Name} {d.Bounds} op={d.Opacity} vis={d.IsVisible}");
    }
    var frame = host.CaptureRenderedFrame();
    var path = Path.Combine(outDir, name + ".png");
    frame?.Save(path);
    Console.WriteLine(path);
    if (timing) Console.WriteLine($"  time {name}: before {before / 1000.0:0.0} s, settle {(settled - before) / 1000.0:0.0} s, capture {(stepClock.ElapsedMilliseconds - settled) / 1000.0:0.0} s");
    stepClock.Restart();
}


var set = model.Sets.First(s => s.Title.StartsWith("Unité 3"));
Shot("01-overview");
model.OpenSet(set.Id);
Shot("02-set");
// Toasts: one rising, then all of them at rest (a success, one with an action, one that stays until closed).
model.ShowToast(new ToastMessage("Backup gespeichert", ToastTone.Success));
Advance(0.15);
Shot("02b-toast-rising", settle: false);
model.ShowToast(new ToastMessage("«Al ristorante» gelöscht", ActionLabel: "Rückgängig", Action: () => { }, DurationMs: 6000));
model.ShowToast(new ToastMessage("Die Datei ist kein Wortschatz-Backup.", ToastTone.Warning, DurationMs: null));
Shot("02c-toasts");
foreach (var t in model.Toasts.ToList()) model.DismissToast(t.Id);
var only = args.FirstOrDefault(a => a.StartsWith("--only="))?[7..];
foreach (var step in Samples.Steps(model, window, host, set.Id, only))
{
    // "!skip": after fast-forwarding many steps, every animation they started jumps to its end in one frame (else
    // the next shot plays thousands of them frame by frame: 15–20 s instead of under 1 s).
    if (step == Samples.SkipAnimations)
    {
        motionNow += 30;
        Motion.RunFrame();
        Dispatcher.UIThread.RunJobs();
        continue;
    }
    // "name@0.25": a frozen moment, 0.25 s after the step's action (no settling).
    var parts = step.Split('@');
    if (parts.Length == 2)
    {
        Advance(double.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture));
        Shot(parts[0], settle: false);
    }
    else Shot(step);
}

static class Samples
{
    const double Day = 86_400_000;

    /// <summary>A step that finishes every running animation at once (after a loop of many study steps).</summary>
    public const string SkipAnimations = "!skip";

    /// <summary>Opens the Learn options.</summary>
    static void OpenStudyOptions(Wortschatz.App.Features.Learn.LearnController c)
    {
        c.Send(new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options));
    }

    public static AppModel Model(bool dark, string? folder = null)
    {
        var store = new LibraryStore(folder is null ? new MemoryBackend() : new FileBackend(Path.Combine(folder, "library.json")));
        store.UpdateSettings(new SettingsPatch(dark ? ThemeSetting.Dark : ThemeSetting.Light));
        var lines = File.ReadAllLines(FindFixture("user-example.txt")).Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        var pairs = new List<CardDraft>();
        for (int i = 0; i + 1 < lines.Count; i += 2) pairs.Add(new CardDraft(lines[i], lines[i + 1]));
        var main = store.CreateSet("Unité 3 – Les personnes", "Personen und Eigenschaften", Lang.Fr, Lang.De, pairs);
        var now = TimeUtil.NowMs();
        var cards = store.GetSet(main.Id)!.Cards;
        for (int i = 0; i < cards.Count; i++)
        {
            if (i < 22) { store.RecordAnswer(main.Id, cards[i].Id, true, now - 3 * Day); store.RecordAnswer(main.Id, cards[i].Id, true, now - 2 * Day); }
            else if (i < 34) store.RecordAnswer(main.Id, cards[i].Id, true, now - Day);
        }
        for (int d = 0; d < 5; d++) store.RecordAnswer(main.Id, cards[40 + d].Id, false, now - d * Day);
        store.ToggleStar(main.Id, cards[3].Id);
        store.ToggleStar(main.Id, cards[7].Id);

        var en = store.CreateSet("Unit 5 – Travel", "", Lang.En, Lang.De,
            [new("the luggage", "das Gepäck"), new("the departure", "die Abfahrt"), new("to book", "buchen"), new("the platform", "das Gleis"), new("the ticket", "die Fahrkarte"), new("delayed", "verspätet")]);
        foreach (var c in store.GetSet(en.Id)!.Cards.Take(4)) { store.RecordAnswer(en.Id, c.Id, true, now - Day); store.RecordAnswer(en.Id, c.Id, true, now); }
        store.CreateSet("Vocabulario 2 – La casa", "", Lang.Es, Lang.De,
            [new("la cocina", "die Küche"), new("el dormitorio", "das Schlafzimmer"), new("la ventana", "das Fenster"), new("la puerta", "die Tür")]);
        store.CreateSet("汉语 Lektion 4 – Familie", "", Lang.Zh, Lang.De,
            [new("妈妈 (māma)", "Mutter"), new("爸爸 (bàba)", "Vater"), new("哥哥 (gēge)", "älterer Bruder"), new("姐姐 (jiějie)", "ältere Schwester")]);
        store.CreateSet("Al ristorante", "", Lang.It, Lang.De, [new("il conto", "die Rechnung"), new("il cameriere", "der Kellner"), new("la forchetta", "die Gabel")]);
        return new AppModel(store, AppPreferences.InMemory(), new SilentSpeech());
    }

    static string FindFixture(string name)
    {
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        while (d is not null)
        {
            var p = Path.Combine(d.FullName, "Website", "tests", "fixtures", name);
            if (File.Exists(p)) return p;
            d = d.Parent;
        }
        throw new FileNotFoundException(name);
    }

    /// <summary>The study screens, step by step (names of the PNGs).</summary>
    public static IEnumerable<string> Steps(AppModel model, MainView window, Avalonia.Controls.Window host, string setId, string? only = null)
    {
        bool Wants(string part) => only is null || only == part;
        if (only == "settings")
        {
            foreach (var step in SettingsSteps(model, window, setId)) yield return step;
            yield break;
        }
        if (only == "updates")
        {
            foreach (var step in UpdateSteps(model, window)) yield return step;
            yield break;
        }
        if (only == "shell")
        {
            // The window's own sheets and actions: delete with undo, Tastenkürzel, text export, backup import, sidebar.
            model.DeleteSet(setId);
            yield return "s1-deleted-toast";
            model.Undo();
            yield return "s2-restored";
            foreach (var t in model.Toasts.ToList()) model.DismissToast(t.Id);
            ShortcutsSheet.Show(model);
            yield return "s3-shortcuts";
            model.ClosePrompt();
            window.ToggleSidebar();
            yield return "s7-sidebar-hidden";
            window.ToggleSidebar();
            yield return "s8-sidebar-back@0.2";
            model.Study(setId, StudyMode.Learn);
            yield return "s9-into-learn@0.15";
            model.OpenSet(setId);
            yield return "s10-out-of-learn@0.15";
            yield break;
        }
        if (only == "editor")
        {
            // The editor alone: an existing set and a new one with the import panel (drop zone).
            model.Navigate(new Route.Editor(setId));
            yield return "08-editor";
            model.Navigate(new Route.Editor(null));
            yield return "08b-editor-new";
            // A pasted list with a heading, a doubled term and an unsure line: the detection, the cards it made at once
            // (doubled term marked; no preview, no "übernehmen" since 26.11.2026, Mac 1.8) and a save attempt without a
            // title (the errors stay on screen).
            if (window.CurrentScreen is Wortschatz.App.Features.Editor.SetEditorScreen editor)
            {
                editor.SnapshotImportText("Vocabulaire – Unité 3\nla maison - das Haus\nle chat - die Katze\nle chien - der Hund\nla maison - das Gebäude\n"
                    + "la fenêtre - das Fenster\nla porte - die Tür\nle jardin - der Garten\nla cuisine - die Küche\nle salon - das Wohnzimmer\nla chambre");
                yield return "08c-editor-detection";
                editor.SnapshotShowCards();
                yield return "08d-editor-cards";
                editor.SnapshotValidate();
                yield return "08e-editor-errors";
            }
            // Changes to cards from the box survive another recognition (Mac: editor-importEdits): the first card changed,
            // the second deleted, an own card typed in, then "Seiten tauschen". (The editor before has unsaved changes: its
            // leave guard would ask first.)
            model.LeaveGuard = null;
            model.Navigate(new Route.Editor(null));
            if (window.CurrentScreen is Wortschatz.App.Features.Editor.SetEditorScreen edits)
            {
                edits.SnapshotImportEdits("le monsieur\nder Herr\n\nla dame\ndie Dame\n\nl'enfant\ndas Kind\n\nle garçon\nder Junge\n\nla fille\ndas Mädchen\n");
                yield return "08f-editor-import-edits";
            }
            yield break;
        }
        if (only == "recheck")
        {
            // A long set (rechecks only above 60 cards): the first card is missed once, everything else is right, until
            // its Nachkontrolle comes – marked on the card, the session's first one with the hint and "Optionen".
            var big = model.Store.CreateSet("Grosses Lernset", "", Lang.Fr, Lang.De,
                Enumerable.Range(1, 70).Select(i => new CardDraft($"le mot {i}", $"das Wort {i}")).ToList());
            void Check(bool ok, string what)
            {
                if (!ok) throw new InvalidOperationException("recheck/sound check failed: " + what);
                Console.WriteLine("ok: " + what);
            }
            model.Study(big.Id, StudyMode.Learn);
            if (window.CurrentScreen is not Wortschatz.App.Features.Learn.LearnScreen screen) yield break;
            var c = screen.Controller;
            // The screen lets its toasts out after its entrance (a real-time timer the headless run does not wait for).
            c.ReleaseToasts();
            bool missed = false;
            screen.WithoutRendering(() =>
            {
            for (int i = 0; i < 3000 && !(c.State.Phase.IsQuestion && c.State.Question!.IsRecheck); i++)
            {
                var ph = c.State.Phase;
                if (ph == LearnFlow.Phase.Mc)
                {
                    var qq = c.State.Question!;
                    int index = qq.Choices.ToList().FindIndex(x => missed ? x.CardId == qq.CardId : x.CardId != qq.CardId);
                    missed = true;
                    c.Send(new LearnFlow.Event.Choose(index));
                }
                else if (ph == LearnFlow.Phase.Written) c.Send(new LearnFlow.Event.Submit(c.State.Question!.Expected));
                else if (c.State.AutoAdvanceToken is { } t) c.Send(new LearnFlow.Event.AutoAdvanceFired(t));
                else c.Send(new LearnFlow.Event.Proceed());
            }
            });
            Check(c.State.Question?.IsRecheck == true, "a recheck is on screen");
            var hints = model.Toasts.Where(x => x.Text == LearnFlow.RECHECK_HINT).ToList();
            Check(hints.Count == 1 && hints[0].DurationMs == LearnFlow.RECHECK_HINT_MS && hints[0].ActionLabel == CoreText.L("Optionen"), "one hint, 10 s, with Optionen");
            // Headless, the toasts' timers run ahead of real time: the hint is checked before skipping.
            yield return SkipAnimations;
            // A shot of this screen takes longer than the hint's 10 s in real time: the picture shows a copy that stays.
            model.DismissToast(hints[0].Id);
            model.ShowToast(hints[0] with { DurationMs = 600_000 });
            yield return "03r-learn-recheck";
            // "Optionen" in the hint opens the options.
            hints[0].Action!();
            Check(c.State.Overlay == LearnFlow.Overlay.Options, "Optionen opens the options");
            yield return "03s-learn-options";
            c.Send(new LearnFlow.Event.OverlayDismissed());
            foreach (var x in model.Toasts.ToList()) model.DismissToast(x.Id);

            // Sounds: on by default; the set's switch mutes only this set, the switch in Einstellungen every set.
            Check(model.Sounds.IsEnabled, "sounds on in the set");
            model.Preferences.SaveSetSoundEffects(big.Id, false);
            Check(!model.Sounds.IsEnabled && !model.Preferences.SetSoundEffects(big.Id), "the set's switch mutes it");
            Check(model.Preferences.SoundEffectsFor(setId) && model.Preferences.SoundEffectsFor(null), "other sets and no set keep their sounds");
            OpenStudyOptions(c);
            screen.RevealOption(Wortschatz.App.Features.Study.StudyChrome.SoundOptionClass);
            yield return "03t-learn-options-sound-off";
            c.Send(new LearnFlow.Event.OverlayDismissed());
            model.Preferences.SaveSetSoundEffects(big.Id, true);
            Check(model.Sounds.IsEnabled, "switched on again");
            model.Preferences.SoundEffects = false;
            Check(!model.Sounds.IsEnabled && !model.Preferences.SoundEffectsFor(setId), "Einstellungen mutes every set");
            OpenStudyOptions(c);
            screen.RevealOption(Wortschatz.App.Features.Study.StudyChrome.SoundOptionClass);
            yield return "03u-learn-options-sound-off-everywhere";
            c.Send(new LearnFlow.Event.OverlayDismissed());
            model.Preferences.SoundEffects = true;

            // Synonyms outside the set: the set's switch (Toleranz) turns them off for this set only, the switch in
            // Einstellungen for every set (Mac: SetExtendedSynonymsToggle).
            Check(model.Preferences.ExtendedSynonymsFor(big.Id), "synonyms on in the set");
            model.Preferences.SaveSetExtendedSynonyms(big.Id, false);
            Check(!model.Preferences.ExtendedSynonymsFor(big.Id) && model.Preferences.ExtendedSynonymsFor(setId), "the set's switch turns off only this set");
            OpenStudyOptions(c);
            screen.RevealOption(Wortschatz.App.Features.Study.StudyChrome.SynonymOptionClass);
            yield return "03u1-learn-options-synonyms-off";
            c.Send(new LearnFlow.Event.OverlayDismissed());
            model.Preferences.SaveSetExtendedSynonyms(big.Id, true);
            model.Preferences.ExtendedSynonyms = false;
            Check(!model.Preferences.ExtendedSynonymsFor(big.Id) && !model.Preferences.ExtendedSynonymsFor(setId), "Einstellungen turns off every set");
            OpenStudyOptions(c);
            screen.RevealOption(Wortschatz.App.Features.Study.StudyChrome.SynonymOptionClass);
            yield return "03u2-learn-options-synonyms-off-everywhere";
            c.Send(new LearnFlow.Event.OverlayDismissed());
            model.Preferences.ExtendedSynonyms = true;

            // «Nachkontrolle nach Fehlern» switched off in the options applies at once (Mac 1.6.2, issue #9): the recheck on
            // screen makes way for the next question, and closing the options asks nothing.
            OpenStudyOptions(c);
            screen.RevealOption(Wortschatz.App.Features.Study.StudyChrome.RecheckOptionClass);
            model.Preferences.LearnRecheck = false;
            c.SwitchesMayHaveChanged();
            Check(c.State.Session?.Recheck is null && c.State.Question?.IsRecheck != true, "Nachkontrolle off: the recheck on screen makes way");
            yield return "03u3-learn-options-recheck-off";
            c.Send(new LearnFlow.Event.OverlayDismissed());
            Check(c.State.Prompt is null, "no «Neu starten?» for the switch");
            model.Preferences.LearnRecheck = true;
            c.SwitchesMayHaveChanged();
            Check(c.State.Session?.Recheck is not null, "Nachkontrolle on again");

            // The set's options changed outside the session (issue #7): «Neu starten?»; «Später» keeps the session, and its
            // options say what it still runs with. Set back to the standard, the option is no longer the set's own (#8).
            model.Store.UpdateOwnStudyOptions(big.Id, new StudyOptionsPatch(AnswerWith: AnswerWith.Definition));
            c.StoreDidChange();
            Check(c.State.Prompt is LearnFlow.Prompt.RestartForOptions, "a direction changed outside asks «Neu starten?»");
            yield return "03u4-learn-restart-for-options";
            c.Send(new LearnFlow.Event.PromptAnswered(false));
            Check(model.Preferences.KeptOptionsOf("learn", big.Id) is not null, "«Später» is kept for the set");
            OpenStudyOptions(c);
            Check(LearnFlow.RunningSettingsNote(c.State) is not null, "the options say the session runs in the old direction");
            yield return "03u5-learn-options-running-note";
            c.Send(new LearnFlow.Event.OverlayDismissed());
            Check(c.State.Prompt is null, "closing the options without a change asks nothing after «Später»");
            model.Store.UpdateOwnStudyOptions(big.Id, new StudyOptionsPatch(AnswerWith: AnswerWith.Term));
            c.StoreDidChange();
            Check(model.Store.GetSet(big.Id)?.StudyOptions is null, "set back to the standard: no own option left");
            Check(c.State.Prompt is null && LearnFlow.RunningSettingsNote(c.State) is null, "back as the session runs: nothing to say");

            // A second session: the hint comes again at its first recheck, but only once.
            model.Store.ResetProgress(big.Id);
            c.Send(new LearnFlow.Event.Restart());
            if (c.State.Prompt is not null) c.Send(new LearnFlow.Event.PromptAnswered(true));
            Check(c.State.Session?.Recheck is not null, "the second session has rechecks");
            missed = false;
            int recheckQuestions = 0;
            string? lastQid = null;
            screen.WithoutRendering(() =>
            {
            for (int i = 0; i < 4000 && c.State.Phase != LearnFlow.Phase.Finished; i++)
            {
                var ph = c.State.Phase;
                if (c.State.Question is { IsRecheck: true } rq && ph.IsQuestion && rq.Qid != lastQid) { recheckQuestions++; lastQid = rq.Qid; }
                if (ph == LearnFlow.Phase.Mc)
                {
                    var qq = c.State.Question!;
                    // Three cards missed: three rechecks in this session.
                    int index = qq.Choices.ToList().FindIndex(x => missed || c.State.Session!.Answered > 2 ? x.CardId == qq.CardId : x.CardId != qq.CardId);
                    c.Send(new LearnFlow.Event.Choose(index));
                }
                else if (ph == LearnFlow.Phase.Written) c.Send(new LearnFlow.Event.Submit(c.State.Question!.Expected));
                else if (c.State.AutoAdvanceToken is { } t) c.Send(new LearnFlow.Event.AutoAdvanceFired(t));
                else c.Send(new LearnFlow.Event.Proceed());
            }
            });
            Check(recheckQuestions >= 2, $"several rechecks in the second session ({recheckQuestions})");
            Check(model.Toasts.Count(x => x.Text == LearnFlow.RECHECK_HINT) == 1, "the hint once in the second session");
            yield return SkipAnimations;
            yield return "03v-learn-finished-after-rechecks";

            // The set page's options: the same switch.
            model.OpenSet(big.Id);
            yield return "03w0-set";
            Wortschatz.App.Features.Study.StudyChrome.ShowSetOptions(model, big.Id);
            yield return "03w-set-options";
            yield break;
        }
        if (Wants("learn")) model.Study(setId, StudyMode.Learn);
        if (Wants("learn")) yield return "03-learn-mc";
        if (Wants("learn") && window.CurrentScreen is Wortschatz.App.Features.Learn.LearnScreen learn)
        {
            var c = learn.Controller;
            void Step()
            {
                var ph = c.State.Phase;
                if (ph == LearnFlow.Phase.Mc) { var qq = c.State.Question!; c.Send(new LearnFlow.Event.Choose(qq.Choices.ToList().FindIndex(x => x.CardId == qq.CardId))); }
                else if (ph == LearnFlow.Phase.Written) c.Send(new LearnFlow.Event.Submit(c.State.Question!.Expected));
                else if (c.State.AutoAdvanceToken is { } t) c.Send(new LearnFlow.Event.AutoAdvanceFired(t));
                else c.Send(new LearnFlow.Event.Proceed());
            }
            yield return "04-learn-written";
            c.Send(new LearnFlow.Event.Submit("la fausse réponse"));
            yield return "04b-learn-written-wrong";
            for (int i = 0; i < 40 && c.State.Phase != LearnFlow.Phase.Mc; i++) Step();
            var q = c.State.Question!;
            var answer = q.Choices.First(x => x.CardId == q.CardId).Text;
            foreach (var ch in answer.Take(5)) c.Send(new LearnFlow.Event.Key(KeyInput.Character(ch.ToString())));
            yield return "03b-learn-typing";
            c.Send(new LearnFlow.Event.Key(KeyInput.Escape));
            int wrong = q.Choices.ToList().FindIndex(x => x.CardId != q.CardId);
            c.Send(new LearnFlow.Event.Choose(wrong));
            yield return "03c0-learn-wrong-shake@0.12";
            yield return "03c-learn-wrong";
            c.Send(new LearnFlow.Event.Proceed());
            yield return "03d-learn-next-question@0.1";
            yield return "03d2-learn-next-settled";
            for (int i = 0; i < 40 && c.State.Phase != LearnFlow.Phase.Written; i++) Step();
            if (c.State.Phase == LearnFlow.Phase.Written)
            {
                c.Send(new LearnFlow.Event.Submit(c.State.Question!.Expected));
                yield return "03e-learn-written-correct@0.15";
                yield return "03e2-learn-written-correct-settled";
                Step();
                yield return "03f-learn-next-question@0.12";
            }
            for (int i = 0; i < 80 && c.State.Phase != LearnFlow.Phase.Checkpoint; i++) Step();
            yield return "04c0-learn-checkpoint-growing@0.35";
            yield return "04c-learn-checkpoint";
            learn.WithoutRendering(() =>
            {
                for (int i = 0; i < 600 && c.State.Phase != LearnFlow.Phase.Finished; i++) Step();
            });
            yield return SkipAnimations;
            if (c.State.Phase == LearnFlow.Phase.Finished) yield return "04d-learn-finished";

            // Abtippen (retype on): the right answer typed into the real copy field, as shown, continues without
            // Enter and the screen follows (23.11.2026). Not a picture of the set: the option goes back off.
            model.Store.ResetProgress(setId);
            model.Store.UpdateStudyOptions(setId, new StudyOptionsPatch(Learn: new LearnOptionsPatch(Retype: true)));
            model.Study(setId, StudyMode.Learn, forceNew: true);
            if (window.CurrentScreen is Wortschatz.App.Features.Learn.LearnScreen retype)
            {
                var r = retype.Controller;
                for (int i = 0; i < 40 && r.State.Phase != LearnFlow.Phase.Written; i++)
                {
                    var ph = r.State.Phase;
                    if (ph == LearnFlow.Phase.Mc) { var qq = r.State.Question!; r.Send(new LearnFlow.Event.Choose(qq.Choices.ToList().FindIndex(x => x.CardId == qq.CardId))); }
                    else if (r.State.AutoAdvanceToken is { } t) r.Send(new LearnFlow.Event.AutoAdvanceFired(t));
                    else r.Send(new LearnFlow.Event.Proceed());
                }
                yield return SkipAnimations;
                if (r.State.Phase == LearnFlow.Phase.Written)
                {
                    r.Send(new LearnFlow.Event.Submit("la fausse réponse"));
                    yield return "04e-learn-copy";
                    if (r.State.Phase != LearnFlow.Phase.Copy) throw new InvalidOperationException("copy check failed: no copy step");
                    var asked = r.State.Question!;
                    // The copy field itself (the answer field stays on screen above it since 24.11.2026).
                    var field = Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(retype.View).OfType<Avalonia.Controls.TextBox>()
                        .First(b => b.IsEffectivelyVisible && b.IsEffectivelyEnabled
                            && (b.PlaceholderText == CoreText.L("Richtige Antwort abtippen") || b.PlaceholderText == CoreText.L("Antwort abtippen")));
                    field.Text = asked.Expected;
                    yield return "04f-learn-copy-typed-out";
                    // Since 24.11.2026 it continues after a short pause (CopyStep.AdvanceMs, a normal advance timer that
                    // this tool's frozen time does not run): the pause has started, fire it.
                    if (r.State.Phase == LearnFlow.Phase.Copy && r.State.AutoAdvanceToken is { } copyToken) r.Send(new LearnFlow.Event.AutoAdvanceFired(copyToken));
                    if (r.State.Phase == LearnFlow.Phase.Copy || r.State.Question?.Qid == asked.Qid)
                        throw new InvalidOperationException("copy check failed: typed out but still " + r.State.Phase.Kind);
                    Console.WriteLine("ok: learn copy typed out continues, phase " + r.State.Phase.Kind);
                }
            }
            model.Store.UpdateStudyOptions(setId, new StudyOptionsPatch(Learn: new LearnOptionsPatch(Retype: false)));
        }
        if (Wants("write")) model.Study(setId, StudyMode.Write);
        if (Wants("write")) yield return "05-write";
        if (Wants("write") && window.CurrentScreen is Wortschatz.App.Features.Write.WriteScreen write)
        {
            var w = write.Controller;
            w.Send(new WriteFlow.Event.Submit("le monsieur"));
            yield return "05b-write-tolerated";
            w.Send(new WriteFlow.Event.Proceed());
            w.Send(new WriteFlow.Event.Submit("la fame"));
            yield return "05c0-write-wrong-moving@0.12";
            yield return "05c-write-wrong";
            // The copy typed into the real field, as shown: continues without Enter and the screen follows (23.11.2026).
            if (w.State.Phase == WriteFlow.Phase.Copy)
            {
                var asked = w.State.Question!;
                var field = Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(write.View).OfType<Avalonia.Controls.TextBox>()
                    .First(b => b.IsEffectivelyVisible && b.IsEffectivelyEnabled);
                field.Text = asked.Expected[..^1];
                if (w.State.Phase != WriteFlow.Phase.Copy) throw new InvalidOperationException("copy check failed: moved on before the last letter");
                field.Text = asked.Expected;
                yield return "05c1-write-copy-typed-out";
                // Since 24.11.2026 it continues after a short pause (CopyStep.AdvanceMs, a normal advance timer that this
                // tool's frozen time does not run): the pause has started, fire it.
                if (w.State.Phase == WriteFlow.Phase.Copy && w.State.AutoAdvance is { } copyAdvance) w.Send(new WriteFlow.Event.AutoAdvanceFired(copyAdvance.Token));
                if (w.State.Phase != WriteFlow.Phase.Question || w.State.Question?.CardId == asked.CardId)
                    throw new InvalidOperationException("copy check failed: typed out but still " + w.State.Phase.Kind);
                Console.WriteLine("ok: copy typed out continues, phase " + w.State.Phase.Kind);
                yield return "05c2-write-copy-next-field";
                if (field.Text is { Length: > 0 } || w.State.Input.Length > 0)
                    throw new InvalidOperationException($"copy check failed: the copied text stayed ('{field.Text}', input '{w.State.Input}')");
                Console.WriteLine("ok: the next question's field is empty");
            }
            void WStep()
            {
                var st = w.State;
                if (st.Phase == WriteFlow.Phase.Question) w.Send(new WriteFlow.Event.Submit(st.Question!.Expected));
                else if (st.Phase == WriteFlow.Phase.Copy) w.Send(new WriteFlow.Event.Submit(st.Question!.Expected));
                else if (st.AutoAdvance is { } a) w.Send(new WriteFlow.Event.AutoAdvanceFired(a.Token));
                else w.Send(new WriteFlow.Event.Proceed());
            }
            w.Send(new WriteFlow.Event.Proceed());
            for (int i = 0; i < 6 && w.State.Phase != WriteFlow.Phase.Question; i++) WStep();
            if (w.State.Phase == WriteFlow.Phase.Question)
            {
                w.Send(new WriteFlow.Event.Submit(w.State.Question!.Expected));
                yield return "05d-write-correct@0.2";
                yield return "05d2-write-correct";
            }
            for (int i = 0; i < 400 && w.State.Phase != WriteFlow.Phase.Summary; i++) WStep();
            yield return "05e0-write-summary-ring@0.3";
            yield return "05e-write-summary";
            for (int i = 0; i < 800 && w.State.Phase != WriteFlow.Phase.Results; i++) WStep();
            yield return "05f-write-results";
            // "Am häufigsten falsch" lists every missed card, not only 10, each with its ★ (issue #3).
            model.Study(setId, StudyMode.Write, forceNew: true);
            if (window.CurrentScreen is Wortschatz.App.Features.Write.WriteScreen many)
            {
                var m = many.Controller;
                int wrong = 0;
                for (int i = 0; i < 3000 && m.State.Phase != WriteFlow.Phase.Results; i++)
                {
                    var st = m.State;
                    if (st.Phase == WriteFlow.Phase.Question)
                        m.Send(new WriteFlow.Event.Submit(wrong++ < 14 ? "xyz" : st.Question!.Expected));
                    else if (st.Phase == WriteFlow.Phase.Copy) m.Send(new WriteFlow.Event.Submit(st.Question!.Expected));
                    else if (st.AutoAdvance is { } a) m.Send(new WriteFlow.Event.AutoAdvanceFired(a.Token));
                    else m.Send(new WriteFlow.Event.Proceed());
                }
                yield return SkipAnimations;
                Dispatcher.UIThread.RunJobs();
                var rows = WriteFlow.HardestRows(m.State);
                Console.Error.WriteLine($"#3: {rows.Count} Begriffe in «Am häufigsten falsch»: erster {rows[0].Term}, letzter {rows[^1].Term}; schon markiert: {string.Join(", ", model.Set(setId)!.Cards.Where(c => c.Starred).Select(c => c.Term))}");
                void ScrollDown()
                {
                    host.UpdateLayout();
                    if (window.CurrentScreen?.View is { } view)
                        foreach (var scroller in Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(view).OfType<Avalonia.Controls.ScrollViewer>()) scroller.ScrollToEnd();
                    host.UpdateLayout();
                }
                ScrollDown();
                yield return "05g-write-results-many";
                if (rows.Count > 0 && window.CurrentScreen?.View is { } view2)
                {
                    bool before = model.Set(setId)!.Cards.Single(c => c.Id == rows[0].CardId).Starred;
                    var stars = Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(view2).OfType<WsButton>()
                        .Where(b => Avalonia.Automation.AutomationProperties.GetName(b) is string star && (star == CoreText.L("Markieren") || star == CoreText.L("Markierung entfernen"))).ToList();
                    stars[0].RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Avalonia.Controls.Button.ClickEvent));
                    Dispatcher.UIThread.RunJobs();
                    bool after = model.Set(setId)!.Cards.Single(c => c.Id == rows[0].CardId).Starred;
                    Console.Error.WriteLine($"#3: {stars.Count} Sterne, erster Stern {before} -> {after} ({(before != after ? "OK" : "FEHLER")}), Name jetzt «{Avalonia.Automation.AutomationProperties.GetName(stars[0])}»");
                    ScrollDown();
                    yield return "05h-write-results-starred";
                }
            }
            // "Weitere Synonyme erkennen" (issue #4): a synonym from the thesaurus that is not in the set counts.
            model.Study(setId, StudyMode.Write, forceNew: true);
            if (window.CurrentScreen is Wortschatz.App.Features.Write.WriteScreen syn)
            {
                var s2 = syn.Controller;
                string? used = null;
                for (int i = 0; i < 200 && used is null && s2.State.Phase != WriteFlow.Phase.Results; i++)
                {
                    var st = s2.State;
                    if (st.Phase == WriteFlow.Phase.Question && st.Question is { } q)
                    {
                        var extra = model.ExtraAnswers(s2.SetId)(new SynonymQuery(q.Prompt, q.Expected, q.PromptLang, q.AnswerLang));
                        if (extra.Count > 0)
                        {
                            used = $"{q.Expected} → {extra[0]}";
                            s2.Send(new WriteFlow.Event.Submit(extra[0]));
                        }
                        else s2.Send(new WriteFlow.Event.Submit(q.Expected));
                    }
                    else if (st.Phase == WriteFlow.Phase.Copy) s2.Send(new WriteFlow.Event.Submit(st.Question!.Expected));
                    else if (st.AutoAdvance is { } a) s2.Send(new WriteFlow.Event.AutoAdvanceFired(a.Token));
                    else s2.Send(new WriteFlow.Event.Proceed());
                }
                Console.Error.WriteLine($"#4: {used ?? "keine Frage mit Synonym gefunden"}");
                if (used is not null) yield return "05i-write-synonym";
            }
            // Two cards for the same word (Joan 10.11.2026): «to kidnap sb» written for «etw. entführen» asks what it counts as.
            var same = model.CreateSet("Unit 14 – Entführen", Lang.En, Lang.De,
                [new CardDraft(null, "to hijack sth", "etw. entführen"), new CardDraft(null, "to kidnap sb", "jmdn. entführen"), new CardDraft(null, "to spark sth", "etw. entfachen")]);
            model.Store.UpdateStudyOptions(same.Id, new StudyOptionsPatch(AnswerWith: AnswerWith.Term));
            model.Study(same.Id, StudyMode.Write, forceNew: true);
            if (window.CurrentScreen is Wortschatz.App.Features.Write.WriteScreen sameScreen)
            {
                var c3 = sameScreen.Controller;
                for (int i = 0; i < 20 && c3.State.Question?.Prompt != "etw. entführen"; i++)
                {
                    var q = c3.State;
                    if (q.Phase == WriteFlow.Phase.Question) c3.Send(new WriteFlow.Event.Submit(q.Question!.Expected));
                    else if (q.AutoAdvance is { } a) c3.Send(new WriteFlow.Event.AutoAdvanceFired(a.Token));
                    else c3.Send(new WriteFlow.Event.Proceed());
                }
                if (c3.State.Question?.Prompt == "etw. entführen" && c3.State.Phase == WriteFlow.Phase.Question)
                {
                    c3.Send(new WriteFlow.Event.Submit("to kidnap sb"));
                    Dispatcher.UIThread.RunJobs();
                    Console.Error.WriteLine($"Gleicher Begriff: Fenster «{model.Prompt?.Title ?? "KEINS"}», Knöpfe: {string.Join(" / ", model.Prompt?.Buttons.Select(b => b.Label) ?? [])}");
                    yield return "05j-write-same-term";
                    if (model.Prompt?.Buttons.FirstOrDefault(b => b.Label == CoreText.L("Für die andere Karte zählen")) is { } forOther)
                    {
                        var kidnap = model.Set(same.Id)!.Cards.Single(c => c.Term == "to kidnap sb");
                        var before = model.Store.GetProgress(same.Id).GetValueOrDefault(kidnap.Id);
                        model.Answer(forOther);
                        Dispatcher.UIThread.RunJobs();
                        var after = model.Store.GetProgress(same.Id).GetValueOrDefault(kidnap.Id);
                        Console.Error.WriteLine($"Für die andere Karte: vorher {before?.Correct ?? 0} richtig, nachher {after?.Correct ?? 0}; gefragte Karte bleibt falsch: {!c3.State.Feedback!.IsCorrect}");
                        yield return "05k-write-same-term-counted";
                    }
                }
                else Console.Error.WriteLine("Gleicher Begriff: Frage nicht erreicht");
            }
        }
        if (Wants("flashcards")) model.Study(setId, StudyMode.Flashcards);
        if (Wants("flashcards")) yield return "07-flashcards";
        if (Wants("flashcards") && window.CurrentScreen is Wortschatz.App.Features.Flashcards.FlashcardsScreen cards)
        {
            var f = cards.Controller;
            // Turning over: frozen moments of the turn, then the back at rest.
            f.Flip();
            yield return "07a-flip-early@0.12";
            yield return "07b-flip-edge@0.08";
            yield return "07c-flip-late@0.1";
            yield return "07d-flipped";
            f.Flip();
            yield return "07d2-front-again";
            // Swiping: past the threshold to "Weiss ich" (sealed), a little toward "Lerne ich noch".
            f.SwipeBegan(Motion.Now());
            f.SwipeMoved(150, Motion.Now());
            yield return "07e-swipe-know@0";
            f.SwipeCancelled();
            yield return "07e2-swipe-settled";
            f.SwipeBegan(Motion.Now());
            f.SwipeMoved(-70, Motion.Now());
            yield return "07f-swipe-learning@0";
            f.SwipeCancelled();
            yield return "07f2-swipe-settled";
            // Sorting: the verdict lands, the card glides off, the next one rises.
            f.Sort(FlashcardVerdict.Know);
            yield return "07g-know-sealed@0.07";
            yield return "07h-know-glide@0.2";
            yield return "07i-next-card";
            f.Sort(FlashcardVerdict.StillLearning);
            yield return "07j-learning-glide@0.3";
            yield return "07j2-settled";
            f.Undo();
            yield return "07k-undo-return@0.15";
            yield return "07k2-undo-settled";
            cards.OpenOptions();
            yield return "07l-options";
            cards.CloseOptions();
            for (int guard = 0; guard < 300 && f.Phase == FlashcardDeck.DeckPhase.Card; guard++) f.Sort(f.Deck.SortedInRound % 3 == 0 ? FlashcardVerdict.StillLearning : FlashcardVerdict.Know);
            yield return "07m-round-done";
            f.NextRound();
            yield return "07n-round-2";
            for (int guard = 0; guard < 300 && f.Phase == FlashcardDeck.DeckPhase.Card; guard++) f.Sort(FlashcardVerdict.Know);
            if (f.Phase == FlashcardDeck.DeckPhase.RoundDone) { f.NextRound(); for (int guard = 0; guard < 300 && f.Phase == FlashcardDeck.DeckPhase.Card; guard++) f.Sort(FlashcardVerdict.Know); }
            yield return "07o-finished";
            f.Restart();
        }
        if (Wants("flashcards"))
        {
            var empty = model.CreateSet("Leeres Lernset", Lang.Fr, Lang.De, []);
            model.Study(empty.Id, StudyMode.Flashcards);
            yield return "07p-flashcards-empty";
            model.Store.DeleteSet(empty.Id);
        }
        if (only is not null && only != "exam") yield break;
        model.Study(setId, StudyMode.Exam);
        yield return "10-exam-setup";
        if (window.CurrentScreen is Wortschatz.App.Features.Exam.ExamScreen exam)
        {
            // The sheet with a few answers (filled number circles, the pill).
            exam.FillForSnapshot(q => q.Number <= 3 ? q.Expected : null);
            yield return "10a-exam-sheet";
            // Right, left open, a typo (small mistake), wrong.
            int n = 0;
            exam.RunForSnapshot(q => (n++ % 7) switch { 3 => "", 5 => q.Expected.Length > 3 ? q.Expected[..^1] + "x" : q.Expected, 6 => "faux", _ => q.Expected });
            yield return "10b-exam-grade@0.25";
            yield return "10c-exam-results";
            // The marked answers further down.
            double height = host.Height;
            host.Height = 2000;
            yield return "10c2-exam-answers";
            host.Height = height;
        }
        if (only is not null) yield break;
        model.Navigate(new Route.Editor(setId));
        yield return "08-editor";
        model.Navigate(new Route.Settings());
        yield return "09-settings";
    }


    /// <summary>
    /// Updates (--only=updates; the Windows app's AppUpdater, shown without network): «Aktualisiert auf …» in the sidebar
    /// with several changes and with one, all changes in the sheet, Einstellungen › Daten › Updates with a version ready
    /// and never looked, and the question after «Jetzt suchen».
    /// </summary>
    static IEnumerable<string> UpdateSteps(AppModel model, MainView window)
    {
        var updater = Wortschatz.App.Services.AppUpdater.Shared;
        string[] de =
        [
            "Neu: Wortschatz aktualisiert sich selbst: Neue Versionen lädt die App im Hintergrund und installiert sie, wenn du sie beendest.",
            "Verbessert: Tippen beim Lernen und in der Prüfung läuft flüssiger.",
            "Behoben: Karteikarten merken sich die Reihenfolge wieder.",
        ];
        string[] en =
        [
            "New: Wortschatz now updates itself: the app downloads new versions in the background and installs them when you quit it.",
            "Improved: Typing in Learn and the exam runs more smoothly.",
            "Fixed: Flashcards remember their order again.",
        ];
        var now = TimeUtil.NowMs();
        model.ShowOverview();
        updater.Preview(model.Preferences, new UpdateNotice("1.8", de, en, now));
        yield return "u1-sidebar-notice";
        Wortschatz.App.Features.UpdateNoticeCard.ShowChanges(model, updater.Notice!);
        yield return "u2-changes";
        model.ClosePrompt();
        updater.Preview(model.Preferences, new UpdateNotice("1.8", [de[2]], [en[2]], now));
        yield return "u3-sidebar-notice-one";
        updater.Preview(model.Preferences, new UpdateNotice("1.8", [], [], now));
        yield return "u4-sidebar-notice-none";
        model.Preferences.SettingsTab = 4;
        model.Navigate(new Route.Settings());
        updater.Preview(model.Preferences, null, new PendingUpdate("1.8", "Wortschatz-1.8-Windows.exe", 1, new string('a', 64)), now - 5 * 60_000);
        window.CurrentScreen?.Refresh();
        yield return "u5-settings-ready";
        var version = "1.8";
        model.Ask(new PromptRequest(CoreText.L($"Version {version} ist bereit"), CoreText.L("Wird installiert, wenn du Wortschatz beendest."),
            [new PromptButton(CoreText.L("Jetzt neu starten"), IsDefault: true), new PromptButton(CoreText.L("Später"), IsCancel: true)])
        {
            Content = Wortschatz.App.Features.UpdateNoticeCard.ChangeList(CoreText.Table is null ? de : en),
        });
        yield return "u6-ready-question";
        model.ClosePrompt();
        updater.Preview(model.Preferences, null);
        window.CurrentScreen?.Refresh();
        yield return "u7-settings-never";
    }

    /// <summary>Einstellungen and the set page's sheets (--only=settings): every tab, backup import, wipe, text export.</summary>
    static IEnumerable<string> SettingsSteps(AppModel model, MainView window, string setId)
    {
        model.OpenSet(setId);
        if (window.CurrentScreen is { } screen && Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(screen.View)
                .OfType<Wortschatz.App.DesignSystem.WsButton>().FirstOrDefault(b => Avalonia.Automation.AutomationProperties.GetName(b) == "Begriff") is { } header)
            header.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Avalonia.Controls.Button.ClickEvent));
        yield return "11-set-sorted";
        Wortschatz.App.Features.Settings.SettingsScreen.ExportText(model, window, model.Set(setId)!);
        yield return "11b-text-export";
        model.ClosePrompt();
        model.Navigate(new Route.Settings());
        for (int tab = 0; tab < 5; tab++)
        {
            model.Preferences.SettingsTab = tab;
            window.CurrentScreen?.Refresh();
            yield return $"12-settings-tab{tab}";
        }
        var data = Wortschatz.Core.Backup.JsonData(model.Store.ExportAll());
        var preview = Wortschatz.Core.BackupImportPreview.Read("wortschatz-backup-2026-11-03.json", data, model.Store.ListSets().Skip(1).ToList());
        Wortschatz.App.Features.Settings.BackupImportSheet.Show(model, window, preview);
        yield return "12b-import-merge";
        Wortschatz.App.Features.Settings.BackupImportSheet.Show(model, window, preview, ImportMode.Replace);
        yield return "12c-import-replace";
        Wortschatz.App.Features.Settings.BackupImportSheet.Show(model, window, preview with { Existing = [] });
        yield return "12d-import-empty";
        model.ClosePrompt();
        Wortschatz.App.Features.Settings.SettingsWipeSheet.Show(model, window);
        yield return "12e-wipe";
        if (model.Prompt?.Buttons.FirstOrDefault(b => b.Label == CoreText.L("Weiter")) is { } next) model.Answer(next);
        yield return "12f-wipe-confirm";
        model.ClosePrompt();
    }
}
