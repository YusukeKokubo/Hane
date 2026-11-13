import AppKit
import Testing
@testable import Hane

@Suite struct WindowDraggingTests {
    private let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let external = NSRect(x: 1440, y: 0, width: 3440, height: 1440)

    @Test func leavesAWindowWhoseTopIsVisible() {
        let onExternal = NSRect(x: 2000, y: 300, width: 1100, height: 750)
        #expect(StillWindow.frame(onExternal, keptOn: [main, external]) == nil)
        let halfOut = NSRect(x: 1000, y: -400, width: 1100, height: 750)
        #expect(StillWindow.frame(halfOut, keptOn: [main]) == nil, "上端が見えていれば、はみ出していても動かさない")
    }

    @Test func bringsBackAWindowLeftOnARemovedScreen() {
        let onExternal = NSRect(x: 2000, y: 300, width: 1100, height: 750)
        let moved = StillWindow.frame(onExternal, keptOn: [main])
        #expect(moved == NSRect(x: 340, y: 150, width: 1100, height: 750))
    }

    @Test func shrinksAWindowLargerThanTheRemainingScreen() {
        let wide = NSRect(x: 1500, y: 100, width: 3000, height: 1300)
        #expect(StillWindow.frame(wide, keptOn: [main]) == main)
    }
}
