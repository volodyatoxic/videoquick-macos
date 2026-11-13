import XCTest
@testable import VideoQuickCore

final class HistoryWindowTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func dated(_ date: Date, imported: Bool = false) throws -> ConversionJob {
        let job = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/history.mov"), bitrate: .mbps5)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object.removeValue(forKey: "createdAt")
        object[imported ? "historyImportedAt" : "createdAt"] = date.timeIntervalSinceReferenceDate
        return try JSONDecoder().decode(ConversionJob.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testThirtyDayBoundaryWithoutTruncatingStoredHistory() throws {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let old = try dated(cutoff.addingTimeInterval(-1))
        let boundary = try dated(cutoff)
        let fresh = try (0..<125).map { _ in try dated(now.addingTimeInterval(-60)) }
        let stored = [old, boundary] + fresh
        let visible = HistoryWindow.recentJobs(from: stored, now: now)
        XCTAssertFalse(visible.contains { $0.id == old.id })
        XCTAssertTrue(visible.contains { $0.id == boundary.id })
        XCTAssertEqual(visible.count, 126)
        XCTAssertEqual(visible.first?.id, fresh.last?.id)
        XCTAssertEqual(stored.count, 127)
    }
    func testLegacyImportBaselineExpiresWithoutPretendingToKnowActionTime() throws {
        let legacy = try dated(now, imported: true)
        XCTAssertEqual(HistoryWindow.recentJobs(from: [legacy], now: now).count, 1)
        XCTAssertTrue(HistoryWindow.recentJobs(from: [legacy], now: now.addingTimeInterval(30 * 86_400 + 1)).isEmpty)
    }
    @MainActor func testQueuePersistsAllDatesAndImportsLegacyOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("queue.json")
        var legacy = ConversionJob(sourceURL: directory.appendingPathComponent("missing.mov"), bitrate: .mbps5)
        legacy.state = .completed
        var old = try dated(now.addingTimeInterval(-90 * 86_400)); old.state = .completed
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "createdAt")
        let snapshot: [String: Any] = ["jobs": [object, try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))], "received": []]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: store)
        let queue = ConversionQueue(storeURL: store, exporter: HistoryUnusedExporter())
        let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue.jobs[0])) as? [String: Any])
        let importDate = try XCTUnwrap(migrated["historyImportedAt"] as? Double)
        XCTAssertNil(migrated["createdAt"])
        let restored = ConversionQueue(storeURL: store, exporter: HistoryUnusedExporter())
        let reloaded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.jobs[0])) as? [String: Any])
        XCTAssertEqual(reloaded["historyImportedAt"] as? Double, importDate)
        XCTAssertEqual(restored.jobs.count, 2)
        XCTAssertEqual(restored.jobs[1].id, old.id)
        let requestDate = Date()
        try restored.enqueue(ConversionRequest(action: .convert, files: [directory.appendingPathComponent("new.mov")], bitrate: .mbps1, createdAt: requestDate))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.jobs.last!)) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(encoded["createdAt"] as? Double), requestDate.timeIntervalSinceReferenceDate, accuracy: 0.001)
        restored.cancelAll()
    }
}

private struct HistoryUnusedExporter: Exporting {
    func export(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { throw CancellationError() }
}
