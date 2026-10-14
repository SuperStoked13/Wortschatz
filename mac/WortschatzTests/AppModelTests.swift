import AppKit
import Foundation
import SwiftUI
import Testing
import WortschatzCore

@testable import Wortschatz

// Unit tests of the app target's own logic (hosted in the DEBUG app, which then runs on an empty
// in-memory library; see `AppModel.launch`). Every model here uses in-memory sample data.

/// "Löschen" (⌘⌫) has no confirmation; ⌘Z is the safety net, also after the toast is gone.
@MainActor
@Suite("Lernset löschen und widerrufen")
struct SetDeletionUndoTests {
    @Test("⌘Z stellt das Lernset wieder her, auch wenn der Hinweis schon weg ist")
    func undoAfterTheToastIsGone() throws {
        let model = SampleLibrary.model(.populated)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.windowUndoManager = undo
        let setID = try #require(model.library.sets.first?.id)
        let cardCount = try #require(model.store.getSet(setID)).cards.count

        undo.beginUndoGrouping()
        model.deleteSet(setID)
        undo.endUndoGrouping()
        #expect(model.store.getSet(setID) == nil)

        // The 7-second "Rückgängig" toast timed out: only the undo stack is left.
        model.toasts.dismissAll()
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Lernset löschen")
        undo.undo()
        #expect(model.store.getSet(setID)?.cards.count == cardCount)

        // Redo deletes it again, and the next undo restores it again.
        model.toasts.dismissAll()
        #expect(undo.canRedo)
        undo.redo()
        #expect(model.store.getSet(setID) == nil)
        model.toasts.dismissAll()
        undo.undo()
        #expect(model.store.getSet(setID)?.cards.count == cardCount)
    }

    @Test("«Rückgängig» im Hinweis stellt das Lernset einmal wieder her und leert den Widerrufen-Eintrag")
    func undoFromTheToast() throws {
        let model = SampleLibrary.model(.populated)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.windowUndoManager = undo
        let setID = try #require(model.library.sets.first?.id)

        undo.beginUndoGrouping()
        model.deleteSet(setID)
        undo.endUndoGrouping()
        let toast = try #require(model.toasts.toasts.last)
        let action = try #require(toast.action)
        action.perform()

        #expect(model.store.getSet(setID) != nil)
        #expect(!undo.canUndo)
    }
}

/// Closing and reopening the main window while studying rebuilds the study screen from the
/// route: it must continue the running session, not quietly start a new one.
@MainActor
@Suite("Lernen und Schreiben nach dem Wiederöffnen des Fensters")
struct StudyRouteResumeTests {
    /// A clock that moves 1 s per reading, so the flows' input lock never swallows a key.
    private static func steppingClock() -> () -> Double {
        var now = 1_760_000_000_000.0
        return {
            now += 1000
            return now
        }
    }

    private static func freshModel() throws -> (AppModel, String) {
        let model = SampleLibrary.model(.fresh)
        let setID = try #require(model.library.sets.first?.id)
        return (model, setID)
    }

    @Test("Lernen: die Route setzt die gestartete Sitzung fort")
    func learnResumesAfterTheScreenIsRebuilt() throws {
        let (model, setID) = try Self.freshModel()
        model.continueLearn(setID: setID)
        let started = try #require(model.route.study)
        #expect(started.forceNew, "No session yet: Lernen starts a new one")

        let first = LearnController(
            model: model, request: started, rng: mulberry32(seed: 7), clock: Self.steppingClock(), isLive: false)
        first.activate()
        let resumed = try #require(model.route.study)
        #expect(resumed.id == started.id, "Same request: the open screen stays")
        #expect(!resumed.forceNew)
        #expect(resumed.subset == nil)

        first.send(.key(.digit(1), isRepeat: false))
        let session = try #require(first.state.session)
        #expect(session.answered == 1)

        // The window was closed and reopened: a new screen for the same route.
        let second = LearnController(
            model: model, request: resumed, rng: mulberry32(seed: 99), clock: Self.steppingClock(), isLive: false)
        second.activate()
        #expect(second.state.session?.startedAt == session.startedAt)
        #expect(second.state.session?.answered == 1)
    }

    @Test("Schreiben: die Route setzt die gestartete Runde fort")
    func writeResumesAfterTheScreenIsRebuilt() throws {
        let (model, setID) = try Self.freshModel()
        model.continueWrite(setID: setID)
        let started = try #require(model.route.study)
        #expect(started.forceNew)

        let first = WriteController(
            model: model, request: started, rng: mulberry32(seed: 7), clock: Self.steppingClock(), isLive: false)
        first.activate()
        let resumed = try #require(model.route.study)
        #expect(resumed.id == started.id)
        #expect(!resumed.forceNew)

        first.send(.inputChanged("falsch"))
        first.send(.key(.returnKey, isRepeat: false))
        let session = try #require(first.state.session)
        #expect(session.roundAnswered.count == 1)

        let second = WriteController(
            model: model, request: resumed, rng: mulberry32(seed: 99), clock: Self.steppingClock(), isLive: false)
        second.activate()
        #expect(second.state.session?.startedAt == session.startedAt)
        #expect(second.state.session?.roundAnswered.count == 1)
    }

    @Test("Eine Teilmenge («Nur markierte») wird nach dem Start ebenfalls fortgesetzt")
    func subsetStartBecomesAResume() throws {
        let (model, setID) = try Self.freshModel()
        model.study(.learn, setID: setID, subset: .learning, forceNew: true)
        let started = try #require(model.route.study)
        let controller = LearnController(
            model: model, request: started, rng: mulberry32(seed: 3), clock: Self.steppingClock(), isLive: false)
        controller.activate()
        let resumed = try #require(model.route.study)
        #expect(resumed.id == started.id)
        #expect(resumed.subset == nil && !resumed.forceNew)
        #expect(model.route == .learn(resumed))
    }

    @Test("Ein veralteter Bildschirm ändert die Route nicht")
    func staleScreenLeavesTheRouteAlone() throws {
        let (model, setID) = try Self.freshModel()
        model.study(.learn, setID: setID, forceNew: true)
        let old = try #require(model.route.study)
        model.study(.write, setID: setID, forceNew: true)
        let current = try #require(model.route.study)

        model.studySessionStarted(requestID: old.id)
        #expect(model.route == .write(current))
    }
}

/// One Return press is one step (spec §4.3): buttons bound to a key ignore auto-repeat and wait
/// a moment after Return changed the screen.
@MainActor
@Suite("Tastenschutz für Knöpfe mit Kurzbefehl", .serialized)
struct KeyActionGateTests {
    private static func key(_ characters: String, isARepeat: Bool = false) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: isARepeat,
                keyCode: characters == "\r" ? 36 : 0))
    }

    @Test("Automatische Wiederholung löst nie aus")
    func autoRepeatIsIgnored() throws {
        KeyActionGate.reset()
        #expect(!KeyActionGate.allows(try Self.key("\r", isARepeat: true)))
        #expect(KeyActionGate.allows(try Self.key("\r")))
    }

    @Test("Ein zweites ↩ direkt nach einem Bildschirmwechsel per ↩ wartet")
    func returnRightAfterNavigationWaits() throws {
        KeyActionGate.reset()
        let start = ContinuousClock.now
        KeyActionGate.returnKeyMoved(by: try Self.key("\r"), at: start)
        #expect(!KeyActionGate.allows(try Self.key("\r"), at: start + .milliseconds(150)))
        #expect(KeyActionGate.allows(try Self.key("\r"), at: start + KeyActionGate.settleTime + .milliseconds(1)))
        KeyActionGate.reset()
    }

    @Test("Klicks und andere Tasten werden nie aufgehalten")
    func clicksAndOtherKeysPass() throws {
        KeyActionGate.reset()
        let start = ContinuousClock.now
        // Navigation by another key (an arrow in the sidebar) or a click starts no settle time.
        KeyActionGate.returnKeyMoved(by: try Self.key("a"), at: start)
        KeyActionGate.returnKeyMoved(by: nil, at: start)
        #expect(KeyActionGate.allows(try Self.key("\r"), at: start + .milliseconds(10)))

        KeyActionGate.returnKeyMoved(by: try Self.key("\r"), at: start)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(KeyActionGate.allows(click, at: start + .milliseconds(10)))
        #expect(KeyActionGate.allows(nil, at: start + .milliseconds(10)))
        KeyActionGate.reset()
    }
}

/// ⌥↩ and esc typed in an answer field reach the study flow; everything else stays typing.
@Suite("Tasten im Antwortfeld")
struct StudyFieldKeyTests {
    @Test("⌥↩ und esc gehen an den Ablauf")
    func optionReturnAndEscape() {
        #expect(LearnKeyRouter.fieldInput(key: .return, characters: "\r", modifiers: .option) == .optionReturn)
        #expect(LearnKeyRouter.fieldInput(key: KeyEquivalent("\u{3}"), characters: "\u{3}", modifiers: .option) == .optionReturn)
        #expect(LearnKeyRouter.fieldInput(key: .escape, characters: "\u{1b}", modifiers: []) == .escape)
    }

    @Test("↩, ⌘↩ und Tippen bleiben beim Feld bzw. beim Menü")
    func everythingElseStays() {
        #expect(LearnKeyRouter.fieldInput(key: .return, characters: "\r", modifiers: []) == nil)
        #expect(LearnKeyRouter.fieldInput(key: .return, characters: "\r", modifiers: .command) == nil)
        #expect(LearnKeyRouter.fieldInput(key: .return, characters: "\r", modifiers: .control) == nil)
        #expect(LearnKeyRouter.fieldInput(key: .escape, characters: "\u{1b}", modifiers: .option) == nil)
        #expect(LearnKeyRouter.fieldInput(key: KeyEquivalent("a"), characters: "a", modifiers: []) == nil)
        #expect(LearnKeyRouter.fieldInput(key: KeyEquivalent("1"), characters: "1", modifiers: []) == nil)
    }
}

/// Quitting writes unsaved changes; a failure asks instead of dropping them silently.
@MainActor
@Suite("Beenden mit ungespeicherten Änderungen")
struct TerminationTests {
    /// The backend's error when the disk is full (the store reports it as `.quota`).
    private static func diskFull() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    }

    /// A persisting model with one unsaved change; its backend fails the next save.
    private static func unsavedModel() throws -> (AppModel, MemoryBackend) {
        let backend = MemoryBackend()
        let model = AppModel(store: LibraryStore(backend: backend), persistence: .enabled)
        try model.store.createSet(title: "Unité 4", cards: [CardDraft(term: "la ville", definition: "die Stadt")])
        #expect(model.store.hasUnsavedChanges)
        backend.failNextSave = Self.diskFull()
        return (model, backend)
    }

    @Test("Ohne Fehler wird gespeichert und beendet, ohne zu fragen")
    func savesAndQuits() throws {
        let (model, backend) = try Self.unsavedModel()
        backend.failNextSave = nil
        var asked = 0
        let reply = model.replyToTermination(ask: { _ in
            asked += 1
            return .stay
        }, exportBackup: { _, _ in false })
        #expect(reply == .terminateNow)
        #expect(asked == 0)
        #expect(backend.saveCount == 1)
        #expect(!model.store.hasUnsavedChanges)
    }

    @Test("Abbrechen lässt die App offen und die Änderungen im Speicher")
    func staying() throws {
        let (model, _) = try Self.unsavedModel()
        var messages: [String] = []
        let reply = model.replyToTermination(ask: { message in
            messages.append(message)
            return .stay
        }, exportBackup: { _, _ in false })
        #expect(reply == .terminateCancel)
        #expect(messages == [StoreMessages.diskFull])
        #expect(model.store.hasUnsavedChanges)
    }

    @Test("Nochmal versuchen speichert, sobald es wieder geht")
    func retry() throws {
        let (model, backend) = try Self.unsavedModel()
        var choices: [QuitAfterFailedSave] = [.retry, .retry]
        let reply = model.replyToTermination(ask: { _ in
            let choice = choices.removeFirst()
            // The first retry fails again, the second one works.
            if !choices.isEmpty { backend.failNextSave = Self.diskFull() }
            return choice
        }, exportBackup: { _, _ in false })
        #expect(reply == .terminateNow)
        #expect(choices.isEmpty)
        #expect(backend.saveCount == 1)
    }

    @Test("Backup exportieren sichert alles und beendet; abgebrochen wird wieder gefragt")
    func exportBackup() throws {
        let (model, backend) = try Self.unsavedModel()
        var choices: [QuitAfterFailedSave] = [.exportBackup, .exportBackup]
        var exports: [(Data, String)] = []
        let reply = model.replyToTermination(ask: { _ in
            backend.failNextSave = Self.diskFull()
            return choices.removeFirst()
        }, exportBackup: { document, fileName in
            exports.append((document, fileName))
            // The first save panel is cancelled.
            return exports.count == 2
        })
        #expect(reply == .terminateNow)
        #expect(exports.count == 2)
        let (document, fileName) = try #require(exports.last)
        #expect(fileName.hasPrefix("wortschatz-backup-") && fileName.hasSuffix(".json"))
        #expect(String(decoding: document, as: UTF8.self).contains("Unité 4"))
    }

    @Test("Trotzdem beenden beendet ohne Speichern")
    func quitAnyway() throws {
        let (model, backend) = try Self.unsavedModel()
        let reply = model.replyToTermination(ask: { _ in .quitAnyway }, exportBackup: { _, _ in false })
        #expect(reply == .terminateNow)
        #expect(backend.saveCount == 0)
    }
}
