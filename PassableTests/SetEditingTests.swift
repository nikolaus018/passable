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

        // An edit in the editor becomes the set's transition.
        editor.choosePreset(.dropSwap)
        try await wait("the edit to reach the set") { set.mix?.transitions.first?.edit.preset == .dropSwap }
        XCTAssertTrue(set.isEdited(from: 0))
        XCTAssertTrue(editor.isEdited)
        XCTAssertEqual(set.mix!.transitions[0].edit.lanes, editor.lanes)

        // Auto drops the edit.
        editor.autoArrange()
        try await wait("the automatic transition") { set.mix?.transitions.first?.isEdited == false }
        XCTAssertEqual(set.mix!.transitions[0].edit.preset, set.mix!.transitions[0].plan.preset)
        try await wait("the editor to reopen") { !editor.isEdited }
    }
}
