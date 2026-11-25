using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Flashcards;

/// <summary>
/// The flashcards options (Mac: FlashcardsOptionsPanel.swift; Ctrl+K, the top row's "Optionen"): which side is up first
/// and whether the cards are shuffled (both for every set, they apply at once), and "Nur markierte" (starts over).
/// </summary>
public static class FlashcardsOptionsPanel
{
    public static Control Create(FlashcardsController controller, Action onClose)
    {
        var names = LearnOptionsCopy.SideNames(controller.Set.TermLang, controller.Set.DefLang);
        int starred = controller.StarredCount;
        var front = new WsSegmented([names.Term.Label, names.Definition.Label], controller.Front == FlashcardFront.Term ? 0 : 1, 110);
        front.SelectionChanged += i => controller.SetFront(i == 0 ? FlashcardFront.Term : FlashcardFront.Definition);
        var shuffle = new WsSwitch(controller.Deck.IsShuffled, L("Mischen"));
        shuffle.Toggled += controller.SetShuffled;
        var onlyStarred = new WsSwitch(controller.Deck.StarredOnly, L($"Nur markierte ({starred})"));
        onlyStarred.Toggled += controller.SetStarredOnly;
        onlyStarred.IsEnabled = starred > 0 || controller.Deck.StarredOnly;

        var cards = Form.Section(L("Karten"), [
            Form.Row(L("Vorderseite"), front),
            Form.Row(L("Mischen"), shuffle, L("Die Karten kommen in zufälliger Reihenfolge.")),
        ]);
        var subset = Form.Section(null, [
            Form.Row(L($"Nur markierte ({starred})"), onlyStarred,
                starred == 0 && !controller.Deck.StarredOnly
                    ? L("Markiere Begriffe mit dem Stern, um nur sie zu üben.")
                    : L("Beginnt die Karteikarten mit den markierten Begriffen neu.")),
        ], L("Karteikarten zählen nicht für «Gemeistert». Dafür fragen dich Lernen und Schreiben ab."));

        var done = Ui.Primary(L("Fertig"), onClose, "Esc", height: 40);
        done.HorizontalAlignment = HorizontalAlignment.Right;
        var body = Ui.V(18, Ui.Text(L("Optionen"), 20, FontWeight.Bold), cards, subset, done);
        var card = Ui.Hero(body, new Thickness(24, 22), 24);
        card.Width = 440;
        return card;
    }
}
