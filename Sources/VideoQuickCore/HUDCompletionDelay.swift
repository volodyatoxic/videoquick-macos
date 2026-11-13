import Foundation

/// The hide deadline belongs to the visible service run, not unrelated editor updates.
public struct HUDCompletionDelay {
    public private(set) var jobIDs: [UUID]?
    public init() {}
    public mutating func update(session: HUDSession, jobs: [ConversionJob]) -> Bool {
        let current = session.jobs(in: jobs)
        let next = !current.isEmpty && current.allSatisfy({ $0.state.isTerminal && $0.state != .failed }) ? session.jobIDs : nil
        guard next != jobIDs else { return false }
        jobIDs = next
        return true
    }
    public mutating func clear() { jobIDs = nil }
}
