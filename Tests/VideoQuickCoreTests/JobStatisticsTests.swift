import XCTest
@testable import VideoQuickCore

final class JobStatisticsTests: XCTestCase {
    func testSavingsReportsSignedChangeAndHandlesZeroOrMissingSizes() throws {
        var job = ConversionJob(sourceURL: URL(fileURLWithPath: "/unavailable/source.mov"), bitrate: .mbps5)
        XCTAssertNil(job.savedBytes)
        XCTAssertNil(job.savedPercentage)
        job.sourceBytes = 100; job.outputBytes = 60
        XCTAssertEqual(job.savedBytes, 40)
        XCTAssertEqual(try XCTUnwrap(job.savedPercentage), 40, accuracy: 0.00001)
        job.outputBytes = 150
        XCTAssertEqual(job.savedBytes, -50)
        XCTAssertEqual(try XCTUnwrap(job.savedPercentage), -50, accuracy: 0.00001)
        job.outputBytes = 0
        XCTAssertEqual(job.savedBytes, 100)
        XCTAssertEqual(job.savedPercentage, 100)
        job.sourceBytes = 0
        XCTAssertEqual(job.savedBytes, 0)
        XCTAssertNil(job.savedPercentage)
        job.outputBytes = 10
        XCTAssertEqual(job.savedBytes, -10)
        XCTAssertNil(job.savedPercentage, "A zero-byte source has no finite savings percentage")
        job.sourceBytes = -1
        XCTAssertNil(job.savedBytes)
        XCTAssertNil(job.savedPercentage)
    }

    @MainActor func testQueueMeasuresFilesAtExportBoundariesAndExcludesWaitingTime() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.mov")
        let second = directory.appendingPathComponent("second.mov")
        try Data(repeating: 1, count: 1_000).write(to: first)
        try Data(repeating: 2, count: 2_000).write(to: second)
        let store = directory.appendingPathComponent("queue.json")
        let queue = ConversionQueue(storeURL: store, exporter: StatisticsFileExporter())
        try queue.enqueue(ConversionRequest(action: .convert, files: [first, second], bitrate: .mbps3))

        // The first job has started, while the second source can still change in FIFO.
        XCTAssertEqual(queue.jobs.map(\.state), [.running, .waiting])
        try Data(repeating: 3, count: 1_500).write(to: first)
        try Data(repeating: 4, count: 3_000).write(to: second)
        for _ in 0..<300 where queue.hasWork { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(queue.jobs.map(\.state), [.completed, .completed])

        let firstMetrics = try encodedJob(queue.jobs[0])
        let secondMetrics = try encodedJob(queue.jobs[1])
        XCTAssertEqual((firstMetrics["sourceBytes"] as? NSNumber)?.int64Value, 1_000)
        XCTAssertEqual((secondMetrics["sourceBytes"] as? NSNumber)?.int64Value, 3_000)
        XCTAssertEqual((firstMetrics["outputBytes"] as? NSNumber)?.int64Value, 400)
        XCTAssertEqual((secondMetrics["outputBytes"] as? NSNumber)?.int64Value, 600)
        let firstElapsed = try XCTUnwrap((firstMetrics["exportElapsedSeconds"] as? NSNumber)?.doubleValue)
        let secondElapsed = try XCTUnwrap((secondMetrics["exportElapsedSeconds"] as? NSNumber)?.doubleValue)
        XCTAssertGreaterThanOrEqual(firstElapsed, 0.35)
        XCTAssertGreaterThanOrEqual(secondElapsed, 0.04)
        XCTAssertLessThan(secondElapsed, firstElapsed / 2, "The second job's FIFO wait must not count as export time")

        // Completed measurements survive queue persistence without being remeasured.
        try Data(repeating: 5, count: 9_000).write(to: first)
        let restored = ConversionQueue(storeURL: store, exporter: StatisticsFileExporter())
        let restoredMetrics = try encodedJob(restored.jobs[0])
        XCTAssertEqual((restoredMetrics["sourceBytes"] as? NSNumber)?.int64Value, 1_000)
        XCTAssertEqual((restoredMetrics["outputBytes"] as? NSNumber)?.int64Value, 400)
        XCTAssertEqual((restoredMetrics["exportElapsedSeconds"] as? NSNumber)?.doubleValue, firstElapsed)
    }

    func testLegacyJobDecodesWithoutInventingMetricsOrElapsedTime() throws {
        let legacy = """
        {"id":"804C624C-DFE7-4751-9810-E046837C7AB1","batchID":"ED4D23A3-60B9-47DE-AD61-66C54229B11A", "sourceURL":"file:///unavailable/source.mov","bitrate":5,"edits":{"trimStart":0,"mute":false},"state":"completed","progress":1,"outputURL":"file:///unavailable/result.mov","duration":15}
        """
        let job = try JSONDecoder().decode(ConversionJob.self, from: Data(legacy.utf8))
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.duration, 15)
        let metrics = try encodedJob(job)
        XCTAssertNil(metrics["sourceBytes"])
        XCTAssertNil(metrics["outputBytes"])
        XCTAssertNil(metrics["exportElapsedSeconds"], "Video duration is not measured export elapsed time")
    }

    @MainActor func testLegacyQueueBackfillsOnlyLatestHundredAndPersistsMetadataWithoutElapsed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("legacy.mov")
        let output = directory.appendingPathComponent("legacy_result.mov")
        try Data(repeating: 1, count: 100).write(to: source)
        try Data(repeating: 2, count: 60).write(to: output)
        let store = directory.appendingPathComponent("queue.json")
        var rows: [[String: Any]] = []
        for index in 0..<102 {
            var job = ConversionJob(sourceURL: source, bitrate: .mbps5)
            job.state = .completed; job.outputURL = output; job.duration = 15
            var row = try encodedJob(job)
            if index == 101 { row["sourceBytes"] = 200; row["outputBytes"] = 90 }
            rows.append(row)
        }
        try JSONSerialization.data(withJSONObject: ["jobs": rows, "received": []]).write(to: store)
        let queue = ConversionQueue(storeURL: store, exporter: StatisticsFileExporter())
        XCTAssertNil(queue.persistenceError)
        let measured = try queue.jobs.map(encodedJob)
        XCTAssertNil(measured[0]["sourceBytes"])
        XCTAssertNil(measured[1]["outputBytes"])
        XCTAssertEqual((measured[2]["sourceBytes"] as? NSNumber)?.int64Value, 100)
        XCTAssertEqual((measured[2]["outputBytes"] as? NSNumber)?.int64Value, 60)
        XCTAssertEqual((measured[101]["sourceBytes"] as? NSNumber)?.int64Value, 200)
        XCTAssertEqual((measured[101]["outputBytes"] as? NSNumber)?.int64Value, 90)
        XCTAssertTrue(measured.allSatisfy { $0["exportElapsedSeconds"] == nil })

        let persisted = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        let persistedRows = try XCTUnwrap(persisted["jobs"] as? [[String: Any]])
        XCTAssertEqual((persistedRows[2]["sourceBytes"] as? NSNumber)?.int64Value, 100)
        // An unchanged refresh must not rewrite the queue file.
        let marker = Date(timeIntervalSince1970: 123_456)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: store.path)
        _ = ConversionQueue(storeURL: store, exporter: StatisticsFileExporter())
        let modification = try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date
        XCTAssertEqual(modification, marker)
    }

    @MainActor func testFailedExportRecordsElapsedWithoutOutputAndPendingRowsAreNotBackfilled() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fail.mov")
        try Data(repeating: 1, count: 25).write(to: source)
        let store = directory.appendingPathComponent("queue.json")
        let pending = ConversionJob(sourceURL: source, bitrate: .mbps3)
        try JSONSerialization.data(withJSONObject: ["jobs": [try encodedJob(pending)], "received": []]).write(to: store)
        let queue = ConversionQueue(storeURL: store, exporter: StatisticsFileExporter())
        XCTAssertTrue(queue.needsRecovery)
        XCTAssertNil(queue.jobs[0].sourceBytes, "Pending source bytes must be measured when its export actually starts")
        queue.resume()
        for _ in 0..<100 where queue.hasWork { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(queue.jobs[0].state, .failed)
        XCTAssertEqual(queue.jobs[0].sourceBytes, 25)
        XCTAssertNil(queue.jobs[0].outputBytes)
        XCTAssertNil(queue.jobs[0].outputURL)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(queue.jobs[0].exportElapsedSeconds), 0.04)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func encodedJob(_ job: ConversionJob) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    }
}

private actor StatisticsFileExporter: Exporting {
    func export(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let first = job.sourceURL.lastPathComponent == "first.mov"
        try await Task.sleep(nanoseconds: first ? 400_000_000 : 50_000_000)
        if job.sourceURL.lastPathComponent == "fail.mov" { throw CocoaError(.fileReadCorruptFile) }
        let temporary = job.sourceURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(repeating: 7, count: first ? 400 : 600).write(to: temporary)
        return try OutputPublisher.publish(temporary: temporary, source: job.sourceURL, bitrate: job.bitrate, edited: false)
    }
}
