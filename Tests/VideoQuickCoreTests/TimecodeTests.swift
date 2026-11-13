import XCTest
import AVFoundation
@testable import VideoQuickCore

final class TimecodeTests: XCTestCase {
    func testCameraTimecodeAndBothAssociationsSurviveConversion() async throws {
        let source = try await cameraFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let before = try Data(contentsOf: source)
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps3)) { _ in }
        let outputAsset = AVURLAsset(url: output)
        defer { withExtendedLifetime(outputAsset) {} }
        let tracks = try await outputAsset.load(.tracks)
        XCTAssertEqual(tracks.map(\.mediaType), [.video, .audio, .timecode])
        let timecode = try XCTUnwrap(tracks.first { $0.mediaType == .timecode })
        for track in tracks where track.mediaType != .timecode {
            let linked = try await track.loadAssociatedTracks(ofType: .timecode)
            XCTAssertEqual(linked.map(\.trackID), [timecode.trackID])
        }
        let enabled = try await timecode.load(.isEnabled)
        XCTAssertTrue(enabled)
        let bytes = try await timecodeBytes(output)
        XCTAssertEqual(bytes, Data([0, 1, 107, 151])) // 01:02:03:04 at 25 fps = 93079.
        let formats = try await timecode.load(.formatDescriptions)
        XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(formats[0]), 25)
        XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameDuration(formats[0]).seconds, 0.04, accuracy: 0.000001)
        let ffmpeg = ProcessInfo.processInfo.environment["VIDEOQUICK_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        let options = ["-v", "error", "-map", "0:a", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"]
        XCTAssertEqual(try runMediaTool(ffmpeg, ["-i", source.path] + options), try runMediaTool(ffmpeg, ["-i", output.path] + options))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testEditorTrimDropsCameraTimecodeAndMetadataWhileKeepingCroppedVideoAndAudio() async throws {
        let source = try await cameraFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let before = try Data(contentsOf: source)
        // Persisted editor policy is deliberately read through the same Codable boundary as a queued job.
        let edits = try JSONDecoder().decode(EditPlan.self, from: Data(#"{"trimStart":0,"mute":false,"metadataPolicy":"discard","clips":[{"id":"00000000-0000-0000-0000-000000000001","start":0.2,"duration":1.2,"crop":{"x":0.125,"y":0,"width":0.75,"height":1}}],"outputAspect":1}"#.utf8))
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: edits)) { _ in }
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.load(.tracks)
        XCTAssertEqual(tracks.map(\.mediaType), [.video, .audio])
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.width, 240); XCTAssertEqual(info.height, 240)
        XCTAssertEqual(info.duration, 1.2, accuracy: 0.04)
        let metadata = try await asset.load(.metadata)
        XCTAssertFalse(metadata.contains { $0.commonKey == .commonKeyTitle })
        for track in tracks { let associations = try await track.load(.availableTrackAssociationTypes); XCTAssertTrue(associations.isEmpty) }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testFullRangeEditorSaveDropsTimecodeAndSourceTitle() async throws {
        let source = try await cameraFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: EditPlan(metadataPolicy: .discard))) { _ in }
        let asset = AVURLAsset(url: output)
        let types = try await asset.load(.tracks).map(\.mediaType)
        XCTAssertEqual(types, [.video, .audio])
        let metadata = try await asset.load(.metadata)
        XCTAssertFalse(metadata.contains { $0.commonKey == .commonKeyTitle })
    }
    func testMutedEditorTrimDropsTimecodeAndAudio() async throws {
        let source = try await cameraFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: EditPlan(trimStart: 0.2, trimEnd: 1.8, mute: true, metadataPolicy: .discard))) { _ in }
        let types = try await AVURLAsset(url: output).load(.tracks).map(\.mediaType)
        XCTAssertEqual(types, [.video])
        let info = try await MediaInspector.inspect(output)
        XCTAssertEqual(info.duration, 1.6, accuracy: 0.04)
    }
    func testEditorTrimDropsChaptersInsteadOfBlockingTimeEdits() async throws {
        let base = try await cameraFixture()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let source = base.deletingLastPathComponent().appendingPathComponent("chapters.mov")
        let chapters = base.deletingLastPathComponent().appendingPathComponent("chapters.txt")
        try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=Camera chapter\n".write(to: chapters, atomically: true, encoding: .utf8)
        let ffmpeg = ProcessInfo.processInfo.environment["VIDEOQUICK_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        _ = try runMediaTool(ffmpeg, ["-v", "error", "-i", base.path, "-i", chapters.path, "-map", "0", "-map_chapters", "1", "-c", "copy", source.path])
        XCTAssertThrowsError(try ContainerMetadata.validateTimeEdits(source: source))
        let before = try Data(contentsOf: source)
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: EditPlan(trimStart: 0.2, trimEnd: 1.8, metadataPolicy: .discard))) { _ in }
        XCTAssertNoThrow(try ContainerMetadata.validateTimeEdits(source: output))
        let types = try await AVURLAsset(url: output).load(.tracks).map(\.mediaType)
        XCTAssertEqual(types, [.video, .audio])
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testMuteRetainsTheVideoTimecodeAssociation() async throws {
        let source = try await cameraFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: EditPlan(mute: true))) { _ in }
        let outputAsset = AVURLAsset(url: output)
        defer { withExtendedLifetime(outputAsset) {} }
        let tracks = try await outputAsset.load(.tracks)
        XCTAssertEqual(tracks.map(\.mediaType), [.video, .timecode])
        let linked = try await tracks[0].loadAssociatedTracks(ofType: .timecode)
        XCTAssertEqual(linked.map(\.trackID), [tracks[1].trackID])
        let bytes = try await timecodeBytes(output)
        XCTAssertEqual(bytes, Data([0, 1, 107, 151]))
    }
    func testTimeEditsRequireTimecodeRetimingInsteadOfCopyingWrongStart() async throws {
        let source = try await cameraFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        do {
            _ = try await MediaExporter().export(ConversionJob(sourceURL: source, bitrate: .mbps1, edits: EditPlan(trimStart: 0.2, trimEnd: 1.8))) { _ in }
            XCTFail("Time edits must not publish an unchanged timecode start")
        } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("таймкод"), error.localizedDescription) }
    }
}

private func cameraFixture() async throws -> URL {
    let ffmpeg = ProcessInfo.processInfo.environment["VIDEOQUICK_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
    guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw XCTSkip("ffmpeg is required to generate camera fixtures") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("camera.mov")
    _ = try runMediaTool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2", "-c:v", "libx264", "-c:a", "pcm_s16be", "-timecode", "01:02:03:04", "-metadata", "title=Camera original", source.path])
    let tracks = try await AVURLAsset(url: source).load(.tracks)
    let audioID = try XCTUnwrap(tracks.first { $0.mediaType == .audio }).trackID
    let timecodeID = try XCTUnwrap(tracks.first { $0.mediaType == .timecode }).trackID
    // Construct the independent camera fixture: audio also references tmcd,
    // and the camera marks the timecode track enabled (FFmpeg defaults to off).
    let handle = try FileHandle(forUpdating: source); defer { try? handle.close() }
    let end = try handle.seekToEnd()
    let moov = try XCTUnwrap(ContainerMetadata.atoms(handle, start: 0, end: end).first { $0.type == "moov" })
    XCTAssertEqual(moov.end, end)
    var movie = Data()
    for child in try ContainerMetadata.atoms(handle, start: moov.start + moov.header, end: moov.end) {
        guard child.type == "trak" else { movie += try ContainerMetadata.read(handle, atom: child); continue }
        let children = try ContainerMetadata.atoms(handle, start: child.start + child.header, end: child.end)
        let header = try XCTUnwrap(children.first { $0.type == "tkhd" })
        let bytes = try ContainerMetadata.read(handle, atom: header)
        let offset = Int(header.header) + (bytes[Int(header.header)] == 1 ? 20 : 12)
        let id = Int32(ContainerMetadata.number(bytes[offset..<(offset + 4)]))
        var payload = Data()
        for item in children {
            var data = try ContainerMetadata.read(handle, atom: item)
            if id == timecodeID && item.type == "tkhd" { data[Int(item.header) + 3] |= 1 }
            payload += data
        }
        if id == audioID {
            var target = timecodeID.bigEndian
            payload += box("tref", box("tmcd", withUnsafeBytes(of: &target) { Data($0) }))
        }
        movie += box("trak", payload)
    }
    let replacement = box("moov", movie)
    try handle.seek(toOffset: moov.start); try handle.write(contentsOf: replacement); try handle.truncate(atOffset: moov.start + UInt64(replacement.count))
    return source
}
private func box(_ name: String, _ payload: Data) -> Data {
    var size = UInt32(payload.count + 8).bigEndian
    return withUnsafeBytes(of: &size) { Data($0) } + Data(name.utf8) + payload
}
private func timecodeBytes(_ url: URL) async throws -> Data {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .timecode)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil); reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    var result = Data()
    while let sample = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        XCTAssertEqual(status, noErr); result += data
    }
    if let error = reader.error { throw error }
    return result
}
