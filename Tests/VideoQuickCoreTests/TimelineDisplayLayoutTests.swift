import XCTest
@testable import VideoQuickCore

final class TimelineDisplayLayoutTests: XCTestCase {
    func testZoomScalesContentAndRetainsExactSourceMappingBetweenFixedHandles() throws {
        let clip = ClipEdit(start: 0, duration: 12)
        let layout = TimelineDisplayLayout(sourceDuration: 12, viewportWidth: 900, clips: [clip], frameDuration: 0.04, zoom: 2)
        XCTAssertEqual(layout.contentWidth, 1800, accuracy: 0.001)
        let item = try XCTUnwrap(layout.item(for: clip.id))
        XCTAssertEqual(item.inset, 13)
        XCTAssertEqual(layout.x(at: 3, preferredClip: clip.id), 456.5, accuracy: 0.001)
        XCTAssertEqual(layout.sourceTime(atX: 456.5, trimming: true), 3, accuracy: 0.00001)
        XCTAssertEqual(layout.x(at: 12, preferredClip: clip.id), 1787, accuracy: 0.001)
    }
    func testLongTimelineZoomIsBoundedAndInvalidFactorsStayFinite() {
        let clip = ClipEdit(start: 0, duration: 10800)
        for zoom in [Double.nan, .infinity, -1, 0, 1, 256, 1_000_000] {
            let layout = TimelineDisplayLayout(sourceDuration: 10800, viewportWidth: 900, clips: [clip], frameDuration: 1.0 / 30, zoom: zoom)
            XCTAssertTrue(layout.contentWidth.isFinite)
            XCTAssertGreaterThanOrEqual(layout.contentWidth, 900)
            XCTAssertLessThanOrEqual(layout.contentWidth, 230400)
            XCTAssertEqual(layout.sourceTime(atX: layout.x(at: 5400), trimming: true), 5400, accuracy: 0.0001)
        }
    }
    func testOneFrameGetsRoomForBothHandlesAndPreviewWithoutUnnecessaryOverflow() throws {
        let short = ClipEdit(start: 0, duration: 1.0 / 30), long = ClipEdit(start: 1.0 / 30, duration: 100 - 1.0 / 30)
        let layout = TimelineDisplayLayout(sourceDuration: 100, viewportWidth: 900, clips: [short, long], frameDuration: 1.0 / 30)
        let item = try XCTUnwrap(layout.item(for: short.id))
        XCTAssertEqual(item.width, 22, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(item.innerEnd - item.innerStart, 11)
        XCTAssertEqual(layout.contentWidth, 900, accuracy: 0.001)
    }
    func testHundredTinyClipsOverflowAndBothMapsAgreeInsideEveryClip() throws {
        let clips = (0..<100).map { ClipEdit(start: Double($0) / 30, duration: 1.0 / 30) }
        let layout = TimelineDisplayLayout(sourceDuration: 100.0 / 30, viewportWidth: 900, clips: clips, frameDuration: 1.0 / 30)
        XCTAssertEqual(layout.items.count, 100, "Frame rounding must not invent tiny inactive gaps")
        XCTAssertEqual(layout.contentWidth, 2200, accuracy: 0.001)
        for clip in clips {
            let item = try XCTUnwrap(layout.item(for: clip.id))
            XCTAssertGreaterThanOrEqual(item.width, 22)
            let source = clip.start + clip.duration / 2
            XCTAssertEqual(layout.sourceTime(atX: layout.x(at: source, preferredClip: clip.id), trimming: true), source, accuracy: 0.000001)
        }
    }
    func testSnappedEdgesMeetPlayheadAtTheirInnerSideAndGapsStayMapped() throws {
        let clip = ClipEdit(start: 2, duration: 4), next = ClipEdit(start: 9, duration: 1)
        let layout = TimelineDisplayLayout(sourceDuration: 10, viewportWidth: 900, clips: [clip, next], frameDuration: 0.04)
        let item = try XCTUnwrap(layout.item(for: clip.id))
        XCTAssertEqual(layout.x(at: clip.start, preferredClip: clip.id), item.innerStart)
        XCTAssertEqual(layout.x(at: clip.end, preferredClip: clip.id), item.innerEnd)
        XCTAssertEqual(layout.x(at: clip.end + 0.01, preferredClip: clip.id), item.innerEnd, "A paused subframe position must align with the frame-snapped inner edge")
        let gapX = layout.x(at: 7.5)
        XCTAssertEqual(layout.sourceTime(atX: gapX, trimming: true), 7.5, accuracy: 0.00001)
        XCTAssertEqual(layout.snappedTrimTime(4.02, playhead: 4, clip: clip.id, limits: 2...5.96), 4)
        XCTAssertEqual(layout.snappedTrimTime(4.02, playhead: 4, clip: clip.id, limits: 4.01...5.96), 4.02)
    }
}
