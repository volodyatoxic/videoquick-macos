import AppKit
import AVFoundation
import VideoQuickCore

@main struct NativeScrubChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            let document = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            await document.load()
            for _ in 0..<300 where document.player.currentItem?.status != .readyToPlay { try await Task.sleep(nanoseconds: 10_000_000) }
            guard let item = document.player.currentItem, item.status == .readyToPlay, let info = document.info else { throw Failure(description: "Source did not become ready") }
            // Read the decoder's native YUV buffers; an RGB conversion on every
            // 4 MP sample would benchmark the probe instead of native playback.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            item.add(output)
            try await sweep("fresh", document, output, duration: info.duration)
            var leftFrames = 0
            for i in 0..<60 {
                document.trim(start: Double(i) / 60 * info.duration * 0.2, end: info.duration)
                try await Task.sleep(nanoseconds: 16_666_666)
                if i > 0, matches(output, player: document.player, source: document.timeline!.selectedClip!.start) { leftFrames += 1 }
            }
            guard leftFrames >= 40 else { throw Failure(description: "Left trim did not display its changing boundary during the gesture (\(leftFrames)/59)") }
            try await sweep("after left trim", document, output, duration: info.duration)
            var rightFrames = 0
            let trimmedStart = document.timeline!.selectedClip!.start
            for i in 0..<60 {
                document.trim(start: trimmedStart, end: info.duration * (1 - Double(i) / 60 * 0.2))
                try await Task.sleep(nanoseconds: 16_666_666)
                if i > 0, matches(output, player: document.player, source: document.timeline!.selectedClip!.end - document.timeline!.frameDuration) { rightFrames += 1 }
            }
            guard rightFrames >= 40 else { throw Failure(description: "Right trim did not display its changing boundary during the gesture (\(rightFrames)/59)") }
            print("Live trim: left \(leftFrames)/59 and right \(rightFrames)/59 decoded samples follow the moving boundary")
            try await sweep("after right trim", document, output, duration: info.duration)
            guard document.player.currentItem === item else { throw Failure(description: "Trim replaced the source decoder") }
            document.reset(); document.seek(to: 3)
            document.trim(start: 0, end: info.duration)
            guard abs(document.playhead - 3) < 0.01 else { throw Failure(description: "Touching an unchanged trim handle jumps to the other end") }
            let window = EditorScrubWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.editorDocument = document
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -20, wheel3: 0) else { throw Failure(description: "Could not create local scroll event") }
            // This event is called locally, never posted. Give it a deterministic
            // point inside our unshown test window, independent of the real mouse.
            cgEvent.location = CGPoint(x: 100, y: (NSScreen.main?.frame.height ?? 1000) - 100)
            guard let event = NSEvent(cgEvent: cgEvent) else { throw Failure(description: "Could not wrap local scroll event") }
            window.setContentSize(NSSize(width: max(800, event.locationInWindow.x + 200), height: max(450, event.locationInWindow.y + 200)))
            let before = document.playhead
            window.sendEvent(event)
            guard document.playhead == before else { throw Failure(description: "Video wheel input still moved the playhead") }
            let region = NSView(frame: window.contentView!.bounds)
            window.contentView!.addSubview(region); window.timelineScrollRegion = region
            let cursorAfterVideoScroll = document.sourcePlayhead
            window.sendEvent(event)
            guard document.sourcePlayhead == cursorAfterVideoScroll else { throw Failure(description: "Timeline pan was intercepted as playhead scrubbing") }
            let playerView = ScrubPlayerView()
            var fallbackDelta = 0.0; playerView.pan = { dx, _ in fallbackDelta = dx }; playerView.scrollWheel(with: event)
            guard fallbackDelta < 0 else { throw Failure(description: "Trackpad no longer positions the image") }
            document.stop(); window.close()
            print("Native scrub checks passed: decoded frames before/after live trims, stable decoder, unchanged-handle touch, matching leftward scroll routes")
        } catch { fputs("Native scrub check failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func matches(_ output: AVPlayerItemVideoOutput, player: AVPlayer, source: Double) -> Bool {
        var displayed = CMTime.invalid
        return output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &displayed) != nil && abs(displayed.seconds - source) < 0.1
    }
    @MainActor static func sweep(_ label: String, _ document: EditorDocument, _ output: AVPlayerItemVideoOutput, duration: Double) async throws {
        var responsive = 0
        for index in 0..<90 {
            let target = duration * (0.3 + Double(index) / 90 * 0.35)
            document.scrubSource(to: target)
            try await Task.sleep(nanoseconds: 16_666_666)
            var displayed = CMTime.invalid
            if output.copyPixelBuffer(forItemTime: document.player.currentTime(), itemTimeForDisplay: &displayed) != nil,
               abs(displayed.seconds - target) < 0.1 { responsive += 1 }
        }
        print("\(label): \(responsive)/90 decoded samples within 100 ms of requested source time")
        guard responsive >= 60 else { throw Failure(description: "\(label): rendered frames stopped following continuous seeking (\(responsive)/90)") }
        try await Task.sleep(nanoseconds: 150_000_000)
    }
}
