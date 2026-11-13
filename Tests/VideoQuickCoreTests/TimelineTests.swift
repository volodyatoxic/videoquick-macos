import XCTest
@testable import VideoQuickCore

final class TimelineTests: XCTestCase {
    func testSplitSnapsToSourceFrameAndInheritsFraming() throws {
        var timeline = try ClipTimeline(duration: 10, aspect: 16 / 9, frameDuration: 0.04)
        try timeline.setAspect(1)
        try timeline.zoomSelected(factor: 2)
        timeline.panSelected(dx: 0.1, dy: -0.1)
        let original = try XCTUnwrap(timeline.selectedClip)
        try timeline.split(at: 4.019)
        XCTAssertEqual(timeline.clips.count, 2)
        guard timeline.clips.count == 2 else { return }
        XCTAssertEqual(timeline.clips[0].id, original.id)
        XCTAssertNotEqual(timeline.clips[1].id, original.id)
        XCTAssertEqual(timeline.selectedID, timeline.clips[1].id)
        XCTAssertEqual(timeline.clips[0].duration, 4, accuracy: 0.000001)
        XCTAssertEqual(timeline.clips[1].start, 4, accuracy: 0.000001)
        XCTAssertEqual(timeline.clips[1].duration, 6, accuracy: 0.000001)
        XCTAssertEqual(timeline.clips.map(\.crop), [original.crop, original.crop])
        XCTAssertEqual(timeline.duration, 10, accuracy: 0.000001)
    }

    func testTrimDeleteAndMappingRespectSourceGapsAndNeighbors() throws {
        var timeline = try ClipTimeline(duration: 12, aspect: 2, frameDuration: 0.04)
        try timeline.split(at: 4)
        try timeline.split(at: 8)
        XCTAssertEqual(timeline.clips.count, 3)
        guard timeline.clips.count == 3 else { return }
        let firstID = timeline.clips[0].id, middleID = timeline.clips[1].id, lastID = timeline.clips[2].id
        timeline.select(middleID)
        XCTAssertEqual(timeline.selectedLimits, 4...8)
        try timeline.trimSelected(start: 5.011, end: 7.989)
        XCTAssertEqual(timeline.selectedClip?.start, 5)
        XCTAssertEqual(timeline.selectedClip?.end, 8)
        XCTAssertEqual(timeline.selectedOutputStart, 4)
        XCTAssertThrowsError(try timeline.trimSelected(start: 3.9, end: 8))
        XCTAssertThrowsError(try timeline.trimSelected(start: 5, end: 8.1))
        XCTAssertEqual(timeline.sourceTime(at: 4), 5)
        XCTAssertEqual(timeline.sourceTime(at: 6), 7)
        try timeline.deleteSelected()
        XCTAssertEqual(timeline.clips.map(\.id), [firstID, lastID])
        XCTAssertEqual(timeline.duration, 8)
        XCTAssertEqual(timeline.outputStart(of: lastID), 4)
        XCTAssertEqual(timeline.sourceTime(at: 3), 3)
        XCTAssertEqual(timeline.sourceTime(at: 4), 8)
        XCTAssertEqual(timeline.sourceTime(at: 7), 11)
        XCTAssertEqual(timeline.sourceTime(at: -1), 0)
        XCTAssertEqual(timeline.sourceTime(at: 100), 12)
        timeline.select(firstID)
        XCTAssertEqual(timeline.selectedLimits, 0...8)
        try timeline.trimSelected(start: 1, end: 6)
        XCTAssertEqual(timeline.duration, 9)
        XCTAssertEqual(timeline.sourceTime(at: 0), 1)
        XCTAssertEqual(timeline.outputStart(of: lastID), 5)
    }

    func testStructuralEditsCannotCollapseBelowAFrameOrRemoveLastClip() throws {
        var timeline = try ClipTimeline(duration: 1, aspect: 1, frameDuration: 0.04)
        let original = timeline
        XCTAssertThrowsError(try timeline.deleteSelected())
        XCTAssertThrowsError(try timeline.split(at: 0.01))
        XCTAssertThrowsError(try timeline.split(at: 0.99))
        XCTAssertThrowsError(try timeline.split(at: .nan))
        XCTAssertThrowsError(try timeline.trimSelected(start: 0.2, end: 0.21))
        XCTAssertThrowsError(try timeline.trimSelected(start: .nan, end: 1))
        XCTAssertEqual(timeline, original)
        try timeline.split(at: 0.04)
        XCTAssertEqual(timeline.clips[0].duration, 0.04, accuracy: 0.000001)
        try timeline.deleteSelected()
        XCTAssertEqual(timeline.clips.count, 1)
        XCTAssertThrowsError(try timeline.deleteSelected())
    }

    func testPortraitCoverPanAndZoomAreClampedWithoutEmptyCanvas() throws {
        var timeline = try ClipTimeline(duration: 2, aspect: 16 / 9, frameDuration: 0.04)
        try timeline.setAspect(9 / 16)
        var crop = try XCTUnwrap(timeline.selectedClip).crop
        XCTAssertEqual(crop.width, 81 / 256, accuracy: 0.000001)
        XCTAssertEqual(crop.height, 1)
        XCTAssertEqual(crop.x, 175 / 512, accuracy: 0.000001)
        timeline.panSelected(dx: -100, dy: 100)
        crop = try XCTUnwrap(timeline.selectedClip).crop
        XCTAssertEqual(crop.x, 0)
        XCTAssertEqual(crop.y, 0)
        try timeline.zoomSelected(factor: 100)
        XCTAssertEqual(timeline.selectedZoom, 8, accuracy: 0.000001)
        crop = try XCTUnwrap(timeline.selectedClip).crop
        XCTAssertTrue(crop.isValid)
        XCTAssertEqual(crop.width, 81 / 2048, accuracy: 0.000001)
        XCTAssertEqual(crop.height, 0.125, accuracy: 0.000001)
        XCTAssertEqual((16 / 9) * crop.width / crop.height, 9 / 16, accuracy: 0.000001)
        timeline.panSelected(dx: 100, dy: 100)
        crop = try XCTUnwrap(timeline.selectedClip).crop
        XCTAssertEqual(crop.x + crop.width, 1, accuracy: 0.000001)
        XCTAssertEqual(crop.y + crop.height, 1, accuracy: 0.000001)
        try timeline.zoomSelected(factor: 0.00001)
        XCTAssertEqual(timeline.selectedZoom, 1, accuracy: 0.000001)
        XCTAssertEqual(timeline.selectedClip?.crop.height, 1)
        XCTAssertThrowsError(try timeline.zoomSelected(factor: 0))
        XCTAssertThrowsError(try timeline.zoomSelected(factor: .infinity))
    }

    func testFramingIsSharedAcrossAllClipsAndSurvivesStructuralEdits() throws {
        var timeline = try ClipTimeline(duration: 6, aspect: 2, frameDuration: 0.04)
        try timeline.split(at: 2); try timeline.split(at: 4)
        let selected = timeline.selectedID
        try timeline.setAspect(1)
        try timeline.zoomSelected(factor: 2)
        timeline.panSelected(dx: 0.1, dy: -0.1)
        let crop = try XCTUnwrap(timeline.selectedClip).crop
        XCTAssertEqual(timeline.clips.map(\.crop), Array(repeating: crop, count: 3))
        XCTAssertEqual(timeline.selectedID, selected)
        timeline.select(timeline.clips[0].id)
        timeline.panSelected(dx: 0.1, dy: 0.1)
        try timeline.setAspect(2)
        let shared = try XCTUnwrap(timeline.selectedClip).crop
        XCTAssertEqual(timeline.clips.map(\.crop), Array(repeating: shared, count: 3))
        try timeline.trimSelected(start: 0.2, end: 1.8)
        try timeline.split(at: 1)
        XCTAssertTrue(timeline.clips.allSatisfy { $0.crop == shared })
        try timeline.deleteSelected()
        XCTAssertTrue(timeline.clips.allSatisfy { $0.crop == shared })
        let before = timeline
        XCTAssertThrowsError(try timeline.setAspect(0))
        XCTAssertThrowsError(try timeline.setAspect(.nan))
        timeline.panSelected(dx: .nan, dy: .infinity)
        XCTAssertEqual(timeline, before)
        timeline.select(UUID())
        XCTAssertEqual(timeline.selectedID, before.selectedID)
    }

    func testSourceScrubbingSkipsInactiveRangesInDragDirection() throws {
        var timeline = try ClipTimeline(duration: 12, aspect: 2, frameDuration: 0.04)
        try timeline.split(at: 4); try timeline.split(at: 8)
        timeline.select(timeline.clips[0].id); try timeline.trimSelected(start: 1, end: 3)
        timeline.select(timeline.clips[1].id); try timeline.deleteSelected()
        timeline.select(timeline.clips[1].id); try timeline.trimSelected(start: 9, end: 11)
        XCTAssertEqual(timeline.outputTime(atSourceTime: 0), 0)
        XCTAssertEqual(timeline.outputTime(atSourceTime: 2), 1)
        XCTAssertEqual(timeline.outputTime(atSourceTime: 6, movingForward: true), 2)
        let backward = timeline.outputTime(atSourceTime: 6, movingForward: false)
        XCTAssertEqual(timeline.sourceTime(at: backward), 2.98, accuracy: 0.00001)
        XCTAssertEqual(timeline.outputTime(atSourceTime: 10), 3)
        XCTAssertEqual(timeline.sourceTime(at: timeline.outputTime(atSourceTime: 12)), 10.98, accuracy: 0.00001)
        XCTAssertEqual(timeline.sourceDuration, 12)
        XCTAssertEqual(timeline.inactiveRanges, [TimeSpan(start: 0, duration: 1), TimeSpan(start: 3, duration: 6), TimeSpan(start: 11, duration: 1)])
        XCTAssertEqual(timeline.duration, 4)
    }

    func testInvalidSourceGeometryIsRejected() {
        XCTAssertThrowsError(try ClipTimeline(duration: 0, aspect: 1, frameDuration: 0.04))
        XCTAssertThrowsError(try ClipTimeline(duration: .infinity, aspect: 1, frameDuration: 0.04))
        XCTAssertThrowsError(try ClipTimeline(duration: 1, aspect: 0, frameDuration: 0.04))
        XCTAssertThrowsError(try ClipTimeline(duration: 1, aspect: 1, frameDuration: .nan))
        XCTAssertThrowsError(try ClipTimeline(duration: 0.01, aspect: 1, frameDuration: 0.04))
    }
}
