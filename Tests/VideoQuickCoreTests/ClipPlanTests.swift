import XCTest
@testable import VideoQuickCore

final class ClipPlanTests: XCTestCase {
    func testSeparateFragmentsRetainSourceOrderAndAdjacentSplitsAreTimingNeutral() throws {
        let plan = EditPlan(clips: [ClipEdit(start: 0, duration: 2), ClipEdit(start: 4, duration: 2), ClipEdit(start: 8, duration: 2)])
        XCTAssertEqual(try plan.retainedRanges(duration: 10), [TimeSpan(start: 0, duration: 2), TimeSpan(start: 4, duration: 2), TimeSpan(start: 8, duration: 2)])
        let splitOnly = EditPlan(clips: [ClipEdit(start: 0, duration: 5), ClipEdit(start: 5, duration: 5)])
        XCTAssertEqual(try splitOnly.retainedRanges(duration: 10), [TimeSpan(start: 0, duration: 10)])
        XCTAssertThrowsError(try EditPlan(clips: []).retainedRanges(duration: 10))
        XCTAssertThrowsError(try EditPlan(clips: [ClipEdit(start: 2, duration: 5), ClipEdit(start: 3, duration: 2)]).retainedRanges(duration: 10))
        XCTAssertThrowsError(try EditPlan(clips: [ClipEdit(start: .nan, duration: 2)]).retainedRanges(duration: 10))
    }
}
