import Foundation

/// A display-only, piecewise time map. Source/edit/export times stay unchanged.
public struct TimelineDisplayLayout {
    public struct Item: Identifiable {
        public let range: TimeSpan
        public let clipID: UUID?
        public var x: Double
        public var width: Double
        public var id: String { clipID?.uuidString ?? "gap:\(range.start)" }
        public var inset: Double { clipID == nil ? 0 : min(13, max(0, width / 4)) }
        public var innerStart: Double { x + inset }
        public var innerEnd: Double { x + width - inset }
    }
    public let sourceDuration: Double
    public let frameDuration: Double
    public private(set) var items: [Item] = []
    public private(set) var contentWidth: Double = 0
    public init(sourceDuration: Double, viewportWidth: Double, clips: [ClipEdit], frameDuration: Double, zoom: Double = 1) {
        self.sourceDuration = sourceDuration; self.frameDuration = frameDuration
        guard sourceDuration.isFinite, sourceDuration > 0, viewportWidth.isFinite, viewportWidth > 0 else { return }
        var cursor = 0.0
        for clip in clips {
            if clip.start - cursor > frameDuration * 0.00001 { items.append(Item(range: TimeSpan(start: cursor, duration: clip.start - cursor), clipID: nil, x: 0, width: 0)) }
            items.append(Item(range: TimeSpan(start: clip.start, duration: clip.duration), clipID: clip.id, x: 0, width: 0)); cursor = clip.end
        }
        if sourceDuration - cursor > frameDuration * 0.00001 { items.append(Item(range: TimeSpan(start: cursor, duration: sourceDuration - cursor), clipID: nil, x: 0, width: 0)) }
        // Fit floors where possible, but retain half the natural time scale
        // before scrolling so long spans never flatten to tiny clip widths.
        let natural = viewportWidth / sourceDuration
        var low = 0.0, high = natural
        for _ in 0..<32 {
            let scale = (low + high) / 2
            let total = items.reduce(0.0) { $0 + max($1.clipID == nil ? 8 : 22, $1.range.duration * scale) }
            if total > viewportWidth { high = scale } else { low = scale }
        }
        let scale = max(natural / 2, low)
        for index in items.indices {
            items[index].x = contentWidth
            items[index].width = max(items[index].clipID == nil ? 8 : 22, items[index].range.duration * scale)
            contentWidth += items[index].width
        }
        let magnification = zoom.isFinite ? min(256, max(1, zoom)) : 1
        for index in items.indices { items[index].x *= magnification; items[index].width *= magnification }
        contentWidth = max(viewportWidth, contentWidth) * magnification
    }
    public func item(for id: UUID) -> Item? { items.first { $0.clipID == id } }
    public func x(at sourceTime: Double, preferredClip: UUID? = nil) -> Double {
        // Trim times are frame-snapped; a paused cursor can sit between samples.
        // Treat the equivalent half-frame boundary as the same inner edge.
        let tolerance = frameDuration / 2 + 0.000001
        let preferred = preferredClip.flatMap { item(for: $0) }.flatMap { sourceTime >= $0.range.start - tolerance && sourceTime <= $0.range.start + $0.range.duration + tolerance ? $0 : nil }
        guard let item = preferred ?? items.first(where: { sourceTime >= $0.range.start && sourceTime < $0.range.start + $0.range.duration }) ?? items.last else { return 0 }
        let fraction = min(1, max(0, (sourceTime - item.range.start) / item.range.duration))
        return item.innerStart + fraction * (item.innerEnd - item.innerStart)
    }
    public func sourceTime(atX x: Double, movingForward: Bool = true, trimming: Bool = false) -> Double {
        guard let item = items.first(where: { x >= $0.x && x < $0.x + $0.width }) ?? (x < 0 ? items.first : items.last) else { return 0 }
        if item.clipID != nil, !trimming {
            if x <= item.innerStart { return movingForward ? item.range.start : max(0, item.range.start - frameDuration / 2) }
            if x >= item.innerEnd { return movingForward ? item.range.start + item.range.duration : item.range.start + item.range.duration - min(frameDuration / 2, item.range.duration / 2) }
        }
        let fraction = min(1, max(0, (x - item.innerStart) / max(0.000001, item.innerEnd - item.innerStart)))
        return item.range.start + fraction * item.range.duration
    }
    public func snappedTrimTime(_ proposed: Double, playhead: Double, clip: UUID, limits: ClosedRange<Double>) -> Double {
        let bounded = min(limits.upperBound, max(limits.lowerBound, proposed))
        guard limits.contains(playhead), abs(x(at: bounded, preferredClip: clip) - x(at: playhead, preferredClip: clip)) <= 8 else { return bounded }
        return playhead
    }
}
