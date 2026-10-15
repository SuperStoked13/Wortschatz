import AVFoundation
import SwiftUI
import WortschatzCore

/// Allgemein: the appearance (System / Hell / Dunkel, applied to every window), the sound effects,
/// synonyms outside the set (Apple Intelligence) and the voice used to read each language aloud.
struct SettingsGeneralTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var voices = SettingsVoiceCatalog()
    @AppStorage(SoundEffects.defaultsKey) private var soundEffects = true
    @AppStorage(SynonymAssistant.defaultsKey) private var extendedSynonyms = true

    /// The app's read-aloud service: a voice chosen here applies at once to every screen.
    private var speech: SpeechService { model.speech }

    var body: some View {
        let theme = model.settings.theme
        Form {
            Section {
                LabeledContent {
                    SettingsAppearancePicker(selection: Binding(
                        get: { theme },
                        set: { SettingsWriter(model: model).update(SettingsPatch(theme: $0)) }))
                } label: {
                    Text("Erscheinungsbild")
                    // With System, the app follows the Mac, so the environment shows the Mac's look.
                    Text(SettingsCopy.themeHint(theme, systemIsDark: colorScheme == .dark))
                }
            } header: {
                Text("Darstellung")
            }

            Section {
                Toggle(isOn: $soundEffects) {
                    Text("Soundeffekte")
                    Text("Leise Töne für richtige und falsche Antworten, Serien und geschaffte Runden.")
                }
                .onChange(of: soundEffects) { _, on in
                    if on { SoundEffects.shared.play(.correct) }
                }
            } header: {
                Text("Töne")
            }

            Section {
                let unavailable = SynonymAssistant.shared.unavailableReason
                Toggle(isOn: $extendedSynonyms) {
                    Text("Weitere Synonyme erkennen")
                    Text("Lässt auch gleichbedeutende Wörter gelten, die nicht im Lernset stehen – z. B. «ensemble» für «gemeinsam» – und markiert sie als «Synonym – nicht im Set». Läuft mit Apple Intelligence direkt auf deinem Mac.")
                }
                .disabled(unavailable != nil)
                if let unavailable {
                    Label(unavailable, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Antworten")
            }

            Section {
                ForEach(SettingsVoiceCatalog.languages, id: \.self) { lang in
                    SettingsVoiceRow(lang: lang, speech: speech, catalog: voices)
                }
            } header: {
                Text("Stimmen zum Vorlesen")
            } footer: {
                Text("Weitere Stimmen lädst du in den Systemeinstellungen unter Bedienungshilfen › Gesprochene Inhalte › Systemstimme › Stimmen verwalten. Premium- und erweiterte Stimmen klingen am natürlichsten.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            voices.reload(using: speech)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voices.reload(using: speech)
        }
        .onDisappear { speech.stop() }
    }
}

/// One language's voice: "Automatisch (Thomas)" or a chosen installed voice, plus a sample to
/// listen to.
private struct SettingsVoiceRow: View {
    let lang: Lang
    let speech: SpeechService
    let catalog: SettingsVoiceCatalog

    var body: some View {
        let name = Labels.langName(lang)
        let options = catalog.voices[lang] ?? []
        // A chosen voice that is no longer installed shows as automatic (what `SpeechService`
        // falls back to).
        let chosen = speech.preferredVoiceIDs[lang].flatMap { id in options.contains { $0.id == id } ? id : nil }
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                Picker(
                    "Stimme für \(name)",
                    selection: Binding(get: { chosen }, set: { speech.setPreferredVoice($0, for: lang) })
                ) {
                    Text(automaticTitle).tag(String?.none)
                    if !options.isEmpty {
                        Divider()
                        ForEach(options) { voice in
                            Text(voice.displayName).tag(String?.some(voice.id))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(catalog.isLoaded && options.isEmpty)

                Button {
                    speech.speak(SettingsVoiceCatalog.sample(for: lang), lang: lang)
                } label: {
                    Label("Probe hören", systemImage: "speaker.wave.2")
                        .labelStyle(.iconOnly)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .disabled(catalog.isLoaded && options.isEmpty)
                .help("Probe hören")
                .accessibilityLabel("Probe hören auf \(name)")
            }
        } label: {
            Text(name)
        }
    }

    private var automaticTitle: String {
        guard catalog.isLoaded else { return "Automatisch" }
        guard let automatic = catalog.automaticNames[lang] else { return "Keine Stimme installiert" }
        return "Automatisch (\(automatic))"
    }

}

/// The installed voices per language (read when the tab appears and whenever the system's voices
/// change).
@Observable
final class SettingsVoiceCatalog {
    /// The languages with a voice choice, in the order of the language pickers (without «Andere»).
    static let languages: [Lang] = Labels.LANG_ORDER.filter { $0 != .other }

    private(set) var voices: [Lang: [SpeechService.Voice]] = [:]
    /// The name of the voice "Automatisch" picks per language (nil: none installed).
    private(set) var automaticNames: [Lang: String] = [:]
    private(set) var isLoaded = false

    /// Reads the installed voices (`SpeechService.voices(for:)` ranks them, best first).
    func reload(using speech: SpeechService) {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        var voices: [Lang: [SpeechService.Voice]] = [:]
        var automaticNames: [Lang: String] = [:]
        for lang in Self.languages {
            voices[lang] = speech.voices(for: lang)
            if let tag = SpeechService.languageTag(for: lang), let best = SpeechService.bestVoice(for: tag, among: installed) {
                automaticNames[lang] = best.name
            }
        }
        self.voices = voices
        self.automaticNames = automaticNames
        isLoaded = true
    }

    /// A short sentence to listen to a voice with.
    static func sample(for lang: Lang) -> String {
        switch lang {
        case .fr: "Bonjour ! Aujourd'hui, nous apprenons de nouveaux mots."
        case .en: "Hello! Today we're learning some new words."
        case .es: "¡Hola! Hoy aprendemos palabras nuevas."
        case .it: "Ciao! Oggi impariamo parole nuove."
        case .ar: "مرحبًا! اليوم نتعلّم كلمات جديدة."
        case .zh: "你好！今天我们学习新词。"
        default: "Hallo! Heute lernen wir neue Wörter."
        }
    }
}

// MARK: - Appearance picker

/// System / Hell / Dunkel as window thumbnails, like the Appearance setting of System Settings.
struct SettingsAppearancePicker: View {
    @Binding var selection: ThemeSetting

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            ForEach(ThemeSetting.allCases, id: \.self) { theme in
                SettingsAppearanceOption(theme: theme, isSelected: selection == theme) {
                    selection = theme
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Erscheinungsbild")
    }
}

private struct SettingsAppearanceOption: View {
    let theme: ThemeSetting
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs) {
                SettingsAppearanceThumbnail(theme: theme)
                    .frame(width: 72, height: 48)
                    .clipShape(.rect(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.hairline)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                Text(SettingsCopy.themeLabel(theme))
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SettingsCopy.themeLabel(theme))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(SettingsCopy.themeHelp(theme))
    }
}

/// A tiny window on a desktop: light, dark, or both split diagonally (System). Fixed colours, so
/// each thumbnail looks the same in either appearance.
private struct SettingsAppearanceThumbnail: View {
    let theme: ThemeSetting

    var body: some View {
        switch theme {
        case .light:
            WindowSketch(palette: .light)
        case .dark:
            WindowSketch(palette: .dark)
        case .system:
            WindowSketch(palette: .light)
                .overlay {
                    WindowSketch(palette: .dark)
                        .mask { DiagonalHalf() }
                }
        }
    }

    private struct Palette {
        let desktop: [Color]
        let window: Color
        let sidebar: Color
        let line: Color
        let accent: Color

        static let light = Palette(
            desktop: [Color(hex: 0xB9B4F4), Color(hex: 0x8CC6DC)], window: Color(hex: 0xFFFFFF),
            sidebar: Color(hex: 0xECEBF3), line: Color(hex: 0xD3D2DE), accent: Color(hex: 0x5146E5))
        static let dark = Palette(
            desktop: [Color(hex: 0x2E2A6B), Color(hex: 0x173A4D)], window: Color(hex: 0x2B2B30),
            sidebar: Color(hex: 0x1F1F24), line: Color(hex: 0x48484F), accent: Color(hex: 0x7B74FF))
    }

    private struct WindowSketch: View {
        let palette: Palette

        var body: some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: palette.desktop, startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 0) {
                    palette.sidebar
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(palette.accent).frame(width: 20, height: 5)
                        Capsule().fill(palette.line).frame(width: 30, height: 3)
                        Capsule().fill(palette.line).frame(width: 24, height: 3)
                        Capsule().fill(palette.line).frame(width: 28, height: 3)
                    }
                    .padding(6)
                    Spacer(minLength: 0)
                }
                .frame(width: 66, height: 44, alignment: .topLeading)
                .background(palette.window)
                .clipShape(.rect(cornerRadius: 4))
                .offset(x: 12, y: 10)
            }
        }
    }

    /// The lower right part of the thumbnail, cut along a slanted line.
    nonisolated private struct DiagonalHalf: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.maxX * 0.62, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX * 0.38, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}
