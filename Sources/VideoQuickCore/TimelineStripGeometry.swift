import Foundation

/// Visual time occupies the filmstrip between trim handles, not the handles themselves.
public struct TimelineStripGeometry {
    public let sourceDuration: Double
    public let width: Double
    public let frameDuration: Double
    public init(sourceDuration: Double, width: Double, frameDuration: Double = 1.0 / 30) { self.sourceDuration = sourceDuration; self.width = width; self.frameDuration = frameDuration }
    public func left(of clip: ClipEdit) -> Double { clip.start / sourceDuration * width }
    public func clipWidth(_ clip: ClipEdit) -> Double { max(1, clip.duration / sourceDuration * width) }
    public func inset(_ clip: ClipEdit) -> Double { min(11, max(0, (clipWidth(clip) - 1) / 2)) }
    public func snappedTrimTime(_ proposed: Double, playhead: Double, limits: ClosedRange<Double>) -> Double {
        let bounded = min(limits.upperBound, max(limits.lowerBound, proposed))
        guard sourceDuration > 0, width > 0, playhead.isFinite, limits.contains(playhead),
              abs(bounded - playhead) / sourceDuration * width <= 8 else { return bounded }
        return playhead
    }
    public func playheadX(sourceTime: Double, clip: ClipEdit) -> Double {
        let fraction = min(1, max(0, (sourceTime - clip.start) / clip.duration))
        return left(of: clip) + inset(clip) + fraction * (clipWidth(clip) - 2 * inset(clip))
    }
    public func sourceTime(atX x: Double, clips: [ClipEdit], movingForward: Bool = true) -> Double {
        for clip in clips {
            let left = left(of: clip), size = clipWidth(clip), padding = inset(clip)
            guard x >= left, x <= left + size else { continue }
            if x <= left + padding { return movingForward ? clip.start : max(0, clip.start - frameDuration / 2) }
            if x >= left + size - padding { return movingForward ? clip.end : clip.end - min(frameDuration / 2, clip.duration / 2) }
            return clip.start + (x - left - padding) / (size - 2 * padding) * clip.duration
        }
        return min(sourceDuration, max(0, x / width * sourceDuration))
    }
}
