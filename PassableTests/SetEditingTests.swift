import XCTest
@testable import Passable

/// The set and the transition editor as one: editing a transition in the
/// editor changes the set, and Auto hands it back.
@MainActor
final class SetEditingTests: XCTestCase {
    private func wait(_ what: String, timeout: TimeInterval = 300, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testEditingATransitionOfTheSet() async throws {
        let a = SeparationTests.fixtures.appendingPathComponent("songA.wav")
        let b = SeparationTests.fixtures.appendingPathComponent("songB.wav")
        guard FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) else {
            throw XCTSkip("Run tools/convert-demucs/make_fixtures.py")
        }
        let set = SetSession(persists: false)
        set.add([a, b])
        try await wait("the mix") { set.mix != nil && set.buildStatus == nil }
        let mix = try XCTUnwrap(set.mix)
        XCTAssertEqual(mix.transitions.count, 1)
        XCTAssertFalse(set.isEdited(from: 0))

        // Holding M mutes the playing song's vocal, and only that; letting
        // go brings it back.
        let vocals = StemKind.laneOrder.firstIndex(of: .vocals)!
        let playing = try XCTUnwrap(set.currentIndex)
        set.holdVocals(solo: false, down: true)
        XCTAssertEqual(set.vocalHold?.track, playing)
        var lanes = set.makeSnapshot().lanes
        XCTAssertFalse(lanes[playing * StemKind.laneOrder.count + vocals].audible)
        XCTAssertEqual(lanes.filter { !$0.audible }.count, 1)
        set.holdVocals(solo: false, down: false)
        lanes = set.makeSnapshot().lanes
        XCTAssertTrue(lanes.allSatisfy(\.audible))

        // The editor shows the transition, on a clock the set can map exactly.
        set.edit(transitionFrom: 0)
        let editor = set.editor
        XCTAssertTrue(editor.hasPair)
        XCTAssertEqual(editor.deckA.url, mix.tracks[0].url)
        XCTAssertEqual(editor.deckB.url, mix.tracks[1].url)
        let t = mix.transitions[0]
        XCTAssertEqual(editor.transitionStart + editor.hostOffset, t.start, accuracy: 1e-6)
        XCTAssertEqual(editor.offsetB + editor.hostOffset, mix.tracks[1].offset, accuracy: 1e-6)
        XCTAssertFalse(editor.isEdited, "opening a transition is not an edit")
        // The editor's rendition of B is the set's: nothing re-rendered.
        XCTAssertTrue(editor.matched?.plan.isSame(as: mix.tracks[1].matched!.plan) ?? false)

        // The playhead is shared.
        set.seek(to: t.start)
        set.editor.syncTransport()
        XCTAssertEqual(editor.transport.seconds, editor.transitionStart, accuracy: 1e-6)

        // An edit in the editor becomes the set's transition (any preset
        // other than the one the planner chose).
        let other: TransitionPreset = editor.preset == .longBlend ? .dropSwap : .longBlend
        editor.choosePreset(other)
        try await wait("the edit to reach the set") { set.mix?.transitions.first?.edit.preset == other }
        XCTAssertTrue(set.isEdited(from: 0))
        XCTAssertTrue(editor.isEdited)
        XCTAssertEqual(set.mix!.transitions[0].edit.lanes, editor.lanes)
        // A chosen preset is still written by the set, from the audio: the
        // editor shows what the set built.
        XCTAssertFalse(set.mix!.transitions[0].edit.byHand)
        XCTAssertFalse(editor.byHand)
        XCTAssertEqual(set.mix!.transitions[0].plan.preset, other)

        // Drawing on a lane takes the automation over: it plays as drawn.
        let lane = editor.lanes[0]
        editor.updateLane(lane.id) { $0[.volume].insert(AutomationPoint(time: editor.transitionStart + 1, value: 0.3)) }
        XCTAssertTrue(editor.byHand)
        try await wait("the drawn lanes to reach the set") { set.mix?.transitions.first?.edit.byHand == true }
        XCTAssertEqual(set.mix!.transitions[0].edit.lanes.map(\.envelopes), editor.lanes.map(\.envelopes))
        XCTAssertTrue(editor.lanes[0][.volume].points.contains { $0.value == 0.3 })
        // Muting a lane isn't drawing; picking a length hands the writing back.
        editor.chooseBars(editor.transitionBars == 8 ? 16 : 8)
        XCTAssertFalse(editor.byHand)
        try await wait("the set to write it again") { set.mix?.transitions.first?.edit.byHand == false }
        XCTAssertEqual(set.mix!.transitions[0].edit.bars, editor.transitionBars)
        try await wait("the editor to show the set's lanes") { set.mix!.transitions[0].edit.lanes == editor.lanes }

        // Every control of the panel, through the calls it makes.
        // Moving the transition: written by the set, where it was put.
        let range = try XCTUnwrap(editor.entryRange)
        let moved = editor.entryBar + 4 <= range.upperBound ? editor.entryBar + 4 : max(range.lowerBound, editor.entryBar - 4)
        editor.entryBar = moved
        try await wait("the move to reach the set") { set.mix?.transitions.first?.edit.entryBar == moved }
        try await wait("the set's lanes at the new spot") { set.mix!.transitions[0].edit.lanes == editor.lanes }
        XCTAssertFalse(set.mix!.transitions[0].edit.byHand)
        XCTAssertEqual(editor.entryBar, moved)
        XCTAssertEqual(editor.transitionStart + editor.hostOffset, set.mix!.transitions[0].start, accuracy: 1e-6)
        // B's cue, and back with undo.
        let cue = editor.cueBar
        editor.cueBar = cue + 1
        try await wait("the cue to reach the set") { set.mix?.transitions.first?.edit.cueBar == cue + 1 }
        try await wait("the set's lanes for the new cue") { set.mix!.transitions[0].edit.lanes == editor.lanes }
        XCTAssertEqual(editor.offsetB + editor.hostOffset, set.mix!.tracks[1].offset, accuracy: 1e-6)
        editor.undo()
        XCTAssertEqual(editor.cueBar, cue)
        try await wait("the undo to reach the set") { set.mix?.transitions.first?.edit.cueBar == cue }
        // B's key: the set renders it, the editor shows that rendition.
        editor.setSemitones(1)
        try await wait("the key to reach the set") { set.mix?.transitions.first?.edit.semitones == 1 }
        try await wait("the shifted rendition") { editor.matched?.plan.semitones == 1 }
        XCTAssertFalse(editor.byHand)
        editor.setSemitones(0)
        try await wait("the key to go back") { set.mix?.transitions.first?.edit.semitones == 0 && editor.matched?.plan.semitones == 0 }
        try await wait("the set's lanes again") { set.mix!.transitions[0].edit.lanes == editor.lanes }
        // Apply changes nothing the set isn't already playing.
        editor.applyPreset()
        XCTAssertEqual(set.mix!.transitions[0].edit.lanes, editor.lanes)
        XCTAssertFalse(editor.byHand)
        // Clear is by hand: nothing automated, played as that.
        editor.clearAutomation()
        XCTAssertTrue(editor.byHand)
        try await wait("the cleared lanes to reach the set") {
            set.mix?.transitions.first.map { $0.edit.byHand && $0.edit.lanes.allSatisfy { $0.envelopes.allSatisfy(\.isEmpty) } } ?? false
        }
        // Back to automatic, then kept exactly as it is.
        editor.autoArrange()
        try await wait("the automatic transition again") { set.mix?.transitions.first?.isEdited == false && !editor.isEdited }
        let automatic = editor.lanes.map(\.envelopes)
        XCTAssertFalse(automatic.allSatisfy { $0.allSatisfy(\.isEmpty) })
        editor.keepAsEdited()
        XCTAssertTrue(editor.byHand)
        try await wait("the kept transition") { set.mix?.transitions.first?.edit.byHand == true }
        XCTAssertEqual(set.mix!.transitions[0].edit.lanes.map(\.envelopes), automatic)
        // Left as a chosen preset for what follows.
        editor.choosePreset(other == .longBlend ? .dropSwap : .longBlend)
        try await wait("a chosen preset again") { set.mix?.transitions.first?.edit.byHand == false }

        // Auto drops the edit.
        editor.autoArrange()
        try await wait("the automatic transition") { set.mix?.transitions.first?.isEdited == false }
        XCTAssertEqual(set.mix!.transitions[0].edit.preset, set.mix!.transitions[0].plan.preset)
        try await wait("the editor to reopen") { !editor.isEdited }
    }
}
