import Foundation
import Testing
import WortschatzCore

/// An option of a set set back to the standard is no longer the set's own (GitHub issue #8,
/// `LibraryStore.updateOwnStudyOptions`). Before, «Vorlesen» on and off again kept
/// `{audio: false}`, and the set stayed silent once the standard was switched on. Same cases as
/// Windows' OptionsChangedElsewhereTests.
@Suite("A set's own options")
struct OwnStudyOptionsTests {
    static func storeWithSet() throws -> (LibraryStore, String) {
        let store = LibraryStore(backend: MemoryBackend())
        let set = try store.createSet(title: "Wörter")
        return (store, set.id)
    }

    @Test func anOptionSetBackToTheStandardIsNoLongerTheSetsOwn() throws {
        let (store, id) = try Self.storeWithSet()
        try store.updateOwnStudyOptions(id, StudyOptionsPatch(audio: true))
        #expect(store.getSet(id)?.studyOptions == StudyOptionsPatch(audio: true))
        try store.updateOwnStudyOptions(id, StudyOptionsPatch(audio: false))
        #expect(store.getSet(id)?.studyOptions == nil)
        // The standard switched on later: the set follows it.
        try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(audio: true)))
        #expect(store.getStudyOptions(id).audio)
    }

    @Test func nestedOptionsSetBackToTheStandardGoToo() throws {
        let (store, id) = try Self.storeWithSet()
        try store.updateOwnStudyOptions(
            id, StudyOptionsPatch(tolerance: TolerancePatch(typos: true), learn: LearnOptionsPatch(roundSize: 12)))
        try store.updateOwnStudyOptions(id, StudyOptionsPatch(learn: LearnOptionsPatch(mc: false)))
        #expect(
            store.getSet(id)?.studyOptions
                == StudyOptionsPatch(tolerance: TolerancePatch(typos: true), learn: LearnOptionsPatch(roundSize: 12, mc: false)))
        try store.updateOwnStudyOptions(
            id, StudyOptionsPatch(tolerance: TolerancePatch(typos: false), learn: LearnOptionsPatch(roundSize: 7)))
        #expect(store.getSet(id)?.studyOptions == StudyOptionsPatch(learn: LearnOptionsPatch(mc: false)))
        try store.updateOwnStudyOptions(id, StudyOptionsPatch(learn: LearnOptionsPatch(mc: true)))
        #expect(store.getSet(id)?.studyOptions == nil)
    }

    @Test func theValuesInEffectStayAndOtherOwnOptionsAreLeft() throws {
        let (store, id) = try Self.storeWithSet()
        try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(answerWith: .both)))
        // Stored the old way (the web app's mergeStudy, kept for parity): its own «Antworten auf»
        // equals the standard.
        try store.updateStudyOptions(id, StudyOptionsPatch(answerWith: .both, shuffle: false))
        var before = store.getStudyOptions(id)
        try store.updateOwnStudyOptions(id, StudyOptionsPatch(audio: true))
        #expect(store.getSet(id)?.studyOptions == StudyOptionsPatch(answerWith: .both, shuffle: false, audio: true))
        before.audio = true
        #expect(store.getStudyOptions(id) == before)
        // Set back to the standard: only what was set goes.
        try store.updateOwnStudyOptions(id, StudyOptionsPatch(answerWith: .both, shuffle: true))
        #expect(store.getSet(id)?.studyOptions == StudyOptionsPatch(audio: true))
    }
}
