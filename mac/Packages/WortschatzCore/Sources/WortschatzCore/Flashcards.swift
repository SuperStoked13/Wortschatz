import Foundation

// Karteikarten (Quizlet's Flashcards with "Fortschritt verfolgen"): the cards of a set one at a
// time; the learner turns a card over and sorts it into "Weiss ich" (→) or "Lerne ich noch" (←).
// At the end of a round the "Lerne ich noch" cards come again, until every card is known.
// Sorting is self-assessment only: it never touches the mastery progress (Lernen and Schreiben
// test for that). The deck is a plain value the app stores per set; no UI code lives here.

/// How the learner sorted a card.
public enum FlashcardVerdict: String, Codable, Sendable, Equatable, Hashable {
    /// "Weiss ich" (→).
    case know
    /// "Lerne ich noch" (←).
    case stillLearning
}

/// Which side of the cards is up first.
public enum FlashcardFront: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// The term (the learnt language, e.g. French).
    case term
    /// The definition (the translation, e.g. German).
    case definition
}

/// What a key does on the flashcards screen.
public enum FlashcardAction: Sendable, Equatable, Hashable {
    case flip
    case sort(FlashcardVerdict)
    /// Takes the last sorted card back ("Zurück", ⌫).
    case undo
    /// "Weiter mit N Karten" after a round.
    case nextRound
    /// "Nochmal von vorne" once every card is known.
    case restart
    /// Back to the set (esc).
    case exit
}

/// One flashcards session of a set: the cards of the current round in the order they are shown,
/// how the learner sorted the ones before the current card, and the cards known in earlier
/// rounds.
public struct FlashcardDeck: Codable, Sendable, Equatable {
    public struct Sort: Codable, Sendable, Equatable, Hashable {
        public var cardID: String
        public var verdict: FlashcardVerdict

        public init(cardID: String, verdict: FlashcardVerdict) {
            self.cardID = cardID
            self.verdict = verdict
        }
    }

    public enum Phase: Sendable, Equatable {
        /// A card is on screen.
        case card
        /// The round is over and some cards are still being learnt.
        case roundDone
        /// Every card is known.
        case finished
        /// No card to show (the set has no card with text).
        case empty
    }

    /// The round, from 1.
    public private(set) var round: Int
    /// The cards of this round, in the order they are shown.
    public private(set) var queue: [String]
    /// This round's sorts, in order: `sorts[i]` is the sort of `queue[i]`.
    public private(set) var sorts: [Sort]
    /// Cards sorted into "Weiss ich" in earlier rounds.
    public private(set) var knownEarlier: [String]
    /// The current card shows its back.
    public var isFlipped: Bool
    /// Only the starred cards (the subset the deck was started with).
    public private(set) var starredOnly: Bool
    /// The cards come in random order (else in the set's order).
    public private(set) var isShuffled: Bool
    /// When the deck last changed (ms since 1970).
    public var updatedAt: Double

    /// A new deck over `cards`: the ones with text on at least one side (only starred ones when
    /// `starredOnly`), in the set's order or shuffled.
    public init(cards: [Card], starredOnly: Bool = false, shuffled: Bool = false, rng: RNG = systemRNG(), now: Double) {
        let ids = Self.eligibleIDs(cards, starredOnly: starredOnly)
        round = 1
        queue = shuffled ? Self.shuffled(ids, rng) : ids
        sorts = []
        knownEarlier = []
        isFlipped = false
        self.starredOnly = starredOnly
        isShuffled = shuffled
        updatedAt = now
    }

    /// Ids of the cards a deck shows, in the set's order.
    public static func eligibleIDs(_ cards: [Card], starredOnly: Bool) -> [String] {
        var seen = Set<String>()
        return cards.compactMap { card in
            guard hasText(card), !starredOnly || card.starred, !card.id.isEmpty, seen.insert(card.id).inserted else {
                return nil
            }
            return card.id
        }
    }

    // MARK: Reading

    public var phase: Phase {
        if queue.isEmpty && knownEarlier.isEmpty { return .empty }
        if sorts.count < queue.count { return .card }
        return learningCount > 0 ? .roundDone : .finished
    }

    /// The card on screen (nil after the round).
    public var currentCardID: String? {
        sorts.count < queue.count ? queue[sorts.count] : nil
    }

    /// The cards waiting under the current one, next first.
    public var upcomingCardIDs: ArraySlice<String> {
        sorts.count + 1 < queue.count ? queue[(sorts.count + 1)...] : []
    }

    /// All cards of the deck.
    public var total: Int { knownEarlier.count + queue.count }
    /// Cards of this round.
    public var roundSize: Int { queue.count }
    /// Cards already sorted in this round.
    public var sortedInRound: Int { sorts.count }
    /// Cards of this round still to come, the current one included.
    public var remaining: Int { queue.count - sorts.count }
    /// "Weiss ich" over all rounds.
    public var knownCount: Int { knownEarlier.count + sorts.lazy.filter { $0.verdict == .know }.count }
    /// "Lerne ich noch" in this round.
    public var learningCount: Int { sorts.lazy.filter { $0.verdict == .stillLearning }.count }
    /// "Weiss ich" in this round.
    public var knownInRound: Int { sorts.count - learningCount }

    /// The last sort can be taken back.
    public var canUndo: Bool { !sorts.isEmpty }

    /// Starting over would throw sorting away.
    public var hasProgress: Bool { !sorts.isEmpty || round > 1 }

    /// The deck can be resumed (not finished, not empty).
    public var isResumable: Bool {
        switch phase {
        case .card, .roundDone: true
        case .finished, .empty: false
        }
    }

    /// Share of the deck known (0…1).
    public var knownShare: Double {
        total > 0 ? Double(knownCount) / Double(total) : 0
    }

    /// Whether a stored deck makes sense: every sort belongs to the card at its place, no card
    /// twice. Decks read back from storage are checked before they are used.
    public var isConsistent: Bool {
        guard round >= 1, sorts.count <= queue.count else { return false }
        for (index, sort) in sorts.enumerated() where queue[index] != sort.cardID { return false }
        let all = queue + knownEarlier
        return Set(all).count == all.count
    }

    // MARK: Changing

    /// Turns the current card over.
    public mutating func flip(now: Double) {
        guard phase == .card else { return }
        isFlipped.toggle()
        updatedAt = now
    }

    /// Sorts the current card; the next one comes up front side first. Nil when there is no
    /// current card.
    @discardableResult
    public mutating func sort(_ verdict: FlashcardVerdict, now: Double) -> Sort? {
        guard let id = currentCardID else { return nil }
        let sort = Sort(cardID: id, verdict: verdict)
        sorts.append(sort)
        isFlipped = false
        updatedAt = now
        return sort
    }

    /// Takes the last sort of this round back: that card is the current one again, front side
    /// up. Nil when nothing was sorted in this round.
    @discardableResult
    public mutating func undo(now: Double) -> Sort? {
        guard let last = sorts.popLast() else { return nil }
        isFlipped = false
        updatedAt = now
        return last
    }

    /// After a round: the "Lerne ich noch" cards again (shuffled, or in the set's order
    /// `cardOrder`; without it in the order they came), the known ones are put aside.
    public mutating func startNextRound(cardOrder: [String]? = nil, rng: RNG = systemRNG(), now: Double) {
        guard phase == .roundDone else { return }
        knownEarlier += sorts.filter { $0.verdict == .know }.map(\.cardID)
        let again = sorts.filter { $0.verdict == .stillLearning }.map(\.cardID)
        queue = isShuffled ? Self.shuffled(again, rng) : cardOrder.map { Self.ordered(again, by: $0) } ?? again
        sorts = []
        round += 1
        isFlipped = false
        updatedAt = now
    }

    /// Shuffles the cards still to come after the current one, or puts them back into the set's
    /// order (`cardOrder`: the set's card ids).
    public mutating func setShuffled(_ shuffled: Bool, cardOrder: [String], rng: RNG = systemRNG(), now: Double) {
        guard shuffled != isShuffled else { return }
        isShuffled = shuffled
        updatedAt = now
        let start = min(queue.count, sorts.count + 1)
        let rest = Array(queue[start...])
        guard rest.count > 1 else { return }
        queue.replaceSubrange(start..., with: shuffled ? Self.shuffled(rest, rng) : Self.ordered(rest, by: cardOrder))
    }

    /// `ids` in the order of `cardOrder` (ids it does not know last, as they were).
    static func ordered(_ ids: [String], by cardOrder: [String]) -> [String] {
        let position = Dictionary(cardOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated()
            .sorted { (position[$0.element] ?? .max, $0.offset) < (position[$1.element] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// Follows changes of the set: deleted cards (or cards without text now) leave the deck, new
    /// cards join at the end of this round. A starred-only deck keeps its cards when their star
    /// is removed and takes newly starred cards in. Returns whether the deck changed.
    @discardableResult
    public mutating func sync(with cards: [Card], now: Double) -> Bool {
        let present = Set(cards.filter(Self.hasText).map(\.id))
        let before = self
        let currentID = currentCardID

        // Drop what is gone, keeping each sort next to its card.
        var keptQueue: [String] = []
        var keptSorts: [Sort] = []
        for (index, id) in queue.enumerated() where present.contains(id) {
            keptQueue.append(id)
            if index < sorts.count { keptSorts.append(sorts[index]) }
        }
        // The sorted cards are the queue's head, so they stay its head.
        queue = keptQueue
        sorts = keptSorts
        knownEarlier = knownEarlier.filter(present.contains)

        let inDeck = Set(queue).union(knownEarlier)
        let joining = Self.eligibleIDs(cards, starredOnly: starredOnly).filter { !inDeck.contains($0) }
        queue += joining

        if currentCardID != currentID { isFlipped = false }
        guard self != before else { return false }
        updatedAt = now
        return true
    }

    // MARK: Keys

    /// What a key does in `phase` (nil: nothing). Held keys do nothing (one press, one step).
    public static func action(for key: KeyInput, isRepeat: Bool, phase: Phase) -> FlashcardAction? {
        guard !isRepeat else { return nil }
        if key == .escape { return .exit }
        switch phase {
        case .card:
            switch key {
            case .returnKey, .character(" "), .arrow(.up), .arrow(.down): return .flip
            case .arrow(.left): return .sort(.stillLearning)
            case .arrow(.right): return .sort(.know)
            case .deleteBackward: return .undo
            default: return nil
            }
        case .roundDone:
            switch key {
            case .returnKey: return .nextRound
            case .deleteBackward: return .undo
            default: return nil
            }
        case .finished:
            switch key {
            case .returnKey: return .restart
            case .deleteBackward: return .undo
            default: return nil
            }
        case .empty:
            return nil
        }
    }

    // MARK: Helpers

    static func hasText(_ card: Card) -> Bool {
        !card.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !card.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fisher–Yates on a copy.
    static func shuffled<T>(_ list: [T], _ rng: RNG) -> [T] {
        var a = list
        var i = a.count - 1
        while i > 0 {
            let r = Int((rng() * Double(i + 1)).rounded(.down))
            a.swapAt(i, min(max(r, 0), i))
            i -= 1
        }
        return a
    }
}

// MARK: - Copy

/// Texts of the flashcards screen (German source, translated with `L`).
public enum FlashcardCopy {
    /// "1 Karte", "12 Karten".
    public static func cards(_ n: Int) -> String {
        Labels.plural(n, "Karte", "Karten")
    }

    /// The set page's line under a running deck: "Runde 2 · 8 von 12 gewusst".
    public static func runningDetail(_ deck: FlashcardDeck) -> String {
        let round = deck.phase == .roundDone ? L("Runde %@ geschafft", "\(deck.round)") : L("Runde %@", "\(deck.round)")
        var parts = [round, L("%@ von %@ gewusst", "\(deck.knownCount)", "\(deck.total)")]
        if deck.starredOnly { parts.insert(L("Nur markierte"), at: 0) }
        return parts.joined(separator: " · ")
    }

    /// The Return action after a round: "Weiter mit 4 Karten".
    public static func nextRoundAction(_ deck: FlashcardDeck) -> String {
        L("Weiter mit %@", cards(deck.learningCount))
    }

    public static func roundDoneTitle(_ deck: FlashcardDeck) -> String {
        deck.knownInRound == 0 ? L("Bleib dran!") : L("Du machst Fortschritte!")
    }

    /// "Du kennst 8 von 12 Karten. Die 4 Karten, die du noch lernst, kommen jetzt nochmal."
    public static func roundDoneText(_ deck: FlashcardDeck) -> String {
        let learning = deck.learningCount
        let again =
            learning == 1
            ? L("Die Karte, die du noch lernst, kommt jetzt nochmal.")
            : L("Die %@ Karten, die du noch lernst, kommen jetzt nochmal.", "\(learning)")
        let known = L("Du kennst %@ von %@.", "\(deck.knownCount)", cards(deck.total))
        return "\(known) \(again)"
    }

    public static func finishedTitle(_ deck: FlashcardDeck) -> String {
        deck.total == 1 ? L("Super, du kennst die Karte!") : L("Super, du kennst alle %@ Karten!", "\(deck.total)")
    }

    public static func finishedText(_ deck: FlashcardDeck) -> String {
        let rounds =
            deck.round == 1 ? L("Gleich in der ersten Runde – stark.") : L("Geschafft in %@ Runden.", "\(deck.round)")
        let test =
            deck.total == 1
            ? L("Teste dich jetzt in «Lernen», damit sie auch als gemeistert zählt.")
            : L("Teste dich jetzt in «Lernen», damit sie auch als gemeistert zählen.")
        return "\(rounds) \(test)"
    }

    /// The confirmation before starting over.
    public static func restartMessage(_ deck: FlashcardDeck) -> String {
        L("Deine Sortierung (%@) beginnt von vorne. Dein Lernfortschritt bleibt erhalten.", runningDetail(deck))
    }
}
