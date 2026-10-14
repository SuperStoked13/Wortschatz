import SwiftUI
import WortschatzCore

// Menu bar (spec §4.1): Ablage, Lernset, Lernen, plus the standard Edit, View, Window and Help
// menus. Commands act on the focused main window: its `AppModel` arrives as a focused scene
// value (`.focusedSceneValue(model)` on the root view), so the Lernset menu is disabled while,
// for example, the Settings window is in front. The Lernen menu talks to the running study
// screen through `StudyCommandContext`.

// MARK: - Study commands (published by the Learn, Write, Flashcards and Exam screens)

/// A command of the "Lernen" menu.
enum StudyCommand: Hashable, CaseIterable, Sendable {
    /// "Ich hatte recht" ⌘↩.
    case override
    /// "Weiss ich nicht" ⌥↩.
    case dontKnow
    /// "Optionen…" ⌘K.
    case options
    /// "Vorlesen" ⌘R.
    case speak
    /// "Markieren" / "Markierung entfernen" ⌘D.
    case toggleStar
    /// "Neu starten" ⇧⌘R.
    case restart
    /// "Beenden" esc.
    case exit
}

/// What the Learn and Write screens publish for the Lernen menu:
///
/// ```swift
/// .focusedSceneValue(\.studyCommands, StudyCommandContext(
///     owner: ObjectIdentifier(controller),
///     mode: .learn,
///     enabled: flow.enabledCommands,          // e.g. [.dontKnow, .speak, .toggleStar, .options, .restart, .exit]
///     isStarred: card.starred
/// ) { command in send(.command(command)) })
/// ```
///
/// Equal contexts (same screen, mode, commands and star) count as unchanged, so the menu bar is
/// not rebuilt on every keystroke in the answer field; `owner` keeps a new screen's context
/// from being mistaken for the last one's.
///
/// Menu key equivalents are handled before the window's own shortcuts only when no control in
/// the window binds the same key, so a screen may bind ⌥↩ / ⌘↩ on its buttons too; both routes
/// should end in the same reducer event. Leave `.exit` out of `enabled` while a popover or
/// alert of the screen is open, so esc closes that first.
struct StudyCommandContext: Equatable {
    /// The screen's controller.
    var owner: ObjectIdentifier
    var mode: StudyMode
    var enabled: Set<StudyCommand>
    var isStarred: Bool
    var perform: (StudyCommand) -> Void

    init(
        owner: ObjectIdentifier, mode: StudyMode, enabled: Set<StudyCommand>, isStarred: Bool = false,
        perform: @escaping (StudyCommand) -> Void
    ) {
        self.owner = owner
        self.mode = mode
        self.enabled = enabled
        self.isStarred = isStarred
        self.perform = perform
    }

    static func == (a: Self, b: Self) -> Bool {
        a.owner == b.owner && a.mode == b.mode && a.enabled == b.enabled && a.isStarred == b.isStarred
    }

    func isEnabled(_ command: StudyCommand) -> Bool {
        enabled.contains(command)
    }
}

extension FocusedValues {
    /// The running study screen's commands (nil outside Learn, Write, Flashcards and Exam).
    @Entry var studyCommands: StudyCommandContext?
}

// MARK: - Commands

struct AppCommands: Commands {
    /// The app's model, for commands that also work without a focused main window
    /// (Neues Lernset, Backup …).
    let model: AppModel

    @FocusedValue(AppModel.self) private var focusedModel
    @FocusedValue(\.studyCommands) private var study
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Lernset") { inMainWindow { $0.openEditor(.new) } }
                .keyboardShortcut("n")
            Button("Liste importieren…") { inMainWindow { $0.openEditor(.importList) } }
                .keyboardShortcut("o")
        }

        CommandGroup(replacing: .importExport) {
            Button("Backup exportieren…") { inMainWindow { $0.exportBackup() } }
            Button("Backup importieren…") { inMainWindow { $0.importBackup() } }
        }

        CommandMenu("Lernset") {
            // Nothing acts on the set behind an open sheet (the editor has its own ⌘E/⌘⌫ meaning).
            let available = focusedModel?.isPresentingSheet == false
            let setID = available ? focusedModel?.currentSetID : nil
            let summary = setID.flatMap { focusedModel?.library.summary(for: $0) }
            let hasCards = summary.map { !$0.isEmpty } ?? false

            Button(summary?.learn != nil ? "Weiterlernen" : "Lernen") {
                if let setID { focusedModel?.continueLearn(setID: setID) }
            }
            .keyboardShortcut("l")
            .disabled(!hasCards)

            Button(summary?.write != nil ? "Schreiben fortsetzen" : "Schreiben") {
                if let setID { focusedModel?.continueWrite(setID: setID) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!hasCards)

            Button("Karteikarten") {
                if let setID { focusedModel?.continueFlashcards(setID: setID) }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!hasCards)

            Button("Prüfung") {
                if let setID { focusedModel?.startExam(setID: setID) }
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(!hasCards)

            Divider()

            Button("Bearbeiten") {
                if let setID { focusedModel?.openEditor(.edit(setID: setID)) }
            }
            .keyboardShortcut("e")
            .disabled(summary == nil)

            Button("Duplizieren") {
                if let setID { focusedModel?.duplicateSet(setID) }
            }
            .disabled(summary == nil)

            Button("Als Text exportieren…") {
                if let setID { focusedModel?.exportText(setID) }
            }
            .disabled(!hasCards)

            Divider()

            Button("Fortschritt zurücksetzen…") {
                if let setID { focusedModel?.confirmResetProgress(setID) }
            }
            .disabled(!(summary?.canReset ?? false))

            Button("Löschen") {
                if let setID { focusedModel?.deleteCommand(setID: setID) }
            }
            .keyboardShortcut(.delete)
            .disabled(summary == nil)
        }

        CommandMenu("Lernen") {
            studyButton(.override, "Ich hatte recht", KeyboardShortcut(.return, modifiers: .command))
            studyButton(.dontKnow, "Weiss ich nicht", KeyboardShortcut(.return, modifiers: .option))
            Divider()
            studyButton(.options, "Optionen…", KeyboardShortcut("k"))
            studyButton(.speak, "Vorlesen", KeyboardShortcut("r"))
            studyButton(.toggleStar, study?.isStarred == true ? "Markierung entfernen" : "Markieren", KeyboardShortcut("d"))
            Divider()
            studyButton(.restart, "Neu starten", KeyboardShortcut("r", modifiers: [.command, .shift]))
            studyButton(.exit, "Beenden", KeyboardShortcut(.escape, modifiers: []))
        }

        SidebarCommands()
    }

    private func studyButton(_ command: StudyCommand, _ title: String, _ shortcut: KeyboardShortcut) -> some View {
        Button(title) { study?.perform(command) }
            .keyboardShortcut(shortcut)
            .disabled(!(study?.isEnabled(command) ?? false) || focusedModel?.isPresentingSheet == true)
    }

    /// Runs `action` on the model with the main window on screen (it is reopened after it was
    /// closed, so sheets and panels have a window to attach to).
    private func inMainWindow(_ action: (AppModel) -> Void) {
        if !model.isMainWindowVisible {
            openWindow(id: WortschatzApp.mainWindowID)
        }
        action(model)
    }
}
