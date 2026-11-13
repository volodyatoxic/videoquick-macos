import XCTest
@testable import VideoQuickCore

final class LaunchPresentationTests: XCTestCase {
    func testOnlyAnUnclaimedManualLaunchOpensHistory() {
        XCTAssertEqual(LaunchPresentation.startup(isDefaultLaunch: true, receivedExternalOpen: false, consumedFinderRequest: false), .history)
        XCTAssertEqual(LaunchPresentation.startup(isDefaultLaunch: false, receivedExternalOpen: false, consumedFinderRequest: false), .service)
        XCTAssertEqual(LaunchPresentation.startup(isDefaultLaunch: true, receivedExternalOpen: true, consumedFinderRequest: false), .service)
        XCTAssertEqual(LaunchPresentation.startup(isDefaultLaunch: true, receivedExternalOpen: false, consumedFinderRequest: true), .service)
    }
}
