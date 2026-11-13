import AVFoundation

public enum VideoComposition {
    /// `asset` is the retained timeline returned by `make`; crop coordinates remain
    /// normalized to the displayed source, while instructions use output time.
    public static func renderComposition(asset: AVAsset, edits: EditPlan) async throws -> AVVideoComposition? {
        guard let clips = edits.clips else {
            if let crop = edits.crop { return try await cropComposition(asset: asset, crop: crop) }
            return nil
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !clips.isEmpty, edits.crop == nil, tracks.count == 1, let track = tracks.first else { throw VideoQuickError("Проверьте фрагменты и область кадрирования.") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let sourceWidth = abs(bounds.width), sourceHeight = abs(bounds.height)
        guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0 else { throw VideoQuickError("Не удалось определить размер кадра.") }
        let sourceAspect = sourceWidth / sourceHeight
        let ratio = edits.outputAspect ?? sourceAspect * clips[0].crop.width / clips[0].crop.height
        let duration = try await asset.load(.duration)
        guard ratio.isFinite, ratio > 0, duration.seconds.isFinite,
              abs(clips.reduce(0) { $0 + $1.duration } - duration.seconds) < 0.00001,
              clips.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.crop.isValid && abs(sourceAspect * $0.crop.width / $0.crop.height / ratio - 1) < 0.00001 }) else {
            throw VideoQuickError("Кадрирование фрагментов должно соответствовать общему соотношению сторон.")
        }
        let full = CropRect(x: 0, y: 0, width: 1, height: 1)
        if clips.allSatisfy({ $0.crop == full }), abs(ratio / sourceAspect - 1) < 0.00001 { return nil }
        let canvasWidth = min(sourceWidth, sourceHeight * ratio)
        let canvasHeight = min(sourceHeight, sourceWidth / ratio)
        guard canvasWidth >= 2, canvasHeight >= 2 else { throw VideoQuickError("Выбранное соотношение сторон даёт слишком узкий кадр.") }
        let video = AVMutableVideoComposition()
        video.renderSize = CGSize(width: floor(canvasWidth / 2) * 2, height: floor(canvasHeight / 2) * 2)
        video.sourceTrackIDForFrameTiming = track.trackID
        let nativeFrame = try await track.load(.minFrameDuration)
        let fps = try await track.load(.nominalFrameRate)
        video.frameDuration = nativeFrame.isNumeric && nativeFrame > .zero ? nativeFrame : CMTime(seconds: 1 / Double(max(1, fps)), preferredTimescale: 600_000)
        var cursor = CMTime.zero
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (index, clip) in clips.enumerated() {
            let instruction = AVMutableVideoCompositionInstruction()
            let clipDuration = index == clips.count - 1 ? duration - cursor : CMTime(seconds: clip.duration, preferredTimescale: 600_000)
            instruction.timeRange = CMTimeRange(start: cursor, duration: clipDuration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let translation = CGAffineTransform(translationX: -bounds.minX - sourceWidth * clip.crop.x, y: -bounds.minY - sourceHeight * clip.crop.y)
            let scale = CGAffineTransform(scaleX: video.renderSize.width / (sourceWidth * clip.crop.width), y: video.renderSize.height / (sourceHeight * clip.crop.height))
            layer.setTransform(transform.concatenating(translation).concatenating(scale), at: cursor)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + clipDuration
        }
        video.instructions = instructions
        return video
    }
    public static func make(asset: AVAsset, edits: EditPlan) async throws -> AVAsset {
        let duration = try await asset.load(.duration).seconds
        let ranges = try edits.retainedRanges(duration: duration)
        let discardMetadata = edits.metadataPolicy == .discard
        if ranges == [TimeSpan(start: 0, duration: duration)], !edits.mute, !discardMetadata { return asset }
        let composition = AVMutableComposition()
        for source in try await asset.load(.tracks) {
            if discardMetadata && source.mediaType != .video && source.mediaType != .audio { continue }
            if edits.mute && source.mediaType == .audio { continue }
            guard let target = composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: source.trackID) else { throw VideoQuickError("Нельзя сохранить дорожку \(source.mediaType.rawValue) при редактировании.") }
            target.preferredTransform = try await source.load(.preferredTransform)
            target.languageCode = try await source.load(.languageCode)
            target.extendedLanguageTag = try await source.load(.extendedLanguageTag)
            let available = try await source.load(.timeRange)
            var cursor = CMTime.zero
            for range in ranges {
                let timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600_000), duration: CMTime(seconds: range.duration, preferredTimescale: 600_000))
                let intersection = CMTimeRangeGetIntersection(available, otherRange: timeRange)
                if intersection.duration > .zero {
                    let offset = intersection.start - timeRange.start
                    try target.insertTimeRange(intersection, of: source, at: cursor + offset)
                }
                cursor = cursor + timeRange.duration
            }
        }
        return composition
    }
    public static func cropComposition(asset: AVAsset, crop: CropRect) async throws -> AVVideoComposition {
        guard crop.isValid, let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoQuickError("Проверьте область кадрирования.") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let width = max(2, Int((abs(bounds.width) * crop.width / 2).rounded(.down)) * 2)
        let height = max(2, Int((abs(bounds.height) * crop.height / 2).rounded(.down)) * 2)
        let video = AVMutableVideoComposition()
        video.renderSize = CGSize(width: width, height: height)
        video.sourceTrackIDForFrameTiming = track.trackID
        let fps = try await track.load(.nominalFrameRate)
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let translation = CGAffineTransform(translationX: -bounds.minX - abs(bounds.width) * crop.x, y: -bounds.minY - abs(bounds.height) * crop.y)
        layer.setTransform(transform.concatenating(translation), at: .zero)
        instruction.layerInstructions = [layer]; video.instructions = [instruction]
        return video
    }
    @MainActor public static func playerItem(url: URL, edits: EditPlan) async throws -> AVPlayerItem {
        let asset = try await make(asset: AVURLAsset(url: url), edits: edits)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = try await renderComposition(asset: asset, edits: edits)
        return item
    }
}
