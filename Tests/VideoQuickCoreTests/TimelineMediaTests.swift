import XCTest
import AVFoundation
import CoreGraphics
@testable import VideoQuickCore

final class TimelineMediaTests: XCTestCase {
    @MainActor func testHistoryRecordsSourceVideoBitrateFromMetadata() async throws {
        let source = try await twoColorFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(samples); XCTAssertTrue(reader.startReading())
        var bytes = 0
        while let sample = samples.copyNextSampleBuffer() { bytes += CMSampleBufferGetTotalSampleSize(sample) }
        let duration = try await track.load(.timeRange).duration.seconds
        let expected = Double(bytes) * 8 / duration / 1_000_000
        let queue = ConversionQueue(storeURL: source.deletingLastPathComponent().appendingPathComponent("queue.json"), exporter: MediaExporter())
        try queue.enqueue(ConversionRequest(action: .convert, files: [source], bitrate: .mbps1))
        for _ in 0..<300 where queue.hasWork { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(queue.jobs.first?.state, .completed)
        let row = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue.jobs[0])) as? [String: Any])
        let recorded = try XCTUnwrap((row["sourceBitrateMbps"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(recorded, expected, accuracy: max(0.0001, expected * 0.01))
    }
    func testFragmentCropsUseTheirOwnSourcePositionOnOneCanvasInPreviewAndExport() async throws {
        let source = try await twoColorFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let original = try Data(contentsOf: source)
        let edits = EditPlan(clips: [
            ClipEdit(start: 0, duration: 0.8, crop: CropRect(x: 0, y: 0, width: 0.5, height: 1)),
            ClipEdit(start: 1.2, duration: 0.8, crop: CropRect(x: 0.75, y: 0.25, width: 0.25, height: 0.5))
        ], outputAspect: 1)
        let previewAsset = try await VideoComposition.make(asset: AVURLAsset(url: source), edits: edits)
        let preview = try await VideoComposition.renderComposition(asset: previewAsset, edits: edits)
        XCTAssertEqual(preview?.renderSize, CGSize(width: 160, height: 160))
        let previewLeft = try await centerPixel(asset: previewAsset, composition: preview, time: 0.4)
        let previewRight = try await centerPixel(asset: previewAsset, composition: preview, time: 1.2)
        XCTAssertGreaterThan(previewLeft.red, previewLeft.blue + 150)
        XCTAssertGreaterThan(previewRight.blue, previewRight.red + 150)
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: edits)) { _ in }
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.width, 160)
        XCTAssertEqual(info.height, 160)
        XCTAssertEqual(info.duration, 1.6, accuracy: 0.04)
        XCTAssertEqual(info.transform, .identity)
        let outputAsset = AVURLAsset(url: output)
        let left = try await centerPixel(asset: outputAsset, time: 0.4)
        let right = try await centerPixel(asset: outputAsset, time: 1.2)
        XCTAssertGreaterThan(left.red, left.blue + 150)
        XCTAssertGreaterThan(right.blue, right.red + 150)
        let metadata = try await outputAsset.load(.metadata)
        let title = try await metadata.first { $0.commonKey == .commonKeyTitle }?.load(.stringValue)
        XCTAssertEqual(title, "Independent red and blue fixture")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testFragmentCropCoordinatesFollowDisplayedRotation() async throws {
        let source = try await twoColorFixture(rotated: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let edits = EditPlan(clips: [
            ClipEdit(start: 0, duration: 1, crop: CropRect(x: 0, y: 0, width: 1, height: 0.5)),
            ClipEdit(start: 1, duration: 1, crop: CropRect(x: 0, y: 0.5, width: 1, height: 0.5))
        ], outputAspect: 1)
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: edits)) { _ in }
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.width, 160); XCTAssertEqual(info.height, 160)
        XCTAssertEqual(info.transform, .identity)
        let asset = AVURLAsset(url: output)
        let top = try await centerPixel(asset: asset, time: 0.4)
        let bottom = try await centerPixel(asset: asset, time: 1.4)
        XCTAssertGreaterThan(top.red, top.blue + 150)
        XCTAssertGreaterThan(bottom.blue, bottom.red + 150)
    }

    func testSplitOnlyDoesNotTriggerTemporalTimecodeRefusal() async throws {
        let ffmpeg = ProcessInfo.processInfo.environment["VIDEOQUICK_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw XCTSkip("ffmpeg required for timecode fixture") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("timecode.mov")
        _ = try runMediaTool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "color=c=red:size=320x160:rate=25", "-t", "2", "-c:v", "libx264", "-timecode", "01:02:03:04", source.path])
        let before = try Data(contentsOf: source)
        let sourceAsset = AVURLAsset(url: source)
        let sourceVideos = try await sourceAsset.loadTracks(withMediaType: .video)
        let sourceVideo = try XCTUnwrap(sourceVideos.first)
        let sourceLinks = try await sourceVideo.loadAssociatedTracks(ofType: .timecode)
        let edits = EditPlan(clips: [ClipEdit(start: 0, duration: 1), ClipEdit(start: 1, duration: 1)], outputAspect: 2)
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: edits)) { _ in }
        let outputAsset = AVURLAsset(url: output)
        defer { withExtendedLifetime((sourceAsset, outputAsset)) {} }
        let tracks = try await outputAsset.load(.tracks)
        let timecode = try XCTUnwrap(tracks.first { $0.mediaType == .timecode })
        let linked = try await XCTUnwrap(tracks.first { $0.mediaType == .video }).loadAssociatedTracks(ofType: .timecode)
        XCTAssertEqual(linked.count, sourceLinks.count)
        if !sourceLinks.isEmpty { XCTAssertEqual(linked.map(\.trackID), [timecode.trackID]) }
        let timecodeFormats = try await timecode.load(.formatDescriptions)
        XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(try XCTUnwrap(timecodeFormats.first)), 25)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let trimmed = EditPlan(clips: [ClipEdit(start: 0.2, duration: 0.8), ClipEdit(start: 1, duration: 1)], outputAspect: 2)
        do {
            _ = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: trimmed)) { _ in }
            XCTFail("Temporal fragment edits need explicit timecode retiming support")
        } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("таймкод"), error.localizedDescription) }
    }
}

private func twoColorFixture(rotated: Bool = false) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("red-left-blue-right.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let title = AVMutableMetadataItem(); title.identifier = .quickTimeMetadataTitle; title.value = "Independent red and blue fixture" as NSString
    writer.metadata = [title]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 160])
    if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 0) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 160])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<50 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        let row = CVPixelBufferGetBytesPerRow(pixel)
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<160 { for x in 0..<320 {
            let p = base + y * row + x * 4
            p[0] = x < 160 ? 0 : 255; p[1] = 0; p[2] = x < 160 ? 255 : 0; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 25)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
    input.markAsFinished(); await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}

private func centerPixel(asset: AVAsset, composition: AVVideoComposition? = nil, time: Double) async throws -> (red: Int, blue: Int) {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.videoComposition = composition
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
    var rgba = [UInt8](repeating: 0, count: 4)
    try rgba.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileReadUnknown) }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
    }
    return (Int(rgba[0]), Int(rgba[2]))
}
