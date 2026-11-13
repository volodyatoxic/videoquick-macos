import Foundation

public struct ClipTimeline: Equatable, Sendable {
    public private(set) var clips: [ClipEdit]
    public private(set) var selectedID: UUID
    public private(set) var aspect: Double
    public let sourceDuration: Double
    public let sourceAspect: Double
    public let frameDuration: Double
    public init(duration: Double, aspect: Double, frameDuration: Double) throws {
        guard duration.isFinite, aspect.isFinite, frameDuration.isFinite,
              frameDuration > 0, duration >= frameDuration, aspect > 0 else {
            throw VideoQuickError("Не удалось определить длительность, частоту кадров или размер видео.")
        }
        let clip = ClipEdit(start: 0, duration: duration)
        clips = [clip]; selectedID = clip.id; self.aspect = aspect
        sourceDuration = duration; sourceAspect = aspect; self.frameDuration = frameDuration
    }
    public var duration: Double { clips.reduce(0) { $0 + $1.duration } }
    public var inactiveRanges: [TimeSpan] {
        var cursor = 0.0
        var ranges: [TimeSpan] = []
        for clip in clips {
            if clip.start > cursor { ranges.append(TimeSpan(start: cursor, duration: clip.start - cursor)) }
            cursor = clip.end
        }
        if cursor < sourceDuration { ranges.append(TimeSpan(start: cursor, duration: sourceDuration - cursor)) }
        return ranges
    }
    public var selectedClip: ClipEdit? { clips.first { $0.id == selectedID } }
    public var selectedOutputStart: Double { outputStart(of: selectedID) }
    public var selectedLimits: ClosedRange<Double> {
        guard let index = selectedIndex else { return 0...sourceDuration }
        let lower = index == 0 ? 0 : clips[index - 1].end
        let upper = index == clips.count - 1 ? sourceDuration : clips[index + 1].start
        return lower...upper
    }
    public var selectedZoom: Double {
        guard let crop = selectedClip?.crop else { return 1 }
        return zoom(of: crop, aspect: aspect)
    }
    public mutating func select(_ id: UUID) {
        if clips.contains(where: { $0.id == id }) { selectedID = id }
    }
    public mutating func split(at outputTime: Double) throws {
        guard outputTime.isFinite, outputTime > 0, outputTime < duration else {
            throw VideoQuickError("Поставьте указатель внутри фрагмента.")
        }
        var cursor = 0.0
        for index in clips.indices {
            let clip = clips[index]
            if outputTime < cursor + clip.duration {
                let boundary = snapped(clip.start + outputTime - cursor)
                guard boundary - clip.start >= frameDuration - tolerance,
                      clip.end - boundary >= frameDuration - tolerance else {
                    throw VideoQuickError("С каждой стороны разреза должен остаться хотя бы один кадр.")
                }
                let right = ClipEdit(start: boundary, duration: clip.end - boundary, crop: clip.crop)
                clips[index].duration = boundary - clip.start
                clips.insert(right, at: index + 1)
                selectedID = right.id
                return
            }
            cursor += clip.duration
        }
        throw VideoQuickError("Поставьте указатель внутри фрагмента.")
    }
    public mutating func deleteSelected() throws {
        guard clips.count > 1, let index = selectedIndex else { throw VideoQuickError("Нельзя удалить последний фрагмент.") }
        clips.remove(at: index)
        selectedID = clips[min(index, clips.count - 1)].id
    }
    public mutating func trimSelected(start: Double, end: Double) throws {
        let limits = selectedLimits
        guard let index = selectedIndex, start.isFinite, end.isFinite,
              start >= limits.lowerBound - tolerance, end <= limits.upperBound + tolerance else {
            throw VideoQuickError("Границы фрагмента не должны перекрывать соседние фрагменты.")
        }
        let a = min(limits.upperBound, max(limits.lowerBound, snapped(start)))
        let b = min(limits.upperBound, max(limits.lowerBound, snapped(end)))
        guard b - a >= frameDuration - tolerance else { throw VideoQuickError("Во фрагменте должен остаться хотя бы один кадр.") }
        clips[index].start = a; clips[index].duration = b - a
    }
    public mutating func setAspect(_ ratio: Double) throws {
        guard ratio.isFinite, ratio > 0 else { throw VideoQuickError("Выберите допустимое соотношение сторон.") }
        guard let crop = selectedClip?.crop else { return }
        setSharedCrop(framing(aspect: ratio, zoom: zoom(of: crop, aspect: aspect), centerX: crop.x + crop.width / 2, centerY: crop.y + crop.height / 2))
        aspect = ratio
    }
    /// Deltas are in displayed source coordinates, normalized to its full width/height.
    public mutating func panSelected(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite, let index = selectedIndex else { return }
        var crop = clips[index].crop
        crop.x = min(1 - crop.width, max(0, crop.x + dx))
        crop.y = min(1 - crop.height, max(0, crop.y + dy))
        setSharedCrop(crop)
    }
    public mutating func zoomSelected(factor: Double) throws {
        guard factor.isFinite, factor > 0 else { throw VideoQuickError("Масштаб должен быть положительным.") }
        guard let index = selectedIndex else { return }
        let crop = clips[index].crop
        let newZoom = min(8, max(1, selectedZoom * factor))
        setSharedCrop(framing(aspect: aspect, zoom: newZoom, centerX: crop.x + crop.width / 2, centerY: crop.y + crop.height / 2))
    }
    private mutating func setSharedCrop(_ crop: CropRect) {
        for index in clips.indices { clips[index].crop = crop }
    }
    public func sourceTime(at outputTime: Double) -> Double {
        let time = outputTime.isNaN ? 0 : min(duration, max(0, outputTime))
        var cursor = 0.0
        for clip in clips {
            if time < cursor + clip.duration { return clip.start + time - cursor }
            cursor += clip.duration
        }
        return clips.last?.end ?? 0
    }
    public func outputTime(atSourceTime sourceTime: Double, movingForward: Bool = true) -> Double {
        let source = sourceTime.isFinite ? min(sourceDuration, max(0, sourceTime)) : 0
        var cursor = 0.0
        for (index, clip) in clips.enumerated() {
            if source < clip.start {
                if movingForward || index == 0 { return cursor }
                let previous = clips[index - 1]
                return max(0, cursor - min(frameDuration / 2, previous.duration / 2))
            }
            if source < clip.end { return cursor + source - clip.start }
            cursor += clip.duration
        }
        return max(0, duration - min(frameDuration / 2, (clips.last?.duration ?? 0) / 2))
    }
    public func outputStart(of id: UUID) -> Double {
        var cursor = 0.0
        for clip in clips {
            if clip.id == id { return cursor }
            cursor += clip.duration
        }
        return cursor
    }
    private var selectedIndex: Int? { clips.firstIndex { $0.id == selectedID } }
    private var tolerance: Double { max(0.000000001, frameDuration * 0.000001) }
    private func snapped(_ time: Double) -> Double {
        // The real source end may include a partial frame; never extend past it.
        min(sourceDuration, max(0, (time / frameDuration).rounded() * frameDuration))
    }
    private func cover(aspect: Double) -> (width: Double, height: Double) {
        aspect <= sourceAspect ? (aspect / sourceAspect, 1) : (1, sourceAspect / aspect)
    }
    private func zoom(of crop: CropRect, aspect: Double) -> Double {
        min(8, max(1, cover(aspect: aspect).width / crop.width))
    }
    private func framing(aspect: Double, zoom: Double, centerX: Double, centerY: Double) -> CropRect {
        let base = cover(aspect: aspect)
        let width = base.width / zoom, height = base.height / zoom
        return CropRect(x: min(1 - width, max(0, centerX - width / 2)), y: min(1 - height, max(0, centerY - height / 2)), width: width, height: height)
    }
}
