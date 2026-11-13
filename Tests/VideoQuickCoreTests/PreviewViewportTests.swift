import XCTest
@testable import VideoQuickCore

final class PreviewViewportTests: XCTestCase {
    func testPanAndZoomUseExportCropCoordinatesAndAlwaysCoverViewport() throws {
        var timeline = try ClipTimeline(duration: 10, aspect: 16.0 / 9, frameDuration: 0.04)
        for aspect in [9.0 / 16, 1, 4.0 / 3, 16.0 / 9, 2.7, 0.4] {
            try timeline.setAspect(aspect)
            try timeline.zoomSelected(factor: 1.3)
            for delta in [-2.0, 0.05, 2.0] {
                timeline.panSelected(dx: delta, dy: delta)
                let crop = try XCTUnwrap(timeline.selectedClip?.crop)
                let size = CGSize(width: 600 * aspect, height: 600)
                let frame = PreviewViewport.frame(crop: crop, size: size)
                XCTAssertLessThanOrEqual(frame.minX, 0.00001)
                XCTAssertLessThanOrEqual(frame.minY, 0.00001)
                XCTAssertGreaterThanOrEqual(frame.maxX, size.width - 0.00001)
                XCTAssertGreaterThanOrEqual(frame.maxY, size.height - 0.00001)
                XCTAssertEqual(frame.minX + crop.x * frame.width, 0, accuracy: 0.00001)
                XCTAssertEqual(frame.minY + crop.y * frame.height, 0, accuracy: 0.00001)
                XCTAssertEqual(crop.width * frame.width, size.width, accuracy: 0.00001)
                XCTAssertEqual(crop.height * frame.height, size.height, accuracy: 0.00001)
            }
        }
    }
}
