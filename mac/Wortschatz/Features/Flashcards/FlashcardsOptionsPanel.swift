import SwiftUI
import WortschatzCore

/// The flashcards options (⌘K, toolbar "Optionen"): which side is up first and whether the cards
/// are shuffled (both for every set, they apply at once), and "Nur markierte" (starts over).
struct FlashcardsOptionsPanel: View {
    let controller: FlashcardsController

    var body: some View {
        let names = LearnOptionsCopy.sideNames(termLang: controller.set.termLang, defLang: controller.set.defLang)
        let starred = controller.starredCount
        Form {
            Section {
                Picker("Vorderseite", selection: Binding(get: { controller.front }, set: controller.setFront)) {
                    Text(names.term.label).tag(FlashcardFront.term)
                    Text(names.definition.label).tag(FlashcardFront.definition)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: Binding(get: { controller.deck.isShuffled }, set: controller.setShuffled)) {
                    Text("Mischen")
                    Text("Die Karten kommen in zufälliger Reihenfolge.")
                }
            } header: {
                Text("Karten")
            }

            Section {
                Toggle(isOn: Binding(get: { controller.deck.starredOnly }, set: controller.setStarredOnly)) {
                    Text("Nur markierte (\(starred))")
                    Text(
                        starred == 0 && !controller.deck.starredOnly
                            ? "Markiere Begriffe mit dem Stern, um nur sie zu üben."
                            : "Beginnt die Karteikarten mit den markierten Begriffen neu.")
                }
                .disabled(starred == 0 && !controller.deck.starredOnly)
            } footer: {
                Text("Karteikarten zählen nicht für «Gemeistert». Dafür fragen dich Lernen und Schreiben ab.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 280, idealHeight: 300)
    }
}
