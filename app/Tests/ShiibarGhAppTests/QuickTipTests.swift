// The icon buttons' tooltip (QuickTip): it shows after its own short delay,
// not sooner, and goes when the pointer leaves.

import AppKit
import ShiibarGhCore
import XCTest

@MainActor
final class QuickTipTests: XCTestCase {
    func testTheTipShowsAfterItsDelayAndGoesOnCancel() {
        XCTAssertLessThanOrEqual(QuickTip.delay, 0.5)
        XCTAssertGreaterThanOrEqual(QuickTip.delay, 0.3)
        let owner = QuickTip.Owner()
        QuickTip.schedule("Dismiss", owner: owner, appearance: nil)
        XCTAssertFalse(QuickTip.isShown, "not at once")
        let early = expectation(description: "before the delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + QuickTip.delay / 2) {
            XCTAssertFalse(QuickTip.isShown)
            early.fulfill()
        }
        wait(for: [early], timeout: 2)
        let shown = expectation(description: "after the delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + QuickTip.delay) {
            XCTAssertTrue(QuickTip.isShown)
            shown.fulfill()
        }
        wait(for: [shown], timeout: 2)
        QuickTip.cancel(owner: QuickTip.Owner())
        XCTAssertTrue(QuickTip.isShown, "another button's cancel leaves it")
        QuickTip.cancel(owner: owner)
        XCTAssertFalse(QuickTip.isShown)
    }
}
