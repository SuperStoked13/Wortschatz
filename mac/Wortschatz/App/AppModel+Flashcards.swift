import Foundation
import WortschatzCore

// Karteikarten (flashcards) in the app shell: opening and restarting them, and the decks of the
// sets. A deck is the learner's own sorting, not progress, so it is not part of the library:
// the decks live in a small file beside it ("library.flashcards.json" next to "library.json"),
// so a test library never mixes with the real one. In-memory libraries keep them in memory.

extension AppModel {
    /// The longest a deck change waits before it is written.
    static let flashcardsSaveDelay: Duration = .milliseconds(400)

    /// "Karteikarten" (⌥⌘L): continues the set's deck, else starts one.
    func continueFlashcards(setID: String) {
        if case let .flashcards(request) = route, request.setID == setID { return }
        study(.flashcards, setID: setID)
    }

    /// "Karteikarten neu starten": same cards (all or the starred ones); a deck with sorting
    /// only starts over after asking.
    func restartFlashcards(setID: String) {
        guard let deck = runningFlashcardDeck(for: setID) else {
            study(.flashcards, setID: setID, forceNew: true)
            return
        }
        let subset: StudySubset? = deck.starredOnly ? .starred : nil
        confirm(ConfirmationRequest(
            title: String(localized: "Karteikarten neu starten?"), message: FlashcardCopy.restartMessage(deck),
            confirmLabel: String(localized: "Neu starten")
        ) { [weak self] in
            self?.study(.flashcards, setID: setID, subset: subset, forceNew: true)
        })
    }

    /// The set's deck, if it was started.
    func flashcardDeck(for setID: String) -> FlashcardDeck? {
        flashcardDecks[setID]
    }

    /// The set's deck while it is under way: sorted at least one card and not finished. As the set
    /// is now: cards deleted or added since the deck was last open are taken into account (the
    /// stored deck itself follows once it is opened again).
    func runningFlashcardDeck(for setID: String) -> FlashcardDeck? {
        guard var deck = flashcardDecks[setID] else { return nil }
        if let set = store.getSet(setID) { _ = deck.sync(with: set.cards, now: deck.updatedAt) }
        guard deck.isResumable, deck.hasProgress else { return nil }
        return deck
    }

    /// Keeps `deck` as the set's deck (nil forgets it) and writes the decks shortly after.
    func storeFlashcardDeck(_ deck: FlashcardDeck?, for setID: String) {
        guard flashcardDecks[setID] != deck else { return }
        flashcardDecks[setID] = deck
        scheduleFlashcardsSave()
    }

    // MARK: Storage

    /// "library.flashcards.json" beside the library file (nil for in-memory libraries).
    var flashcardsFileURL: URL? {
        guard persistence == .enabled, let url = libraryFileURL else { return nil }
        return url.deletingPathExtension().appendingPathExtension("flashcards.json")
    }

    /// The stored decks of sets that still exist; unreadable or inconsistent ones are dropped.
    func loadFlashcardDecks() -> [String: FlashcardDeck] {
        guard let url = flashcardsFileURL, let data = try? Data(contentsOf: url),
            let decks = try? JSONDecoder().decode([String: FlashcardDeck].self, from: data)
        else { return [:] }
        return decks.filter { $0.value.isConsistent && store.getSet($0.key) != nil }
    }

    private func scheduleFlashcardsSave() {
        guard flashcardsFileURL != nil, flashcardsSaveTask == nil else { return }
        flashcardsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashcardsSaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.writeFlashcards(waiting: false)
        }
    }

    /// Writes the decks now, if a change is waiting (also called by `save()`, so quitting keeps
    /// the last sort). A failure is not worth an alert: the decks stay in memory.
    func saveFlashcardsNow() {
        writeFlashcards(waiting: true)
        // A delayed write handed to the queue a moment ago may still be under way: wait for it
        // too, or quitting right after a sort could end the app in the middle of it.
        Self.flashcardsWriter.sync {}
    }

    /// Encodes and writes the decks on `flashcardsWriter`, after any write still under way; waits
    /// for it when `waiting` (quitting). The delayed save does not wait: on the main thread it cost
    /// the next card's animation frames, 400 ms after each sorted card.
    private func writeFlashcards(waiting: Bool) {
        guard let task = flashcardsSaveTask else { return }
        task.cancel()
        flashcardsSaveTask = nil
        guard let url = flashcardsFileURL else { return }
        let decks = flashcardDecks.filter { store.getSet($0.key) != nil }
        let write: @Sendable () -> Void = {
            guard let data = try? JSONEncoder().encode(decks) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if waiting {
            Self.flashcardsWriter.sync(execute: write)
        } else {
            Self.flashcardsWriter.async(execute: write)
        }
    }

    /// One write after the other, so an older one never lands after a newer one.
    nonisolated static let flashcardsWriter = DispatchQueue(label: "Wortschatz.flashcards", qos: .utility)
}
