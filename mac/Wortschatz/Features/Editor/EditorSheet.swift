import SwiftUI
import UniformTypeIdentifiers
import WortschatzCore
import WortschatzImport

// The set editor sheet (spec §4.4 "Editor", §4.3 key map).
//
// Contract with the app shell:
// - `init(request: EditorRequest)`: `.new` (empty editor), `.importList` (new set, the file
//   chooser opens right away) or `.edit(setID:)`.
// - Presented by `ContentView` as `.sheet(item: $model.editorRequest)`.
// - Saving goes through `model.store` (`createSet` / `updateSet`, card ids preserved), then
//   `model.editorDidSave(setID:)`; cancelling through `model.closeEditor()`, after asking when
//   there are unsaved changes.
// - Keys: ⌘↩ / ⌘S save, esc cancels (or stops a running import first). Return moves through
//   the fields: title → description → import box / first card, term → definition → next card.

/// The editor sheet for a new or an existing set.
struct EditorSheet: View {
    let request: EditorRequest

    @Environment(AppModel.self) private var model
    @State private var editor: SetEditorModel?

    init(request: EditorRequest) {
        self.request = request
    }

    var body: some View {
        ZStack {
            if let editor {
                SetEditorView(editor: editor, opensFileChooser: request.kind == .importList)
            }
        }
        .frame(minWidth: 900, idealWidth: 1000, maxWidth: .infinity, minHeight: 680, idealHeight: 800, maxHeight: .infinity)
        .onAppear {
            guard editor == nil else { return }
            editor = SetEditorModel(app: model, request: request)
        }
    }
}

/// The editor's content around a `SetEditorModel`: meta fields, import panel, card rows and
/// the floating save bar, plus focus, scrolling, drops, the file chooser, prompts and toasts.
/// Also used by the snapshot harness with a prepared model.
struct SetEditorView: View {
    let editor: SetEditorModel
    var opensFileChooser = false

    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: SetEditorField?
    @State private var isSheetDropTargeted = false
    @State private var isTextDropTargeted = false

    var body: some View {
        @Bindable var importPanel = editor.importPanel
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    SetEditorHeader(editor: editor)
                        .padding(.bottom, Spacing.xl)
                    SetEditorMetaSection(editor: editor, focus: $focus)
                        .padding(.bottom, Spacing.l)
                    ImportPanelView(
                        model: editor.importPanel, isTextDropTargeted: $isTextDropTargeted, focus: $focus,
                        onShowCards: { editor.scroll(to: .cards, anchor: .top) }, onClearText: editor.clearImportText
                    )
                    .id(SetEditorModel.ScrollTarget.importPanel)
                    .padding(.bottom, Spacing.xxl)
                    SetEditorCardsHeader(editor: editor)
                        .id(SetEditorModel.ScrollTarget.cards)
                        .padding(.bottom, Spacing.xs)
                    Section {
                        ForEach(Array(editor.rows.enumerated()), id: \.element.id) { index, row in
                            SetEditorRowView(
                                row: row, number: index + 1, termLang: editor.termLang, defLang: editor.defLang, editor: editor,
                                focus: $focus
                            )
                            .padding(.bottom, 6)
                            .transition(.opacity)
                        }
                    } header: {
                        SetEditorColumnHeader(
                            termLang: editor.termIsAuto ? nil : editor.termLang, defLang: editor.defIsAuto ? nil : editor.defLang)
                    }
                    SetEditorCardsFooter(editor: editor)
                        .padding(.top, Spacing.xxs)
                }
                .frame(maxWidth: SetEditorLayout.contentWidth)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.l)
                .frame(maxWidth: .infinity)
            }
            .safeAreaBar(edge: .bottom) {
                SetEditorActionBar(editor: editor)
            }
            .onChange(of: editor.focusRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in await moveFocus(to: request.field, proxy: proxy, token: request.token) }
            }
            .onChange(of: editor.scrollRequest) { _, request in
                if let request { scroll(to: request, proxy: proxy, animated: true) }
            }
            .onAppear {
                // A model prepared before the sheet appeared (e.g. scrolled to its cards).
                if let request = editor.scrollRequest {
                    Task { @MainActor in scroll(to: request, proxy: proxy, animated: false) }
                }
            }
            .onChange(of: editor.importPanel.revealToken) {
                Task { @MainActor in
                    withAnimation(scrollAnimation) {
                        proxy.scrollTo(SetEditorModel.ScrollTarget.detection, anchor: .top)
                    }
                }
            }
        }
        .overlay {
            if isSheetDropTargeted || isTextDropTargeted {
                SetEditorDropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: isSheetDropTargeted || isTextDropTargeted)
        .onDrop(of: PasteboardImage.acceptedTypes, isTargeted: $isSheetDropTargeted) { providers in
            editor.importPanel.importProviders(providers)
        }
        .onPasteCommand(of: PasteboardImage.acceptedTypes) { providers in
            // ⌘V of an image while no text field takes it (text fields paste text themselves).
            editor.importPanel.importProviders(providers)
        }
        .fileImporter(
            isPresented: $importPanel.isChoosingFiles, allowedContentTypes: ImportFileType.supportedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            editor.importPanel.filesChosen(result)
        }
        .alert(
            editor.prompt?.title ?? "",
            isPresented: Binding(
                get: { editor.prompt != nil },
                set: { shown in if !shown { editor.prompt = nil } }),
            presenting: editor.prompt
        ) { prompt in
            SetEditorPromptButtons(prompt: prompt, editor: editor)
        } message: { prompt in
            Text(prompt.message)
        }
        .toastOverlay(editor.toasts)
        .background {
            // ⌘S saves too (⌘↩ is bound on the save button).
            Button("Sichern", action: editor.save)
                .keyboardShortcut("s")
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            editor.undoManager = undoManager
            if opensFileChooser {
                editor.importPanel.isChoosingFiles = true
            } else {
                // The sheet is still sliding in: retried until the title field takes it.
                Task { @MainActor in await moveFocus(to: .title, proxy: nil, token: nil) }
            }
        }
        .onDisappear { editor.finish() }
        .onChange(of: undoManager) { _, manager in editor.undoManager = manager }
        .onChange(of: app.revision) { editor.storeDidChange() }
    }

    private var scrollAnimation: Animation {
        Motion.animation(Motion.gentle, reduceMotion: reduceMotion)
    }

    private func scroll(to request: SetEditorModel.ScrollRequest, proxy: ScrollViewProxy, animated: Bool) {
        let id: AnyHashable =
            switch request.target {
            case let .row(rowID): rowID
            default: request.target
            }
        withAnimation(animated ? scrollAnimation : nil) { proxy.scrollTo(id, anchor: request.anchor) }
    }

    /// Moves the keyboard focus. A card row far down the lazy list has no text field until it
    /// is scrolled into view, so the row is scrolled to first (without animation, like any
    /// keyboard move) and the focus is set again until the field exists.
    private func moveFocus(to field: SetEditorField, proxy: ScrollViewProxy?, token: Int?) async {
        for attempt in 0..<8 {
            if let token, editor.focusRequest?.token != token { return }
            if let rowID = field.rowID, let proxy { proxy.scrollTo(rowID) }
            await Task.yield()
            focus = field
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 20 : 45))
            if focus == field { return }
        }
    }
}
