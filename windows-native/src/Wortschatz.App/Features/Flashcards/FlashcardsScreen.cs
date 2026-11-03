using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using DeckPhase = Wortschatz.Core.FlashcardDeck.DeckPhase;

namespace Wortschatz.App.Features.Flashcards;

/// <summary>
/// Karteikarten (Mac: FlashcardsScreen.swift): one card at a time, turned over with Space (or a click, Enter, ↑↓) and
/// sorted with ← "Lerne ich noch" and → "Weiss ich" (or swiped there with two fingers on the touchpad or the mouse), in
/// rounds until every card is known. Rücktaste takes the last sort back. Self-assessment only: no progress is recorded.
/// The deck is kept per set (AppPreferences), so leaving and coming back continues.
/// The screen is built once; the controller's changes update it in place, so the cards can move.
/// </summary>
public sealed class FlashcardsScreen : Screen
{
    enum OverlayKind { None, Options, Editor, Confirm }

    readonly FlashcardsController _c;
    readonly FlashcardScrollMonitor _monitor;
    readonly Border _overlayHost = new() { IsVisible = false };
    FlashcardsStage? _stage;
    Grid? _content;
    Border? _progress;
    ProgressLine? _line;
    TextBlock? _roundText, _countText;
    WsButton? _optionsButton, _restartButton;
    OverlayKind _overlay;
    Action? _editorSave;
    Action<bool>? _confirm;

    public FlashcardsScreen(AppModel model, MainWindow window, StudyRequest request) : base(model, window)
    {
        _c = new FlashcardsController(model, request);
        _c.Changed += OnChanged;
        _c.Confirm = ShowConfirm;
        _monitor = new FlashcardScrollMonitor(_c);
    }

    public override bool UsesSidebar => false;
    public FlashcardsController Controller => _c;
    static Palette P => WsTheme.P;
    DeckPhase Phase => _c.Phase;

    public override void Activate()
    {
        base.Refresh();
        // Built once, then revealed (Mac: StudyEntrance): the screen fades in, the first card rises.
        if (_content is not null) StudyEntrance.RevealScreen(_content);
        _stage?.Entrance();
    }

    public override void Deactivate()
    {
        _monitor.Cancel();
        _c.Deactivate();
    }

    /// <summary>The library changed (a star, the card editor): the deck follows.</summary>
    public override void Refresh() => _c.StoreDidChange();

    protected override Control Build()
    {
        var root = new Grid();
        var content = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        content.Children.Add(TopRow());
        _stage = new FlashcardsStage(_c, EditCurrentCard);
        Grid.SetRow(_stage, 1);
        content.Children.Add(_stage);
        _content = content;
        root.Children.Add(content);
        root.Children.Add(_overlayHost);
        // Two fingers sideways move the card; up and down still scroll.
        root.AddHandler(InputElement.PointerWheelChangedEvent, (_, e) =>
        {
            if (_monitor.Handle(e)) e.Handled = true;
        }, RoutingStrategies.Tunnel);
        UpdateTopRow();
        _monitor.IsEnabled = _overlay == OverlayKind.None && Phase == DeckPhase.Card;
        return root;
    }

    void OnChanged()
    {
        UpdateTopRow();
        _stage?.Update();
        _monitor.IsEnabled = _overlay == OverlayKind.None && Phase == DeckPhase.Card;
    }

    // MARK: Top row

    /// <summary>"‹ Lernset", the round's progress in the middle, Optionen and Neu starten on the right.</summary>
    Control TopRow()
    {
        _roundText = Ui.Text("", 14, FontWeight.SemiBold, P.TextSecondary);
        _line = new ProgressLine(0, P.Accent, 120);
        _countText = Ui.Text("", 14, FontWeight.Medium, P.TextSecondary);
        _countText.FontFeatures = FontFeatureCollection.Parse("tnum");
        var capsule = Ui.Glass(Ui.H(16, _roundText, _line, _countText), 999, new Thickness(18, 0), strong: true, shadow: false);
        capsule.Height = 40;
        _progress = capsule;
        _optionsButton = Ui.IconButton(IconName.Sliders, "Optionen (Ctrl+K)", ShowOptions);
        _restartButton = Ui.IconButton(IconName.RotateCcw, "Neu starten (Ctrl+Shift+R)", _c.RequestRestart);
        foreach (var b in new[] { _optionsButton, _restartButton }) b.Focusable = false;
        return StudyChrome.TopRow(StudyChrome.BackPill(_c.Set.Title is { Length: > 0 } t ? t : "Zurück", _c.Exit), capsule, Ui.H(8, _optionsButton, _restartButton));
    }

    /// <summary>"Runde 2", how far the round is and "5/12" (Mac: FlashcardsToolbarProgress).</summary>
    void UpdateTopRow()
    {
        var deck = _c.Deck;
        if (_progress is null || _line is null || _roundText is null || _countText is null) return;
        _progress.IsVisible = Phase != DeckPhase.Empty;
        int shown = Math.Min(deck.SortedInRound + (Phase == DeckPhase.Card ? 1 : 0), deck.RoundSize);
        _roundText.Text = $"Runde {deck.Round}";
        _countText.Text = $"{shown}/{deck.RoundSize}";
        _line.SetValue(deck.RoundSize > 0 ? (double)deck.SortedInRound / deck.RoundSize : 0, Motion.Snappy);
        ToolTip.SetTip(_progress, $"Runde {deck.Round} · {deck.SortedInRound} von {FlashcardCopy.Cards(deck.RoundSize)} sortiert");
        AutomationProperties.SetName(_progress, $"Fortschritt: Runde {deck.Round}, Karte {shown} von {deck.RoundSize}");
        if (_optionsButton is not null) _optionsButton.IsEnabled = Phase != DeckPhase.Empty;
        if (_restartButton is not null) _restartButton.IsEnabled = deck.HasProgress;
    }

    // MARK: Overlays (options, card editor, confirmation)

    void Show(OverlayKind kind, Control card, Action onCancel)
    {
        _monitor.Cancel();
        if (_c.Swipe.IsTracking) _c.SwipeCancelled();
        _overlay = kind;
        _monitor.IsEnabled = false;
        var layer = StudyChrome.Overlay(card, onCancel);
        _overlayHost.Child = layer;
        _overlayHost.IsVisible = true;
        Effects.Of(layer).Enter(new Placement(Opacity: 0), Curve.EaseOut(0.16));
        Effects.Of(card).Enter(new Placement(Y: 8, Scale: 0.98, Opacity: 0), Motion.Arrive(0.3));
    }

    void CloseOverlay()
    {
        _overlay = OverlayKind.None;
        _editorSave = null;
        _confirm = null;
        if (_overlayHost.Child is { } layer)
            Effects.Of(layer).Place(new Placement(Opacity: 0), Curve.EaseOut(0.12), () =>
            {
                if (_overlay != OverlayKind.None) return;
                _overlayHost.Child = null;
                _overlayHost.IsVisible = false;
            });
        _monitor.IsEnabled = Phase == DeckPhase.Card;
    }

    /// <summary>Opens and closes the options (Ctrl+K; also for the snapshot tool).</summary>
    public void OpenOptions() => ShowOptions();
    public void CloseOptions() => CloseOverlay();

    void ShowOptions()
    {
        if (Phase == DeckPhase.Empty || _overlay != OverlayKind.None) return;
        Show(OverlayKind.Options, FlashcardsOptionsPanel.Create(_c, CloseOverlay), CloseOverlay);
    }

    void EditCurrentCard()
    {
        if (_overlay != OverlayKind.None || _c.CurrentCard is not { } card) return;
        var editor = StudyChrome.CardEditor(_c.Set, card, (term, definition) =>
        {
            CloseOverlay();
            _c.SaveEdit(card, term, definition);
        }, CloseOverlay, out var save);
        _editorSave = save;
        Show(OverlayKind.Editor, editor, CloseOverlay);
    }

    void ShowConfirm(string title, string message, string confirm, Action action)
    {
        if (_overlay != OverlayKind.None) return;
        _confirm = yes =>
        {
            CloseOverlay();
            if (yes) action();
        };
        Show(OverlayKind.Confirm, StudyChrome.PromptCard(title, message, confirm, "Abbrechen", false, yes => _confirm?.Invoke(yes)), () => _confirm?.Invoke(false));
    }

    // MARK: Keys

    public override bool HandleKey(KeyEventArgs e, bool isRepeat)
    {
        var mods = e.KeyModifiers;
        bool enter = e.Key is Key.Enter or Key.Return;
        switch (_overlay)
        {
            case OverlayKind.Confirm:
                if (!isRepeat && enter) _confirm?.Invoke(true);
                else if (e.Key == Key.Escape) _confirm?.Invoke(false);
                return true;
            case OverlayKind.Editor:
                if (e.Key == Key.Escape) CloseOverlay();
                else if (enter && !isRepeat) _editorSave?.Invoke();
                else return false;
                return true;
            case OverlayKind.Options:
                if (e.Key != Key.Escape) return false;
                CloseOverlay();
                return true;
        }
        if (mods == KeyModifiers.Control)
        {
            switch (e.Key)
            {
                case Key.K: ShowOptions(); return true;
                case Key.R: _c.SpeakVisibleSide(); return true;
                case Key.D: _c.ToggleStar(); return true;
                case Key.E: EditCurrentCard(); return true;
            }
        }
        if (mods == (KeyModifiers.Control | KeyModifiers.Shift) && e.Key == Key.R)
        {
            _c.RequestRestart();
            return true;
        }
        // Space turns the card over here (before a focused button could take it); its text input is then ignored.
        if (e.Key == Key.Space && mods == KeyModifiers.None) return _c.Press(KeyInput.Character(" "), isRepeat) || true;
        if (Translate(e) is not { } key) return false;
        if (Phase == DeckPhase.Empty)
        {
            if (key.Kind == KeyKind.Escape) _c.Exit();
            else if (key.Kind == KeyKind.Return && !isRepeat) _c.AddCards();
            return key.Kind is KeyKind.Escape or KeyKind.Return;
        }
        return _c.Press(key, isRepeat);
    }

    public override bool HandleText(string text)
    {
        if (_overlay != OverlayKind.None) return false;
        if (text == " ") return true;
        return _c.Press(TextKey(text), false);
    }
}
