import Foundation
import Testing
@testable import Tic

@Suite("NoteWindowManager placement")
struct NoteWindowManagerTests {
    // Two side-by-side displays in global coordinates: the main one at the origin, a second to its right.
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let second = CGRect(x: 1440, y: 0, width: 2560, height: 1415)

    @Test("a note on the second display counts as visible, not lost")
    func secondDisplayIsVisible() {
        let onSecond = CGRect(x: 2000, y: 300, width: 280, height: 360)
        #expect(NoteWindowManager.isVisible(onSecond, onAnyOf: [main, second]))
        #expect(!NoteWindowManager.isVisible(onSecond, onAnyOf: [main]))   // display unplugged
    }

    @Test("a sliver hanging off every edge is lost; an 80×80 corner is enough")
    func slivers() {
        let sliver = CGRect(x: -250, y: 300, width: 280, height: 360)     // 30pt showing
        #expect(!NoteWindowManager.isVisible(sliver, onAnyOf: [main, second]))
        let corner = CGRect(x: -200, y: -280, width: 280, height: 360)    // exactly 80×80 showing
        #expect(NoteWindowManager.isVisible(corner, onAnyOf: [main, second]))
    }

    @Test("office → home → office: parked on the main display while its monitor is gone, back exactly after")
    func displayRoundTrip() {
        let onSecond = CGRect(x: 2000, y: 300, width: 280, height: 360)
        #expect(NoteWindowManager.placement(for: onSecond, screens: [main, second], main: main) == onSecond)

        let parked = NoteWindowManager.placement(for: onSecond, screens: [main], main: main)   // monitor unplugged
        #expect(NoteWindowManager.isVisible(parked, onAnyOf: [main]))
        #expect(parked.size == onSecond.size)
        #expect(parked.maxX == main.maxX && parked.minY == 300)   // nearest edge, not a pile in the centre

        // The saved frame is never rewritten by parking, so the same input places it back on the monitor.
        #expect(NoteWindowManager.placement(for: onSecond, screens: [main, second], main: main) == onSecond)
    }

    @Test("a note taller than the display keeps its header on screen")
    func tallNote() {
        let tall = CGRect(x: 5000, y: 5000, width: 280, height: 1200)
        let parked = NoteWindowManager.placement(for: tall, screens: [main], main: main)
        #expect(parked.maxY == main.maxY && parked.maxX == main.maxX)
    }
}
