import Foundation
import Testing
import WortschatzCore

/// Karteikarten: turning cards over, sorting them into "Weiss ich" / "Lerne ich noch", rounds of
/// the cards still being learnt, taking a sort back, following changes of the set, the keys.
@Suite("Flashcards")
struct FlashcardsTests {
    static let T0: Double = 1_760_000_000_000

    static func card(_ id: String, _ term: String = "le mot", _ definition: String = "das Wort", starred: Bool = false) -> Card {
        Card(id: id, term: term, definition: definition, starred: starred)
    }

    static let cards = [card("a"), card("b"), card("c"), card("d")]

    static func deck(_ cards: [Card] = cards, starredOnly: Bool = false) -> FlashcardDeck {
        FlashcardDeck(cards: cards, starredOnly: starredOnly, now: T0)
    }

    // MARK: Starting

    @Test("A new deck shows the cards with text in the set's order, front side up")
    func newDeck() {
        let cards = [Self.card("a"), Self.card("empty", " ", ""), Self.card("b", "", "nur Deutsch"), Self.card("a")]
        let deck = Self.deck(cards)
        #expect(deck.queue == ["a", "b"])
        #expect(deck.currentCardID == "a")
        #expect(deck.phase == .card)
        #expect(!deck.isFlipped)
        #expect(deck.round == 1 && deck.total == 2 && deck.remaining == 2)
        #expect(!deck.hasProgress && !deck.canUndo)
    }

    @Test("Starred only takes the starred cards; none starred is an empty deck")
    func starredOnly() {
        let cards = [Self.card("a"), Self.card("b", starred: true), Self.card("c", starred: true)]
        #expect(Self.deck(cards, starredOnly: true).queue == ["b", "c"])
        #expect(Self.deck([Self.card("a")], starredOnly: true).phase == .empty)
        #expect(Self.deck([]).phase == .empty)
    }

    @Test("Shuffled decks contain every card once and replay with the same seed")
    func shuffledDeck() {
        let cards = (0..<20).map { Self.card("c\($0)") }
        let one = FlashcardDeck(cards: cards, shuffled: true, rng: mulberry32(seed: 7), now: Self.T0)
        let two = FlashcardDeck(cards: cards, shuffled: true, rng: mulberry32(seed: 7), now: Self.T0)
        #expect(one.queue == two.queue)
        #expect(Set(one.queue) == Set(cards.map(\.id)))
        #expect(one.queue != cards.map(\.id))
        #expect(one.isShuffled)
    }

    // MARK: Flipping and sorting

    @Test("Flipping turns the card; sorting moves on with the next card front side up")
    func flipAndSort() {
        var deck = Self.deck()
        deck.flip(now: Self.T0 + 1)
        #expect(deck.isFlipped)
        deck.flip(now: Self.T0 + 2)
        #expect(!deck.isFlipped)
        deck.flip(now: Self.T0 + 3)
        let sort = deck.sort(.know, now: Self.T0 + 4)
        #expect(sort == FlashcardDeck.Sort(cardID: "a", verdict: .know))
        #expect(deck.currentCardID == "b")
        #expect(!deck.isFlipped)
        #expect(deck.knownCount == 1 && deck.learningCount == 0 && deck.remaining == 3)
        #expect(deck.upcomingCardIDs == ["c", "d"])
        #expect(deck.hasProgress && deck.canUndo)
        #expect(deck.updatedAt == Self.T0 + 4)
    }

    @Test("A card can be sorted without turning it over")
    func sortWithoutFlip() {
        var deck = Self.deck()
        deck.sort(.stillLearning, now: Self.T0)
        #expect(deck.learningCount == 1)
        #expect(deck.currentCardID == "b")
    }

    @Test("Undo brings the last card back front side up, also from the round summary")
    func undo() {
        var deck = Self.deck([Self.card("a"), Self.card("b")])
        deck.sort(.know, now: Self.T0)
        deck.flip(now: Self.T0)
        deck.sort(.stillLearning, now: Self.T0)
        #expect(deck.phase == .roundDone)
        let undone = deck.undo(now: Self.T0)
        #expect(undone?.cardID == "b")
        #expect(deck.phase == .card && deck.currentCardID == "b" && !deck.isFlipped)
        #expect(deck.learningCount == 0 && deck.knownCount == 1)
        deck.undo(now: Self.T0)
        #expect(deck.currentCardID == "a")
        let nothing = deck.undo(now: Self.T0)
        #expect(nothing == nil)
    }

    // MARK: Rounds

    @Test("After a round the cards still being learnt come again; known ones stay known")
    func rounds() {
        var deck = Self.deck()
        deck.sort(.know, now: Self.T0)
        deck.sort(.stillLearning, now: Self.T0)
        deck.sort(.know, now: Self.T0)
        deck.sort(.stillLearning, now: Self.T0)
        #expect(deck.phase == .roundDone)
        #expect(deck.currentCardID == nil)
        #expect(FlashcardCopy.nextRoundAction(deck) == "Weiter mit 2 Karten")
        #expect(FlashcardCopy.runningDetail(deck) == "Runde 1 geschafft · 2 von 4 gewusst")

        deck.startNextRound(now: Self.T0)
        #expect(deck.round == 2)
        #expect(deck.queue == ["b", "d"])
        #expect(deck.knownEarlier == ["a", "c"])
        #expect(deck.knownCount == 2 && deck.total == 4 && deck.remaining == 2)
        #expect(!deck.canUndo)
        #expect(FlashcardCopy.runningDetail(deck) == "Runde 2 · 2 von 4 gewusst")

        deck.sort(.know, now: Self.T0)
        deck.sort(.know, now: Self.T0)
        #expect(deck.phase == .finished)
        #expect(deck.knownCount == 4 && deck.knownShare == 1)
        #expect(!deck.isResumable)
        #expect(FlashcardCopy.finishedTitle(deck) == "Super, du kennst alle 4 Karten!")
        #expect(FlashcardCopy.finishedText(deck).hasPrefix("Geschafft in 2 Runden."))
    }

    @Test("Everything known in the first round finishes at once")
    func finishedFirstRound() {
        var deck = Self.deck([Self.card("a")])
        deck.sort(.know, now: Self.T0)
        #expect(deck.phase == .finished)
        #expect(FlashcardCopy.finishedTitle(deck) == "Super, du kennst die Karte!")
        // Nothing happens to a finished deck.
        deck.startNextRound(now: Self.T0)
        #expect(deck.round == 1)
        let none = deck.sort(.know, now: Self.T0)
        #expect(none == nil)
    }

    @Test("The round summary's text counts singular and plural")
    func roundDoneCopy() {
        var deck = Self.deck([Self.card("a"), Self.card("b")])
        deck.sort(.stillLearning, now: Self.T0)
        deck.sort(.know, now: Self.T0)
        #expect(FlashcardCopy.roundDoneTitle(deck) == "Du machst Fortschritte!")
        #expect(
            FlashcardCopy.roundDoneText(deck)
                == "Du kennst 1 von 2 Karten. Die Karte, die du noch lernst, kommt jetzt nochmal.")
        #expect(FlashcardCopy.nextRoundAction(deck) == "Weiter mit 1 Karte")

        var none = Self.deck([Self.card("a"), Self.card("b")])
        none.sort(.stillLearning, now: Self.T0)
        none.sort(.stillLearning, now: Self.T0)
        #expect(FlashcardCopy.roundDoneTitle(none) == "Bleib dran!")
    }

    @Test("A shuffled deck shuffles the next round too")
    func shuffledNextRound() {
        let cards = (0..<12).map { Self.card("c\($0)") }
        var deck = FlashcardDeck(cards: cards, shuffled: true, rng: mulberry32(seed: 3), now: Self.T0)
        let first = deck.queue
        for _ in first { deck.sort(.stillLearning, now: Self.T0) }
        deck.startNextRound(rng: mulberry32(seed: 99), now: Self.T0)
        #expect(Set(deck.queue) == Set(first))
        #expect(deck.queue != first)
    }

    // MARK: Options

    @Test("Shuffling on and off reorders only the cards after the current one")
    func toggleShuffle() {
        let cards = (0..<10).map { Self.card("c\($0)") }
        let order = cards.map(\.id)
        var deck = FlashcardDeck(cards: cards, now: Self.T0)
        deck.sort(.know, now: Self.T0)
        deck.sort(.stillLearning, now: Self.T0)
        deck.setShuffled(true, cardOrder: order, rng: mulberry32(seed: 5), now: Self.T0)
        #expect(deck.isShuffled)
        #expect(Array(deck.queue.prefix(3)) == ["c0", "c1", "c2"])
        #expect(Set(deck.queue) == Set(order))
        #expect(deck.queue != order)
        deck.setShuffled(false, cardOrder: order, now: Self.T0)
        #expect(deck.queue == order)
        #expect(deck.sorts.count == 2)
    }

    @Test("Shuffling turned off at the round summary puts the next round in the set's order")
    func unshuffledNextRound() {
        let cards = (0..<8).map { Self.card("c\($0)") }
        let order = cards.map(\.id)
        var deck = FlashcardDeck(cards: cards, shuffled: true, rng: mulberry32(seed: 3), now: Self.T0)
        for _ in order { deck.sort(.stillLearning, now: Self.T0) }
        #expect(deck.phase == .roundDone)
        deck.setShuffled(false, cardOrder: order, now: Self.T0)
        deck.startNextRound(cardOrder: order, now: Self.T0)
        #expect(deck.queue == order)
    }

    // MARK: Changes of the set

    @Test("Deleted cards leave the deck, new cards join at the end of the round")
    func syncWithSet() {
        var deck = Self.deck()
        deck.sort(.know, now: Self.T0)  // a
        deck.sort(.stillLearning, now: Self.T0)  // b
        deck.flip(now: Self.T0)  // c is up, back side
        let changed = deck.sync(with: [Self.card("a"), Self.card("c"), Self.card("d"), Self.card("e")], now: Self.T0 + 9)
        #expect(changed)
        #expect(deck.queue == ["a", "c", "d", "e"])
        #expect(deck.sorts == [FlashcardDeck.Sort(cardID: "a", verdict: .know)])
        #expect(deck.currentCardID == "c")
        #expect(deck.isFlipped)
        #expect(deck.isConsistent)
        #expect(deck.updatedAt == Self.T0 + 9)
        let again = deck.sync(with: [Self.card("a"), Self.card("c"), Self.card("d"), Self.card("e")], now: Self.T0 + 10)
        #expect(!again)

        // The current card deleted: the next one comes up front side first.
        deck.sync(with: [Self.card("a"), Self.card("d"), Self.card("e")], now: Self.T0)
        #expect(deck.currentCardID == "d")
        #expect(!deck.isFlipped)
    }

    @Test("Known cards of earlier rounds that are deleted leave the totals")
    func syncKnownEarlier() {
        var deck = Self.deck([Self.card("a"), Self.card("b")])
        deck.sort(.know, now: Self.T0)
        deck.sort(.stillLearning, now: Self.T0)
        deck.startNextRound(now: Self.T0)
        deck.sync(with: [Self.card("b")], now: Self.T0)
        #expect(deck.knownEarlier.isEmpty)
        #expect(deck.total == 1)
        deck.sync(with: [], now: Self.T0)
        #expect(deck.phase == .empty)
    }

    @Test("Starred only keeps cards whose star was removed and takes newly starred ones in")
    func syncStarredOnly() {
        var deck = Self.deck([Self.card("a", starred: true), Self.card("b")], starredOnly: true)
        #expect(deck.queue == ["a"])
        deck.sync(with: [Self.card("a"), Self.card("b", starred: true)], now: Self.T0)
        #expect(deck.queue == ["a", "b"])
    }

    @Test("A stored deck is checked before it is used")
    func consistency() throws {
        var deck = Self.deck()
        deck.sort(.know, now: Self.T0)
        #expect(deck.isConsistent)
        let data = try JSONEncoder().encode(deck)
        let decoded = try JSONDecoder().decode(FlashcardDeck.self, from: data)
        #expect(decoded == deck)

        // A sort that does not belong to its card.
        let broken = #"{"round":1,"queue":["a","b"],"sorts":[{"cardID":"b","verdict":"know"}],"knownEarlier":[],"isFlipped":false,"starredOnly":false,"isShuffled":false,"updatedAt":0}"#
        let bad = try JSONDecoder().decode(FlashcardDeck.self, from: Data(broken.utf8))
        #expect(!bad.isConsistent)
        let twice = #"{"round":2,"queue":["a"],"sorts":[],"knownEarlier":["a"],"isFlipped":false,"starredOnly":false,"isShuffled":false,"updatedAt":0}"#
        #expect(!(try JSONDecoder().decode(FlashcardDeck.self, from: Data(twice.utf8))).isConsistent)
    }

    // MARK: Keys

    @Test("Space, Return and ↑↓ turn the card; ← and → sort; ⌫ takes back; esc leaves")
    func keysOnCard() {
        func action(_ key: KeyInput, repeat isRepeat: Bool = false) -> FlashcardAction? {
            FlashcardDeck.action(for: key, isRepeat: isRepeat, phase: .card)
        }
        #expect(action(.character(" ")) == .flip)
        #expect(action(.returnKey) == .flip)
        #expect(action(.arrow(.up)) == .flip)
        #expect(action(.arrow(.down)) == .flip)
        #expect(action(.arrow(.left)) == .sort(.stillLearning))
        #expect(action(.arrow(.right)) == .sort(.know))
        #expect(action(.deleteBackward) == .undo)
        #expect(action(.escape) == .exit)
        #expect(action(.character("x")) == nil)
        #expect(action(.digit(1)) == nil)
        // A held key is one step.
        #expect(action(.arrow(.right), repeat: true) == nil)
        #expect(action(.character(" "), repeat: true) == nil)
    }

    @Test("Return continues after a round and starts over at the end")
    func keysAfterRound() {
        #expect(FlashcardDeck.action(for: .returnKey, isRepeat: false, phase: .roundDone) == .nextRound)
        #expect(FlashcardDeck.action(for: .deleteBackward, isRepeat: false, phase: .roundDone) == .undo)
        #expect(FlashcardDeck.action(for: .arrow(.right), isRepeat: false, phase: .roundDone) == nil)
        #expect(FlashcardDeck.action(for: .returnKey, isRepeat: false, phase: .finished) == .restart)
        #expect(FlashcardDeck.action(for: .character(" "), isRepeat: false, phase: .finished) == nil)
        #expect(FlashcardDeck.action(for: .returnKey, isRepeat: false, phase: .empty) == nil)
        #expect(FlashcardDeck.action(for: .escape, isRepeat: false, phase: .empty) == .exit)
    }
}
