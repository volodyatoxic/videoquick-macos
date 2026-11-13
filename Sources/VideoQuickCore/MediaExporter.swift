import AVFoundation
import VideoToolbox

public struct MediaExporter: Exporting {
    public init() {}
    public func export(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let info = try await MediaInspector.inspect(job.sourceURL)
        guard !info.isHDR, info.bitDepth <= 8 else { throw VideoQuickError("HDR / 10-bit / Dolby Vision пока не экспортируются: сохранение цвета и динамических метаданных ещё не проверено. Исходник не изменён.") }
        let preserveMetadata = job.edits.metadataPolicy != .discard
        let source = AVURLAsset(url: job.sourceURL)
        let sourceTracks = try await source.load(.tracks)
        for characteristic in try await source.load(.availableMediaCharacteristicsWithMediaSelectionOptions) {
            // Selection groups affect audible content, not just metadata. Never turn alternatives into simultaneous sound.
            if !preserveMetadata && (job.edits.mute || characteristic != .audible) { continue }
            if let group = try await source.loadMediaSelectionGroup(for: characteristic), group.options.count > 1 { throw VideoQuickError("Альтернативные группы дорожек пока не поддерживаются: их условия воспроизведения должны сохраниться.") }
        }
        if preserveMetadata {
            let hasTimeEdits = try job.edits.retainedRanges(duration: info.duration) != [TimeSpan(start: 0, duration: info.duration)]
            try await TrackAssociations.validate(sourceTracks, hasTimeEdits: hasTimeEdits)
            if hasTimeEdits { try ContainerMetadata.validateTimeEdits(source: job.sourceURL) }
        }
        let asset = try await VideoComposition.make(asset: source, edits: job.edits)
        let renderComposition = try await VideoComposition.renderComposition(asset: asset, edits: job.edits)
        let duration = try await asset.load(.duration)
        let work = try FileSecurity.workDirectory(source: job.sourceURL, id: job.id)
        defer { try? FileManager.default.removeItem(at: work) }
        let temporary = work.appendingPathComponent("result").appendingPathExtension(job.sourceURL.pathExtension)
        let fileType: AVFileType = job.sourceURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: fileType)
        let sourceMetadata: [AVMetadataItem] = preserveMetadata ? try await source.load(.metadata) : []
        writer.metadata = sourceMetadata
        struct Channel { let output: AVAssetReaderOutput; let input: AVAssetWriterInput; let video: Bool; var finished = false }
        var channels: [Channel] = []
        var inputsBySourceID: [CMPersistentTrackID: AVAssetWriterInput] = [:]
        var expectedWidth = info.width, expectedHeight = info.height
        for track in try await asset.load(.tracks) {
            let original = sourceTracks.first { $0.trackID == track.trackID } ?? track
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
            if track.mediaType == .video {
                var settings: [String: Any] = [AVVideoCodecKey: info.codec == "HEVC" ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: info.width, AVVideoHeightKey: info.height,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: job.bitrate.bitsPerSecond],
                    AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]]
                let formats = try await original.load(.formatDescriptions)
                if let format = formats.first {
                    let ext = CMFormatDescriptionGetExtensions(format).map { $0 as NSDictionary } ?? NSDictionary()
                    var colors: [String: Any] = [:]
                    for (cm, av) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey), (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey), (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] { if let value = ext[cm] { colors[av] = value } }
                    if !colors.isEmpty { settings[AVVideoColorPropertiesKey] = colors }
                    if renderComposition == nil {
                        if let aperture = ext[kCMFormatDescriptionExtension_CleanAperture] as? [String: Any] {
                            var values: [String: Any] = [:]
                            for (cm, av) in [(kCMFormatDescriptionKey_CleanApertureWidth, AVVideoCleanApertureWidthKey), (kCMFormatDescriptionKey_CleanApertureHeight, AVVideoCleanApertureHeightKey), (kCMFormatDescriptionKey_CleanApertureHorizontalOffset, AVVideoCleanApertureHorizontalOffsetKey), (kCMFormatDescriptionKey_CleanApertureVerticalOffset, AVVideoCleanApertureVerticalOffsetKey)] { values[av] = aperture[cm as String] }
                            if values.count == 4 { settings[AVVideoCleanApertureKey] = values }
                        }
                        if let aspect = ext[kCMFormatDescriptionExtension_PixelAspectRatio] as? [String: Any], let horizontal = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String], let vertical = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] {
                            settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: horizontal, AVVideoPixelAspectRatioVerticalSpacingKey: vertical]
                        }
                    }
                }
                let pixelSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                if let composition = renderComposition {
                    let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: pixelSettings)
                    videoOutput.videoComposition = composition
                    output = videoOutput
                    expectedWidth = Int(composition.renderSize.width); expectedHeight = Int(composition.renderSize.height)
                    settings[AVVideoWidthKey] = expectedWidth; settings[AVVideoHeightKey] = expectedHeight
                } else { output = AVAssetReaderTrackOutput(track: track, outputSettings: pixelSettings) }
                input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.transform = renderComposition == nil ? info.transform : .identity
            } else {
                let formats = try await track.load(.formatDescriptions)
                output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: formats.first)
            }
            input.expectsMediaDataInRealTime = false
            if preserveMetadata {
                input.metadata = try await original.load(.metadata)
                input.languageCode = try await original.load(.languageCode)
                input.extendedLanguageTag = try await original.load(.extendedLanguageTag)
            }
            input.marksOutputTrackAsEnabled = try await original.load(.isEnabled)
            input.preferredVolume = try await original.load(.preferredVolume)
            if track.mediaType == .timecode { input.mediaTimeScale = try await original.load(.naturalTimeScale) }
            guard reader.canAdd(output), writer.canAdd(input) else { throw VideoQuickError("Нельзя сохранить дорожку \(track.mediaType.rawValue) в исходном формате.") }
            reader.add(output); writer.add(input)
            inputsBySourceID[original.trackID] = input
            channels.append(Channel(output: output, input: input, video: track.mediaType == .video))
        }
        if preserveMetadata { try await TrackAssociations.copy(sourceTracks, inputs: inputsBySourceID) }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? VideoQuickError("Не удалось начать конвертацию.") }
        writer.startSession(atSourceTime: .zero)
        do {
            while channels.contains(where: { !$0.finished }) {
                try Task.checkCancellation()
                if writer.status == .failed || reader.status == .failed { throw writer.error ?? reader.error ?? VideoQuickError("Ошибка обработки видео.") }
                var advanced = false
                for index in channels.indices where !channels[index].finished && channels[index].input.isReadyForMoreMediaData {
                    advanced = true
                    if let sample = channels[index].output.copyNextSampleBuffer() {
                        guard channels[index].input.append(sample) else { throw writer.error ?? VideoQuickError("Не удалось записать дорожку.") }
                        if channels[index].video { progress(min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration.seconds))) }
                    } else { channels[index].input.markAsFinished(); channels[index].finished = true }
                }
                if !advanced { try await Task.sleep(nanoseconds: 1_000_000) }
            }
            guard reader.status != .failed else { throw reader.error ?? VideoQuickError("Ошибка чтения видео.") }
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? VideoQuickError("Не удалось завершить видео.") }
            if preserveMetadata { try ContainerMetadata.preserve(from: job.sourceURL, to: temporary) }
            let result = try await MediaInspector.inspect(temporary)
            guard result.width == expectedWidth, result.height == expectedHeight, abs(result.duration - duration.seconds) <= max(0.08, 2 / Double(max(1, info.nominalFrameRate))), result.codec == info.codec else { throw VideoQuickError("Проверка готового видео обнаружила изменение размера, длительности или кодека.") }
            if renderComposition == nil, result.transform != info.transform { throw VideoQuickError("Не удалось сохранить ориентацию видео.") }
            let outputAsset = AVURLAsset(url: temporary)
            let outputTracks = try await outputAsset.load(.tracks)
            let expectedTypes = try await asset.load(.tracks).map(\.mediaType).map(\.rawValue).sorted()
            guard outputTracks.map(\.mediaType).map(\.rawValue).sorted() == expectedTypes else { throw VideoQuickError("Не удалось сохранить все дорожки.") }
            let originals = sourceTracks.filter { inputsBySourceID[$0.trackID] != nil }
            if preserveMetadata { try await TrackAssociations.verify(source: originals, output: outputTracks) }
            for (original, result) in zip(originals, outputTracks) {
                let enabled = try await original.load(.isEnabled), resultEnabled = try await result.load(.isEnabled)
                let volume = try await original.load(.preferredVolume), resultVolume = try await result.load(.preferredVolume)
                guard original.mediaType == result.mediaType, enabled == resultEnabled, abs(volume - resultVolume) < 0.001 else { throw VideoQuickError("Не удалось сохранить условия воспроизведения дорожек.") }
            }
            if preserveMetadata {
                let outputMetadata = try await outputAsset.load(.metadata)
                for item in sourceMetadata {
                    guard outputMetadata.contains(where: { Self.metadataSignature($0) == Self.metadataSignature(item) }) else { throw VideoQuickError("Не удалось сохранить метаданные \(item.identifier?.rawValue ?? "исходника").") }
                }
                for original in sourceTracks where !(job.edits.mute && original.mediaType == .audio) {
                    let originalMetadata = try await original.load(.metadata)
                    let candidates = outputTracks.filter { $0.mediaType == original.mediaType }
                    var savedMetadata: [AVMetadataItem] = []
                    for track in candidates { savedMetadata += try await track.load(.metadata) }
                    guard originalMetadata.allSatisfy({ item in savedMetadata.contains { Self.metadataSignature($0) == Self.metadataSignature(item) } }) else { throw VideoQuickError("Не удалось сохранить метаданные дорожки.") }
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: job.sourceURL.path)
                if let created = attributes[.creationDate] { try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: temporary.path) }
                let tags = try job.sourceURL.resourceValues(forKeys: [.tagNamesKey]).tagNames
                if let tags, !tags.isEmpty { try (temporary as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
            }
            try FileSecurity.apply(source: job.sourceURL, output: temporary)
            try Task.checkCancellation()
            let final = try OutputPublisher.publish(temporary: temporary, source: job.sourceURL, bitrate: job.bitrate, edited: job.edits.isEdited)
            progress(1)
            return final
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }
    private static func metadataSignature(_ item: AVMetadataItem) -> String {
        "\(item.identifier?.rawValue ?? "\(item.keySpace?.rawValue ?? "")/\(String(describing: item.key))")|\(item.locale?.identifier ?? "")|\(String(describing: item.value))"
    }
}
