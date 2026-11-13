import XCTest
@testable import VideoQuickCore

final class HUDSessionTests: XCTestCase {
    func testHistoryStaysHiddenAndNewArrivalsJoinTheActiveRun() {
        let old = job(.failed), a = job(.running), b = job(.waiting), c = job(.waiting)
        var session = HUDSession(history: [old])
        XCTAssertTrue(session.jobs(in: [old]).isEmpty)
        session.update([old, a, b])
        session.update([old, a, b, c])
        XCTAssertEqual(session.jobs(in: [old, a, b, c]).map(\.id), [a.id, b.id, c.id])
    }
    func testNewRunReplacesCompletedSegmentsAndDismissDoesNotReplayHistory() {
        var a = job(.running); let b = job(.waiting)
        var session = HUDSession(history: [])
        session.update([a]); a.state = .completed
        session.update([a]); session.update([a, b])
        XCTAssertEqual(session.jobs(in: [a, b]).map(\.id), [b.id])
        session.dismiss(); session.update([a, b])
        XCTAssertTrue(session.jobs(in: [a, b]).isEmpty)
    }
    func testRecoveryPagesKeepEveryFileAndOnlyAdvanceAfterTheWholePageFinishes() {
        let old = job(.completed), recovered = job(.waiting)
        var session = HUDSession(history: [old, recovered])
        XCTAssertEqual(session.jobs(in: [old, recovered]).map(\.id), [recovered.id])
        let extra = (0..<49).map { _ in job(.waiting) }
        var all = [old, recovered] + extra
        session.update(all)
        XCTAssertEqual(session.segments(in: all).flatMap(\.jobs).map(\.id), Array(all[1...15]).map(\.id))
        for i in 1...14 { all[i].state = .completed }
        all[1].state = .cancelled
        all[15].state = .running
        session.update(all)
        XCTAssertEqual(session.segments(in: all).first?.id, recovered.id)
        all[15].state = .completed; session.update(all)
        XCTAssertEqual(session.segments(in: all).flatMap(\.jobs).map(\.id), Array(all[16...30]).map(\.id))
        for i in 16...45 { all[i].state = .completed }; session.update(all)
        XCTAssertEqual(session.segments(in: all).flatMap(\.jobs).map(\.id), Array(all[46...50]).map(\.id))
    }
    func testNewArrivalsStayOnTheirFIFOPageAndEarlierErrorsRemainInspectableAtTheEnd() {
        var jobs = (0..<15).map { _ in job(.waiting) }
        var session = HUDSession(history: jobs)
        let later = job(.waiting); jobs.append(later); session.update(jobs)
        XCTAssertEqual(session.segments(in: jobs).count, 15)
        for i in 0..<15 { jobs[i].state = .completed }
        jobs[2].state = .failed; session.update(jobs)
        XCTAssertEqual(session.segments(in: jobs).map(\.id), [later.id])
        jobs[15].state = .completed; session.update(jobs)
        XCTAssertTrue(session.segments(in: jobs).contains { $0.id == jobs[2].id && $0.failed })
    }
    func testWidthsUseCachedSourceBytesInsteadOfEqualSlots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let small = directory.appendingPathComponent("small.mov"), large = directory.appendingPathComponent("large.mov")
        try Data(repeating: 0, count: 1_000).write(to: small)
        try Data(repeating: 0, count: 3_000).write(to: large)
        let jobs = [ConversionJob(sourceURL: small, bitrate: .mbps5), ConversionJob(sourceURL: large, bitrate: .mbps5)]
        var session = HUDSession(history: jobs)
        let widths = session.segments(in: jobs, availableWidth: 403).map(\.width)
        XCTAssertEqual(widths, [100, 300]) // 400 pt after the one 3 pt gap; 1:3 bytes.
        try Data(repeating: 0, count: 9_000).write(to: small)
        session.update(jobs)
        XCTAssertEqual(session.segments(in: jobs, availableWidth: 403).map(\.width), widths)
    }
    func testMissingAndTinySourcesStillHaveVisibleTracksAndFitThePanel() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data(repeating: 0, count: 1_000_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let jobs = [job(.waiting), ConversionJob(sourceURL: file, bitrate: .mbps5)]
        let session = HUDSession(history: jobs)
        let segments = session.segments(in: jobs, availableWidth: 403)
        XCTAssertEqual(segments.map(\.width), [10, 390])
        XCTAssertTrue(segments.allSatisfy { $0.progress == 0 })
    }
    private func job(_ state: JobState) -> ConversionJob {
        var value = ConversionJob(sourceURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov"), bitrate: .mbps5)
        value.state = state
        return value
    }
}
