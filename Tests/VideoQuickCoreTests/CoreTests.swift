import XCTest
@testable import VideoQuickCore

final class CoreTests: XCTestCase {
    @MainActor func testEditorMetadataPolicySurvivesQueueRestoreAndRetry() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: store) }
        let queue = ConversionQueue(storeURL: store, exporter: RecordingExporter())
        let source = URL(fileURLWithPath: "/tmp/fail.mov")
        try queue.enqueue(ConversionRequest(action: .convert, files: [source], bitrate: .mbps3, edits: EditPlan(trimStart: 1, metadataPolicy: .discard)), presentation: .editor)
        for _ in 0..<100 where queue.hasWork { try await Task.sleep(nanoseconds: 10_000_000) }
        let restored = ConversionQueue(storeURL: store, exporter: RecordingExporter())
        XCTAssertEqual(restored.jobs.first?.edits.metadataPolicy, .discard)
        try restored.retry(XCTUnwrap(restored.jobs.first).id)
        XCTAssertEqual(restored.jobs.last?.edits.metadataPolicy, .discard)
        restored.cancelAll()
        let legacy = try JSONDecoder().decode(EditPlan.self, from: Data(#"{"trimStart":0,"mute":false}"#.utf8))
        XCTAssertNil(legacy.metadataPolicy)
        XCTAssertFalse(legacy.isEdited)
    }
    @MainActor func testMeasuredDurationAccountsForRemovedContent() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: store) }
        let source = URL(fileURLWithPath: "/tmp/a.mov")
        let queue = ConversionQueue(storeURL: store, exporter: RecordingExporter())
        try queue.enqueue(ConversionRequest(action: .convert, files: [source], bitrate: .mbps3, edits: EditPlan(trimStart: 1, trimEnd: 10, cutStart: 4.8, cutEnd: 7.2)))
        queue.setDuration(for: source, duration: 12)
        XCTAssertEqual(queue.jobs[0].duration ?? 0, 6.6, accuracy: 0.0001)
        queue.cancelAll()
    }
    func testTrimAndInternalCutProduceContinuousRetainedRanges() throws {
        let edit = EditPlan(trimStart: 2, trimEnd: 18, cutStart: 6, cutEnd: 9)
        XCTAssertEqual(try edit.retainedRanges(duration: 20), [TimeSpan(start: 2, duration: 4), TimeSpan(start: 9, duration: 9)])
        XCTAssertThrowsError(try EditPlan(trimStart: 10, trimEnd: 4).retainedRanges(duration: 20))
        XCTAssertThrowsError(try EditPlan(cutStart: 0, cutEnd: 20).retainedRanges(duration: 20))
        XCTAssertThrowsError(try EditPlan(trimStart: .nan).retainedRanges(duration: 20))
        XCTAssertThrowsError(try EditPlan(crop: CropRect(x: 0.9, y: 0, width: 0.5, height: 1)).retainedRanges(duration: 20))
    }
    func testRequestRequiresExplicitPresetAndOnlyLocalVideoFiles() throws {
        let video = URL(fileURLWithPath: "/tmp/Ролик.MOV")
        XCTAssertThrowsError(try ConversionRequest(action: .convert, files: [video]).validate())
        XCTAssertNoThrow(try ConversionRequest(action: .convert, files: [video], bitrate: .mbps5).validate())
        XCTAssertThrowsError(try ConversionRequest(action: .convert, files: [URL(string: "https://example.com/a.mp4")!], bitrate: .mbps5).validate())
        XCTAssertThrowsError(try ConversionRequest(action: .edit, files: [video, URL(fileURLWithPath: "/tmp/a.txt")]).validate())
    }
    func testPublicationNeverOverwritesOriginalOrCollidingResult() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Ролик.mov")
        try Data("original".utf8).write(to: source)
        let first = dir.appendingPathComponent("Ролик_5mbps.mov")
        try Data("existing".utf8).write(to: first)
        let temp = dir.appendingPathComponent(".temp.mov")
        try Data("new".utf8).write(to: temp)
        let output = try OutputPublisher.publish(temporary: temp, source: source, bitrate: .mbps5, edited: false)
        XCTAssertEqual(output.lastPathComponent, "Ролик_5mbps_2.mov")
        XCTAssertEqual(try String(contentsOf: source), "original")
        XCTAssertEqual(try String(contentsOf: first), "existing")
        XCTAssertEqual(try String(contentsOf: output), "new")
    }
    @MainActor func testNewRequestsJoinSingleFIFOAndFailureDoesNotStopIt() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: store) }
        let engine = RecordingExporter()
        let queue = ConversionQueue(storeURL: store, exporter: engine)
        let a = ConversionRequest(action: .convert, files: [URL(fileURLWithPath: "/tmp/fail.mov"), URL(fileURLWithPath: "/tmp/b.mp4")], bitrate: .mbps3)
        try queue.enqueue(a)
        try await Task.sleep(nanoseconds: 10_000_000)
        try queue.enqueue(ConversionRequest(action: .convert, files: [URL(fileURLWithPath: "/tmp/c.mov")], bitrate: .mbps10))
        try queue.enqueue(a)
        for _ in 0..<200 where queue.jobs.contains(where: { !$0.state.isTerminal }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(queue.jobs.map(\.state), [.failed, .completed, .completed])
        XCTAssertEqual(queue.jobs.map(\.bitrate), [.mbps3, .mbps3, .mbps10])
        let observed = await engine.observed()
        XCTAssertEqual(observed.0, ["fail.mov", "b.mp4", "c.mov"])
        XCTAssertEqual(observed.1, 1)
    }
    @MainActor func testCancelledWorkDoesNotPublishAndRecoveryWaitsForUser() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let recovery = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: store); try? FileManager.default.removeItem(at: recovery) }
        let queue = ConversionQueue(storeURL: store, exporter: RecordingExporter())
        try queue.enqueue(ConversionRequest(action: .convert, files: [URL(fileURLWithPath: "/tmp/a.mov")], bitrate: .mbps1))
        try FileManager.default.copyItem(at: store, to: recovery)
        let restored = ConversionQueue(storeURL: recovery, exporter: RecordingExporter())
        XCTAssertTrue(restored.needsRecovery)
        XCTAssertEqual(restored.jobs.first?.state, .waiting)
        queue.cancelAll()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(queue.jobs.first?.state, .cancelled)
        XCTAssertNil(queue.jobs.first?.outputURL)
        XCTAssertEqual(restored.jobs.first?.state, .waiting)
        restored.resume()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(restored.jobs.first?.state, .completed)
    }
}

actor RecordingExporter: Exporting {
    private var names: [String] = []
    private var active = 0
    private var maximum = 0
    func export(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        active += 1; maximum = max(maximum, active); names.append(job.sourceURL.lastPathComponent)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 40_000_000)
        try Task.checkCancellation()
        if job.sourceURL.lastPathComponent == "fail.mov" { throw CocoaError(.fileReadCorruptFile) }
        progress(1)
        return job.sourceURL.deletingPathExtension().appendingPathExtension("result.mp4")
    }
    func observed() -> ([String], Int) { (names, maximum) }
}
