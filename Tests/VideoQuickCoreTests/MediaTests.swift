import XCTest
import AVFoundation
import CoreVideo
@testable import VideoQuickCore

final class MediaTests: XCTestCase {
    func testRestrictiveACLIsCopiedToResult() async throws {
        let source = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        _ = try runMediaTool("/bin/chmod", ["+a", "everyone deny write", source.path])
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1)) { _ in }
        let acl = try runMediaTool("/bin/ls", ["-le", output.path])
        XCTAssertTrue(acl.contains("group:everyone deny write"), acl)
    }
    func testPlaybackEnabledFlagIsPreserved() async throws {
        let source = try await makeFixture(enabled: false)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1)) { _ in }
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let enabled = try await tracks[0].load(.isEnabled)
        XCTAssertFalse(enabled)
    }
    func testAlternativeAudioIsRejectedRatherThanMixingLanguages() async throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw XCTSkip("ffmpeg fixture generator unavailable") }
        let video = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        let source = video.deletingLastPathComponent().appendingPathComponent("languages.mov")
        _ = try runMediaTool(ffmpeg, ["-v", "error", "-i", video.path, "-f", "lavfi", "-i", "sine=frequency=440", "-f", "lavfi", "-i", "sine=frequency=880", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-t", "2", "-c:v", "copy", "-c:a", "aac", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=rus", source.path])
        for edits in [EditPlan(), EditPlan(metadataPolicy: .discard)] {
            do { _ = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: edits)) { _ in }; XCTFail("Alternative audio must not become simultaneous tracks, including editor saves") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Альтернативные"), error.localizedDescription) }
        }
        let muted = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: EditPlan(mute: true, metadataPolicy: .discard))) { _ in }
        let mutedTypes = try await AVURLAsset(url: muted).load(.tracks).map(\.mediaType)
        XCTAssertEqual(mutedTypes, [.video])
    }
    func testRestrictivePermissionsAndQuarantineArePreserved() async throws {
        let source = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let quarantine = Array("0081;00000000;VideoQuick;".utf8)
        let set = quarantine.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(set, 0)
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1)) { _ in }
        let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
        let size = getxattr(output.path, "com.apple.quarantine", nil, 0, 0, 0)
        XCTAssertEqual(size, quarantine.count)
    }
    func testTimedChapterMetadataIsRejectedBeforeTimeEdits() throws {
        func atom(_ type: String, _ data: Data) -> Data {
            var size = UInt32(data.count + 8).bigEndian
            return withUnsafeBytes(of: &size) { Data($0) } + Data(type.utf8) + data
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: path) }
        try atom("moov", atom("udta", atom("chpl", Data(repeating: 0, count: 12)))).write(to: path)
        XCTAssertThrowsError(try ContainerMetadata.validateTimeEdits(source: path))
    }
    func testAllPresetsBothContainersPreserveAudioAndSource() async throws {
        let ffmpeg = ProcessInfo.processInfo.environment["VIDEOQUICK_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw XCTSkip("Install ffmpeg to generate audio integration fixtures.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for container in ["mov", "mp4"] {
            let source = folder.appendingPathComponent("Тест со звуком.\(container)")
            _ = try runMediaTool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2", "-c:v", "libx264", "-b:v", "8M", "-c:a", "aac", "-metadata", "title=Audio test", source.path])
            let original = try Data(contentsOf: source)
            let audioHash = try runMediaTool(ffmpeg, ["-v", "error", "-i", source.path, "-map", "0:a", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
            for bitrate in Bitrate.allCases {
                let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: bitrate)) { _ in }
                let info = try await MediaInspector.inspect(output)
                XCTAssertEqual(info.width, 640); XCTAssertEqual(info.height, 360)
                XCTAssertEqual(info.duration, 2, accuracy: 0.06)
                let outputHash = try runMediaTool(ffmpeg, ["-v", "error", "-i", output.path, "-map", "0:a", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
                XCTAssertEqual(outputHash, audioHash, "Audio was re-encoded at \(bitrate.label)")
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }
    func testConversionPreservesContainerRotationMetadataAndOriginal() async throws {
        let source = try await makeFixture(rotated: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let before = try Data(contentsOf: source)
        let result = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps3)) { _ in }
        let info = try await MediaInspector.inspect(result)
        XCTAssertEqual(result.pathExtension, "mov")
        XCTAssertEqual(info.width, 320); XCTAssertEqual(info.height, 240)
        XCTAssertEqual(info.displayWidth, 240); XCTAssertEqual(info.displayHeight, 320)
        XCTAssertEqual(info.duration, 2, accuracy: 0.06)
        let title = try await AVURLAsset(url: result).load(.metadata).first { $0.commonKey == .commonKeyTitle }?.stringValue
        XCTAssertEqual(title, "VideoQuick fixture")
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testTrimCutCropAndMuteExportTheEditedTimeline() async throws {
        let source = try await makeFixture(rotated: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let edits = EditPlan(trimStart: 0.2, trimEnd: 1.8, cutStart: 0.6, cutEnd: 1.0, mute: true, crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: edits)) { _ in }
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.displayWidth, 120); XCTAssertEqual(info.displayHeight, 160)
        XCTAssertEqual(info.duration, 1.2, accuracy: 0.06)
        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }
    func testHEVCCodecIsPreservedAndCancellationLeavesNoOutput() async throws {
        let source = try await makeFixture(codec: .hevc)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps5)) { _ in }
        let codec = try await MediaInspector.inspect(output).codec
        XCTAssertEqual(codec, "HEVC")
        let task = Task { try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps20)) { _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Wrong cancellation: \(error)") }
        let names = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.contains("videoquick-") })
    }
}

func runMediaTool(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
    try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); let errorData = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw VideoQuickError(String(decoding: errorData, as: UTF8.self)) }
    return String(decoding: data, as: UTF8.self)
}

func makeFixture(codec: AVVideoCodecType = .h264, rotated: Bool = false, enabled: Bool = true) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Ролик с пробелом.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let metadata = AVMutableMetadataItem(); metadata.identifier = .quickTimeMetadataTitle; metadata.value = "VideoQuick fixture" as NSString
    writer.metadata = [metadata]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    input.marksOutputTrackAsEnabled = enabled
    if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for frame in 0..<50 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pixel: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
        let buffer = pixel!
        CVPixelBufferLockBaseAddress(buffer, [])
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<240 { for x in 0..<320 {
            let p = base + y * row + x * 4
            p[0] = UInt8((x + frame * 3) % 256); p[1] = UInt8((y * 2 + frame) % 256); p[2] = UInt8((x + y + frame * 5) % 256); p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 25)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
    input.markAsFinished(); await writer.finishWriting()
    if let error = writer.error { throw error }
    return url
}
