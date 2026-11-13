import XCTest
@testable import VideoQuickCore

final class RequestInboxTests: XCTestCase {
    func testPendingRequestsUseCreationOrderRatherThanDirectoryEnumeration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = URL(fileURLWithPath: "/tmp/a.mov")
        let later = ConversionRequest(action: .convert, files: [file], bitrate: .mbps20, createdAt: Date(timeIntervalSince1970: 20))
        let earlier = ConversionRequest(action: .convert, files: [file], bitrate: .mbps1, createdAt: Date(timeIntervalSince1970: 10))
        _ = try RequestInbox.write(later, directory: folder)
        _ = try RequestInbox.write(earlier, directory: folder)
        XCTAssertEqual(try RequestInbox.pending(directory: folder).map(\.request.bitrate), [.mbps1, .mbps20])
    }
    func testLargeSelectionRoundTripsButExternalAndSymlinkRequestsAreRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: other) }
        let request = ConversionRequest(action: .convert, files: (0..<2_000).map { URL(fileURLWithPath: "/tmp/Видео \($0).mov") }, bitrate: .mbps20)
        let command = try RequestInbox.write(request, directory: folder)
        let received = try RequestInbox.read(command, directory: folder)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: received.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(received.request.files.count, 2_000)
        XCTAssertEqual(received.request.id, request.id)
        XCTAssertLessThan(command.absoluteString.count, 1024)
        let external = try RequestInbox.write(request, directory: other)
        XCTAssertThrowsError(try RequestInbox.read(external, directory: folder))
        try FileManager.default.removeItem(at: received.fileURL)
        try FileManager.default.createSymbolicLink(at: received.fileURL, withDestinationURL: other.appendingPathComponent(request.id.uuidString + ".json"))
        XCTAssertThrowsError(try RequestInbox.read(command, directory: folder))
    }
}
