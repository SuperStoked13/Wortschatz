using Avalonia;
using Avalonia.Headless;
using Avalonia.Threading;
using Wortschatz.App;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Services;
using Wortschatz.Core;

// Renders the app's screens to PNG with Avalonia headless (Skia) – the Windows app's design checks without
// Windows (Mac: the snapshot harness, DebugSnapshot.swift). Usage:
//   dotnet run --project tools/Wortschatz.Snapshots -- <out-dir> [phone] [dark] [reduce] [contrast] [solid] [--only=learn|write|flashcards|editor|exam|settings|shell]
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
    var main = new MainWindow(model) { Width = 1280, Height = 800 };
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

void Shot(string name, bool settle = true)
{
    if (settle) Advance(3);
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

    public static AppModel Model(bool dark)
    {
        var store = new LibraryStore(new MemoryBackend());
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
            // A pasted list with a heading, a doubled term and an unsure line: the detection with its preview, then the
            // cards it makes (doubled term marked) and a save attempt without a title (the errors stay on screen).
            if (window.CurrentScreen is Wortschatz.App.Features.Editor.SetEditorScreen editor)
            {
                editor.SnapshotImportText("Vocabulaire – Unité 3\nla maison - das Haus\nle chat - die Katze\nle chien - der Hund\nla maison - das Gebäude\n"
                    + "la fenêtre - das Fenster\nla porte - die Tür\nle jardin - der Garten\nla cuisine - die Küche\nle salon - das Wohnzimmer\nla chambre");
                yield return "08c-editor-detection";
                editor.SnapshotApplyImport();
                yield return "08d-editor-cards";
                editor.SnapshotValidate();
                yield return "08e-editor-errors";
            }
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
            for (int i = 0; i < 600 && c.State.Phase != LearnFlow.Phase.Finished; i++) Step();
            if (c.State.Phase == LearnFlow.Phase.Finished) yield return "04d-learn-finished";
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
        if (model.Prompt?.Buttons.FirstOrDefault(b => b.Label == "Weiter") is { } next) model.Answer(next);
        yield return "12f-wipe-confirm";
        model.ClosePrompt();
    }
}
