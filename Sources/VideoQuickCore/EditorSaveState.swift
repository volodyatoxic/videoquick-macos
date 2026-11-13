import Foundation

/// Presentation of one editor-owned job, independent of other work in the FIFO.
public struct EditorSaveState {
    public let job: ConversionJob?
    public init(job: ConversionJob? = nil) { self.job = job }
    public var isActive: Bool { job.map { !$0.state.isTerminal } ?? false }
    public var progress: Double {
        guard let job, isActive else { return 1 }
        guard job.state == .running, job.progress.isFinite else { return 0 }
        return min(1, max(0, job.progress))
    }
    public func fraction(for clipID: UUID, in timeline: ClipTimeline) -> Double {
        guard isActive, let clip = timeline.clips.first(where: { $0.id == clipID }) else { return 1 }
        return min(1, max(0, (progress * timeline.duration - timeline.outputStart(of: clipID)) / clip.duration))
    }
}
