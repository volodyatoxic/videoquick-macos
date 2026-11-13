import XCTest
@testable import VideoQuickCore

final class TimelineStripGeometryTests: XCTestCase {
    func testTrimMagnetUsesEightPointsAndRespectsLegalClipBounds() {
        let geometry = TimelineStripGeometry(sourceDuration: 10, width: 1000)
        XCTAssertEqual(geometry.snappedTrimTime(5.075, playhead: 5, limits: 0...9), 5)
        XCTAssertEqual(geometry.snappedTrimTime(5.081, playhead: 5, limits: 0...9), 5.081)
        XCTAssertEqual(geometry.snappedTrimTime(5.075, playhead: 5, limits: 5.05...9), 5.075)
        XCTAssertEqual(geometry.snappedTrimTime(12, playhead: 5, limits: 0...9), 9)
        let long = TimelineStripGeometry(sourceDuration: 10_800, width: 900)
        XCTAssertEqual(long.snappedTrimTime(3680, playhead: 3600, limits: 0...10_799), 3600)
    }
    func testPlayheadKeepsMovingUntilRealEndInsideTrimHandles() {
        let geometry = TimelineStripGeometry(sourceDuration: 10, width: 1000)
        let first = ClipEdit(start: 2, duration: 4), next = ClipEdit(start: 6, duration: 4)
        XCTAssertEqual(geometry.playheadX(sourceTime: 2, clip: first), 211)
        XCTAssertEqual(geometry.playheadX(sourceTime: 6, clip: first), 589)
        XCTAssertEqual(geometry.playheadX(sourceTime: 5.9, clip: first), 579.55, accuracy: 0.00001)
        XCTAssertGreaterThan(geometry.playheadX(sourceTime: 5.99, clip: first), geometry.playheadX(sourceTime: 5.95, clip: first))
        XCTAssertEqual(geometry.playheadX(sourceTime: 6, clip: next), 611)
        for source in [2.0, 2.02, 3, 4, 5.98, 6] {
            let x = geometry.playheadX(sourceTime: source, clip: first)
            XCTAssertEqual(geometry.sourceTime(atX: x, clips: [first, next]), source, accuracy: 0.00001)
        }
    }
    func testInactiveGapsUseSourcePositionAndTinyClipsRemainFinite() {
        let geometry = TimelineStripGeometry(sourceDuration: 120, width: 900)
        let a = ClipEdit(start: 10, duration: 20), b = ClipEdit(start: 90, duration: 0.04)
        XCTAssertEqual(geometry.sourceTime(atX: 450, clips: [a, b]), 60)
        XCTAssertTrue(geometry.playheadX(sourceTime: 90.02, clip: b).isFinite)
        XCTAssertTrue(geometry.sourceTime(atX: geometry.playheadX(sourceTime: 90.02, clip: b), clips: [a, b]).isFinite)
    }
}
