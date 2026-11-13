import XCTest
@testable import VideoQuickCore

final class EditorPresentationTests: XCTestCase {
    func testEditorJobsNeverEnterCompactHUDIncludingRecoveryAndNewArrivals() throws {
        let editor = try taggedEditorJob()
        let service = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/service.mov"), bitrate: .mbps5)
        var recovered = HUDSession(history: [editor, service])
        XCTAssertEqual(recovered.jobIDs, [service.id])
        let later = try taggedEditorJob()
        recovered.update([editor, service, later])
        XCTAssertEqual(recovered.jobIDs, [service.id])
        var fresh = HUDSession(history: [])
        fresh.update([editor, later])
        XCTAssertTrue(fresh.jobIDs.isEmpty)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(editor)) as! [String: Any]
        XCTAssertEqual(encoded["presentation"] as? String, "editor")
    }
    func testRevealUsesRetainedDurationsAndTerminalStatesRestoreNormalTimeline() throws {
        var timeline = try ClipTimeline(duration: 10, aspect: 2, frameDuration: 0.04)
        try timeline.split(at: 2)
        var job = try taggedEditorJob()
        job.state = .waiting; job.progress = 0.7
        XCTAssertEqual(EditorSaveState(job: job).progress, 0)
        job.state = .running; job.progress = 0.6
        let state = EditorSaveState(job: job)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.fraction(for: timeline.clips[0].id, in: timeline), 1)
        XCTAssertEqual(state.fraction(for: timeline.clips[1].id, in: timeline), 0.5)
        for terminal in [JobState.completed, .cancelled, .failed] {
            job.state = terminal
            XCTAssertFalse(EditorSaveState(job: job).isActive)
            XCTAssertEqual(EditorSaveState(job: job).fraction(for: timeline.clips[1].id, in: timeline), 1)
        }
        XCTAssertFalse(EditorSaveState().isActive)
    }
    @MainActor func testEditorPresentationPersistsAndCancellationDoesNotStopOtherFIFOJobs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("queue.json"), copy = dir.appendingPathComponent("recovery.json")
        let engine = RecordingExporter()
        let queue = ConversionQueue(storeURL: store, exporter: engine)
        try queue.enqueue(ConversionRequest(action: .convert, files: [dir.appendingPathComponent("service.mov")], bitrate: .mbps5))
        let editRequest = ConversionRequest(action: .convert, files: [dir.appendingPathComponent("editor.mov")], bitrate: .mbps3)
        try queue.enqueue(editRequest, presentation: .editor)
        try FileManager.default.copyItem(at: store, to: copy)
        let restored = ConversionQueue(storeURL: copy, exporter: engine)
        XCTAssertEqual(restored.jobs.map(\.presentation), [.compact, .editor])
        XCTAssertEqual(HUDSession(history: restored.jobs).jobIDs, [restored.jobs[0].id])
        queue.cancel(queue.jobs[1].id)
        for _ in 0..<100 where queue.hasWork { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(queue.jobs.map(\.state), [.completed, .cancelled])
        XCTAssertEqual(queue.jobs[1].batchID, editRequest.id)
        try queue.retry(queue.jobs[1].id)
        XCTAssertEqual(queue.jobs.last?.presentation, .editor)
        queue.cancelAll()
    }
    func testEditorProgressDoesNotResetCompletedServiceHideDeadline() throws {
        var service = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/service.mov"), bitrate: .mbps5)
        var editor = try taggedEditorJob()
        service.state = .completed; editor.state = .running
        let session = HUDSession(history: [])
        var run = session; run.update([service, editor])
        var delay = HUDCompletionDelay()
        XCTAssertTrue(delay.update(session: run, jobs: [service, editor]))
        for step in 1...10 {
            editor.progress = Double(step) / 10
            XCTAssertFalse(delay.update(session: run, jobs: [service, editor]))
            XCTAssertEqual(delay.jobIDs, [service.id])
        }
    }
    private func taggedEditorJob() throws -> ConversionJob {
        let job = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/editor.mov"), bitrate: .mbps5)
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        encoded["presentation"] = "editor"
        return try JSONDecoder().decode(ConversionJob.self, from: JSONSerialization.data(withJSONObject: encoded))
    }
}
