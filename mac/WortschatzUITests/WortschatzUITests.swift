import XCTest

/// The Enter-only flows of spec §4.3 / §5, played with the keyboard alone like a learner:
/// - a new set from the user's list through the editor (⌘N, typing, Return, ⌘V, ⌘↩);
/// - Lernen with the number keys and Return up to the checkpoint and into round 2, where the
///   same words come back as written questions;
/// - a Learn session that resumes after quitting and relaunching the app;
/// - esc and ⌥↩ while the answer field has the focus;
/// - typing goes on in the answer field after a click on a special character.
///
/// The app runs in DEBUG on sample data: `--sample-library <scenario>` keeps everything in
/// memory, `--ui-test-library <name>` uses a file of its own next to library.json (for the
/// relaunch). The learner's real library is never read or written.
///
/// Running them needs a logged-in GUI session and the UI-automation permission
/// (`mac/scripts/test.sh --ui`).
final class WortschatzUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsWindow() throws {
        let app = XCUIApplication.wortschatz("--sample-library", "populated")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.terminate()
    }

    // MARK: - Editor

    /// ⌘N, the title, ↩ (to the description), ↩ (to the import box), ⌘V of the list, ⌘↩: a new
    /// set with all 52 pairs, shown right away.
    @MainActor
    func testNewSetFromTheUserListWithTheKeyboardOnly() throws {
        let list = try UserList.load()
        XCTAssertEqual(list.pairs.count, 52)
        let clipboard = PasteboardSwap(list.text)
        defer { clipboard.restore() }

        let app = XCUIApplication.wortschatz("--sample-library", "empty")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: .command)
        let title = app.element("editor-title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "⌘N öffnet den Editor")
        // The title has the focus (set when the sheet appears).
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText(UserList.setTitle)
        XCTAssertTrue(
            waitUntil(timeout: 3) { textValue(title) == UserList.setTitle },
            "Der Titel bekommt die Eingabe: \(textValue(title))")

        app.pressReturn()  // → Beschreibung
        app.pressReturn()  // → Importfeld
        app.typeKey("v", modifierFlags: .command)

        let importText = app.element("editor-import-text")
        XCTAssertTrue(
            waitUntil(timeout: 5) { textValue(importText).contains("le monsieur, messieurs") },
            "⌘V fügt die Liste ins Importfeld ein")
        // The pairs are cards right away (no "übernehmen"): the save bar counts them.
        XCTAssertTrue(
            app.text(startingWith: "52 Karten").waitForExistence(timeout: 10), "52 Paare erkannt und als Karten in der Liste")

        // ⌘↩ saves.
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.text(startingWith: "52 Begriffe").waitForExistence(timeout: 10), "Das Lernset hat 52 Begriffe")
        XCTAssertFalse(title.exists, "Der Editor ist zu")
        XCTAssertTrue(app.text(containing: UserList.setTitle).exists)
        app.terminate()
    }

    // MARK: - Lernen

    /// Overview ↩ (opens the set), set ↩ (Lernen), 1-4 for every multiple-choice question of
    /// round 1, ↩ at the checkpoint; round 2 asks the same words in writing, answered with
    /// typing and ↩.
    @MainActor
    func testLearnWithNumberKeysAndReturnIntoTheWrittenRound() throws {
        let list = try UserList.load()
        let app = XCUIApplication.wortschatz("--sample-library", "fresh")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let learn = LearnDriver(app: app, list: list)

        openSetAndLearn(app)
        XCTAssertTrue(app.element("learn-prompt").waitForExistence(timeout: 10), "↩ auf dem Lernset startet Lernen")

        let round1 = learn.playChoices()
        XCTAssertTrue(learn.isAtCheckpoint, "Nach Runde 1 kommt der Zwischenstand")
        XCTAssertEqual(round1.count, 7, "Runde 1: 7 Begriffe (Standard), gefragt: \(round1)")
        XCTAssertTrue(app.text(containing: "Runde 1 geschafft").exists)

        app.pressReturn()  // Weiter zu Runde 2
        let answer = app.element("learn-answer")
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "Runde 2 fragt schriftlich")
        let prompt = try XCTUnwrap(learn.currentPrompt())
        XCTAssertTrue(round1.contains(prompt), "Runde 2 fragt einen Begriff aus Runde 1: «\(prompt)»")

        // The answer field has the focus: type the answer and press Return.
        let expected = try XCTUnwrap(list.answers(for: prompt).first)
        Thread.sleep(forTimeInterval: 0.5)
        app.typeText(expected)
        XCTAssertTrue(waitUntil(timeout: 3) { textValue(answer) == expected }, "Die Antwort steht im Feld: \(textValue(answer))")
        app.pressReturn()
        XCTAssertTrue(
            waitUntil(timeout: 5) { learn.isShowingFeedback || learn.currentPrompt() != prompt },
            "↩ prüft die Antwort")
        app.terminate()
    }

    /// Two answers, quit, relaunch: the overview's ↩ (Weiterlernen) continues the session on
    /// the same question with "Willkommen zurück".
    @MainActor
    func testLearnResumesAfterRelaunch() throws {
        let list = try UserList.load()
        let library = "uitest-resume"

        var app = XCUIApplication.wortschatz(
            "--ui-test-library", library, "--reset-library", "--sample-library", "fresh")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        openSetAndLearn(app)
        var learn = LearnDriver(app: app, list: list)
        XCTAssertTrue(app.element("learn-prompt").waitForExistence(timeout: 10))

        XCTAssertEqual(learn.playChoices(limit: 2).count, 2)
        // The third question is on screen; its state is saved within 300 ms.
        XCTAssertTrue(waitUntil(timeout: 5) { learn.choiceQuestion() != nil })
        let open = try XCTUnwrap(learn.choiceQuestion()?.prompt)
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()

        app = XCUIApplication.wortschatz("--ui-test-library", library)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        learn = LearnDriver(app: app, list: list)
        // The overview offers the running session first: Return continues it.
        Thread.sleep(forTimeInterval: 0.8)
        app.pressReturn()
        XCTAssertTrue(app.text(containing: "Willkommen zurück").waitForExistence(timeout: 10), "Willkommen zurück")
        XCTAssertTrue(waitUntil(timeout: 5) { learn.choiceQuestion() != nil })
        XCTAssertEqual(learn.currentPrompt(), open, "Es geht mit derselben Frage weiter")
        app.terminate()
    }

    /// While the answer field has the focus, esc still means "Beenden" and ⌥↩ still means
    /// "Weiss ich nicht?" (the field editor would swallow esc and type a line break for ⌥↩).
    @MainActor
    func testEscapeAndOptionReturnWhileTyping() throws {
        let list = try UserList.load()
        let app = XCUIApplication.wortschatz("--sample-library", "fresh")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let learn = LearnDriver(app: app, list: list)

        openSetAndLearn(app)
        XCTAssertTrue(app.element("learn-prompt").waitForExistence(timeout: 10))
        learn.playChoices()
        XCTAssertTrue(learn.isAtCheckpoint)
        app.pressReturn()  // Weiter zu Runde 2: written questions
        let answer = app.element("learn-answer")
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "Runde 2 fragt schriftlich")
        Thread.sleep(forTimeInterval: 0.5)

        // esc in the focused field leaves Learn.
        app.typeText("la")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.text(startingWith: "52 Begriffe").waitForExistence(timeout: 5), "esc im Antwortfeld führt zum Lernset")
        XCTAssertFalse(answer.exists)

        // Back to the same written question; ⌥↩ in the field gives up on it.
        Thread.sleep(forTimeInterval: 0.5)
        app.pressReturn()  // Weiterlernen
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "Weiterlernen zeigt die schriftliche Frage wieder")
        XCTAssertTrue(waitUntil(timeout: 5) { learn.primary?.hasPrefix("Antworten") == true })
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(
            waitUntil(timeout: 5) { learn.primary?.hasPrefix("Antworten") == false },
            "⌥↩ im Antwortfeld zählt als «Weiss ich nicht»: \(learn.primary ?? "kein Knopf")")
        XCTAssertFalse(textValue(answer).contains("\n"), "⌥↩ tippt keinen Zeilenumbruch")
        XCTAssertFalse(app.text(containing: "Gib zuerst eine Antwort ein").exists)
        app.terminate()
    }

    // MARK: - Special characters

    /// Schreiben: after a click on a special character the typing goes on in the answer field,
    /// right behind the inserted character.
    @MainActor
    func testTypingContinuesAfterASpecialCharacterInWrite() throws {
        let app = XCUIApplication.wortschatz("--sample-library", "fresh")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.8)
        app.pressReturn()
        XCTAssertTrue(app.text(startingWith: "52 Begriffe").waitForExistence(timeout: 10), "↩ öffnet das Lernset")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("l", modifierFlags: [.command, .shift])  // Schreiben
        let answer = app.element("write-answer")
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "⇧⌘L öffnet Schreiben")
        Thread.sleep(forTimeInterval: 0.5)
        try typeAroundASpecialCharacter(app, field: answer)
        app.terminate()
    }

    /// Lernen (written round): the same.
    @MainActor
    func testTypingContinuesAfterASpecialCharacterInLearn() throws {
        let list = try UserList.load()
        let app = XCUIApplication.wortschatz("--sample-library", "fresh")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let learn = LearnDriver(app: app, list: list)
        openSetAndLearn(app)
        XCTAssertTrue(app.element("learn-prompt").waitForExistence(timeout: 10))
        learn.playChoices()
        XCTAssertTrue(learn.isAtCheckpoint)
        app.pressReturn()  // Weiter zu Runde 2: written questions
        let answer = app.element("learn-answer")
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "Runde 2 fragt schriftlich")
        Thread.sleep(forTimeInterval: 0.5)
        try typeAroundASpecialCharacter(app, field: answer)
        app.terminate()
    }

    // MARK: - Helpers

    /// Types "a", clicks the first special character, types "b" without touching the field:
    /// the field holds "a", the character and "b", and the next key still goes into it.
    @MainActor
    private func typeAroundASpecialCharacter(_ app: XCUIApplication, field: XCUIElement) throws {
        app.typeText("a")
        XCTAssertTrue(waitUntil(timeout: 3) { textValue(field) == "a" }, "Das Feld hat die Tasten: «\(textValue(field))»")
        let key = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " einfügen")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 3), "Es gibt Sonderzeichen-Knöpfe")
        let character = String(key.label.dropLast(" einfügen".count))
        key.click()
        Thread.sleep(forTimeInterval: 0.4)
        app.typeText("b")
        XCTAssertTrue(
            waitUntil(timeout: 3) { textValue(field) == "a\(character)b" },
            "Nach dem Klick auf «\(character)» geht das Tippen im Feld weiter: «\(textValue(field))»")
    }

    /// Overview → Return opens the set (no session yet) → Return starts Lernen.
    @MainActor
    private func openSetAndLearn(_ app: XCUIApplication) {
        // Let the window settle its focus (the sidebar list) first.
        Thread.sleep(forTimeInterval: 0.8)
        app.pressReturn()
        XCTAssertTrue(app.text(startingWith: "52 Begriffe").waitForExistence(timeout: 10), "↩ öffnet das Lernset")
        Thread.sleep(forTimeInterval: 0.5)
        app.pressReturn()
    }
}
