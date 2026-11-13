import Foundation

/// Only the current run is presented; persisted history never floods the HUD.
public struct HUDSession {
    private var seen: Set<UUID>
    private var sourceBytes: [URL: Double] = [:]
    public private(set) var jobIDs: [UUID]
    public init(history: [ConversionJob]) {
        let history = history.filter { $0.presentation != .editor }
        seen = Set(history.map(\.id))
        jobIDs = history.filter { !$0.state.isTerminal }.map(\.id)
        cacheSourceBytes(for: history.filter { !$0.state.isTerminal })
    }
    public mutating func update(_ jobs: [ConversionJob]) {
        let jobs = jobs.filter { $0.presentation != .editor }
        let arrivals = jobs.filter { !seen.contains($0.id) }
        if !arrivals.isEmpty {
            if self.jobs(in: jobs).allSatisfy({ $0.state.isTerminal }) { jobIDs = []; sourceBytes = [:] }
            jobIDs += arrivals.map(\.id)
            cacheSourceBytes(for: arrivals)
        }
        let existing = Set(jobs.map(\.id))
        jobIDs.removeAll { !existing.contains($0) }
        seen.formUnion(existing)
    }
    public mutating func dismiss() { jobIDs = []; sourceBytes = [:] }
    public func jobs(in allJobs: [ConversionJob]) -> [ConversionJob] {
        let values = Dictionary(uniqueKeysWithValues: allJobs.map { ($0.id, $0) })
        return jobIDs.compactMap { values[$0] }
    }
    public func segments(in allJobs: [ConversionJob], availableWidth: Double = 552) -> [HUDSegment] {
        let values = jobs(in: allJobs)
        guard !values.isEmpty else { return [] }
        // A terminal page advances only when its last unfinished file finishes.
        // At the end, keep an earlier failure inspectable without page controls.
        let focus = values.firstIndex { !$0.state.isTerminal }
            ?? values.firstIndex { $0.state == .failed } ?? (values.count - 1)
        let start = (focus / 15) * 15
        let page = Array(values[start..<min(start + 15, values.count)])
        let weights = page.map { sourceBytes[$0.sourceURL] ?? 1 }
        var remaining = max(0, availableWidth - Double(page.count - 1) * 3)
        let minimum = min(10, remaining / Double(page.count))
        var widths = [Double](repeating: 0, count: page.count)
        var pending = Array(page.indices)
        // Keep tiny/missing sources visible; all other widths keep their byte ratio.
        while !pending.isEmpty {
            let total = pending.reduce(0) { $0 + weights[$1] }
            let small = pending.filter { remaining * weights[$0] / total < minimum }
            if small.isEmpty {
                for i in pending { widths[i] = remaining * weights[i] / total }
                break
            }
            for i in small { widths[i] = minimum; remaining -= minimum }
            let fixed = Set(small); pending.removeAll { fixed.contains($0) }
        }
        return page.indices.map { HUDSegment(jobs: [page[$0]], width: widths[$0]) }
    }
    private mutating func cacheSourceBytes(for jobs: [ConversionJob]) {
        for job in jobs where sourceBytes[job.sourceURL] == nil {
            let size = try? job.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            sourceBytes[job.sourceURL] = Double(max(1, size ?? 1))
        }
    }
}
public struct HUDSegment: Identifiable {
    public let jobs: [ConversionJob]
    public let width: Double
    public var id: UUID { jobs[0].id }
    public var progress: Double { jobs.reduce(0) { $0 + ($1.state.isTerminal ? 1 : $1.progress) } / Double(jobs.count) }
    public var failed: Bool { jobs.contains { $0.state == .failed } }
    public var completed: Bool { jobs.allSatisfy { $0.state == .completed } }
}
