import Foundation
import AppKit
import AVFoundation
import Darwin
import VideoQuickCore

/// Integration checks against the real document, source decoder and AppKit window.
@main struct NativeEditorChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            guard CommandLine.arguments.count == 2 else { throw Failure(description: "Expected synthetic fixture path") }
            let document = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            await document.load()
            guard document.info != nil else { throw Failure(description: document.error ?? "Fixture did not load") }
            try await ready(document, output: 0, source: 0)
            let originalItem = document.player.currentItem
            document.setPreset("9:16")
            for _ in 0..<12 {
                document.change { $0.panSelected(dx: 0.005, dy: 0) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            guard document.player.currentItem === originalItem, originalItem?.videoComposition == nil else {
                throw Failure(description: "Crop gestures rebuild the video rendering pipeline")
            }
            for index in 0..<12 { document.trim(start: Double(index) / 25, end: 11) }
            try await ready(document, output: 0, source: 0.44)
            guard document.player.currentItem === originalItem else { throw Failure(description: "Trimming replaces the visible player item") }
            document.reset()
            document.change { try $0.split(at: 6) }
            let firstID = document.timeline!.clips[0].id
            document.selectClip(firstID); document.seek(to: 5.9)
            document.trim(start: 0, end: 5)
            guard document.timeline?.selectedID == firstID else {
                throw Failure(description: "Shortening a clip switched selection to its neighbor")
            }
            document.trim(start: 0, end: 4.8)
            guard document.timeline?.clips[0].end == 4.8, document.timeline?.clips[1].start == 6 else {
                throw Failure(description: "Repeated trimming changed a different clip")
            }
            document.reset()
            document.change { try $0.split(at: 1); try $0.split(at: 5); try $0.split(at: 6) }
            guard let second = document.timeline?.clips[1] else { throw Failure(description: "Split failed") }
            document.selectClip(second.id); document.seek(to: 4.5); document.deleteSelected()
            try await ready(document, output: 1, source: 5)
            document.setPreset("9:16")
            for index in 0..<30 { document.seek(to: Double(index) / 10) }
            document.seek(to: 3)
            try await ready(document, output: 3, source: 7)
            await document.player.seek(to: CMTime(seconds: 5.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try await ready(document, output: 1.5, source: 5.5)
            document.scrubSource(to: 3, movingForward: true)
            try await ready(document, output: 1, source: 5)
            document.scrubSource(to: 3, movingForward: false)
            try await ready(document, output: 0.98, source: 0.98)
            document.seek(to: 0.8); try await ready(document, output: 0.8, source: 0.8)
            document.scrollScrub(delta: 100, viewportWidth: 1200)
            try await ready(document, output: 1, source: 5)
            document.scrollScrub(delta: -100, viewportWidth: 1200)
            try await ready(document, output: 0.98, source: 0.98)
            document.seek(to: 0.8); try await ready(document, output: 0.8, source: 0.8)
            document.togglePlayback()
            try await Task.sleep(nanoseconds: 750_000_000)
            let crossed = document.player.currentTime().seconds
            guard crossed >= 5, crossed < 6.5, document.playing else {
                throw Failure(description: "Playback crossed removed time or stalled: source \(crossed)s")
            }
            document.seek(to: 7.8); try await ready(document, output: 7.8, source: 11.8)
            document.togglePlayback()
            try await Task.sleep(nanoseconds: 500_000_000)
            guard !document.playing, abs(document.playhead - 8) < 0.05 else { throw Failure(description: "Playback did not stop at final trim") }
            document.togglePlayback(); document.mute = true; document.refreshPreview(); document.stop()
            try await Task.sleep(nanoseconds: 200_000_000)
            guard document.player.rate == 0 else { throw Failure(description: "Closed preview resumed playback") }
            guard document.player.isMuted, document.player.currentItem === originalItem else { throw Failure(description: "Mute replaced decoder or was not applied") }
            let saveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: saveDirectory) }
            let saveQueue = ConversionQueue(storeURL: saveDirectory.appendingPathComponent("queue.json"), exporter: SlowEditorExporter())
            document.save(in: saveQueue, bitrate: .mbps5)
            let frozen = document.plan
            document.split(); document.trim(start: 1, end: 10); document.setPreset("1:1"); document.reset()
            guard !document.canReset else { throw Failure(description: "Reset stayed enabled during export") }
            guard document.plan == frozen else { throw Failure(description: "An active save allowed timeline edits") }
            for _ in 0..<100 where document.saveState.progress == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
            guard document.saveState.isActive, document.saveState.progress > 0, document.saveState.progress < 1,
                  saveQueue.jobs.first?.presentation == .editor,
                  HUDSession(history: saveQueue.jobs).jobIDs.isEmpty else { throw Failure(description: "Editor save did not own inline progress") }
            document.cancelSave()
            try await Task.sleep(nanoseconds: 100_000_000)
            guard !document.saveState.isActive, saveQueue.jobs.first?.state == .cancelled else { throw Failure(description: "Inline cancel failed") }
            document.save(in: saveQueue, bitrate: .mbps3)
            for _ in 0..<100 where document.saveState.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            document.refreshPreview()
            guard document.saveJob?.state == .completed, document.saved else { throw Failure(description: "Inline completion did not restore editor") }
            document.save(in: saveQueue, bitrate: .mbps20)
            for _ in 0..<100 where document.saveState.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            guard document.saveJob?.state == .failed, let exportError = document.saveJob?.error, document.error == exportError else {
                throw Failure(description: "Failed inline save lost the queue error message")
            }
            document.save(in: saveQueue, bitrate: .mbps5)
            let savePath = saveDirectory.appendingPathComponent("queue.json")
            try FileManager.default.removeItem(at: savePath)
            try FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
            document.cancelSave()
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let persistenceError = saveQueue.persistenceError, document.error == persistenceError else {
                throw Failure(description: "Editor hid cancellation persistence failure")
            }
            let anchored = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            await anchored.load(); anchored.seek(to: 3)
            try await ready(anchored, output: 3, source: 3)
            let markerGeometry = TimelineStripGeometry(sourceDuration: 12, width: 1000)
            let originalMarker = markerGeometry.playheadX(sourceTime: anchored.sourcePlayhead, clip: anchored.playheadClip!)
            anchored.trim(start: 1, end: 10)
            guard abs(anchored.timeline!.sourceTime(at: anchored.playhead) - 3) < 0.0001 else { throw Failure(description: "Left trimming moved the stationary source playhead") }
            guard anchored.sourcePlayhead == 3, markerGeometry.playheadX(sourceTime: anchored.sourcePlayhead, clip: anchored.playheadClip!) == originalMarker else { throw Failure(description: "Trim moved the red marker's visual anchor") }
            try await ready(anchored, output: 2, source: 1)
            anchored.trim(start: 1, end: 8)
            try await ready(anchored, output: 2, source: 7.96)
            let keyWindow = EditorScrubWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            keyWindow.isReleasedWhenClosed = false; keyWindow.editorDocument = anchored
            func arrow(_ code: UInt16, shift: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: keyWindow.windowNumber, context: nil, characters: code == 124 ? "\u{f703}" : "\u{f702}", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            }
            keyWindow.sendEvent(arrow(124))
            guard abs(anchored.playhead - 2.04) < 0.0001 else { throw Failure(description: "Right arrow did not step exactly one frame") }
            keyWindow.sendEvent(arrow(123, shift: true))
            try await ready(anchored, output: 1.64, source: 2.64)
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30)); text.string = "123"
            keyWindow.contentView?.addSubview(text); keyWindow.makeFirstResponder(text)
            keyWindow.sendEvent(arrow(124))
            guard abs(anchored.playhead - 1.64) < 0.0001 else { throw Failure(description: "Frame shortcut stole the text field's arrow key") }
            anchored.reset(); anchored.change { try $0.split(at: 1); try $0.split(at: 5) }
            anchored.selectClip(anchored.timeline!.clips[1].id); anchored.deleteSelected(); anchored.seek(to: 0.96)
            anchored.stepPlayhead(frames: 1)
            guard abs(anchored.sourcePlayhead - 5) < 0.0001 else { throw Failure(description: "Frame stepping entered a deleted span") }
            anchored.stepPlayhead(frames: -10)
            try await ready(anchored, output: 0.6, source: 0.6)
            anchored.stop(); keyWindow.close()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let originalViewportSize = window.contentView!.bounds.size
            EditorWindowChrome.configure(window, title: "Synthetic.mov")
            guard window.title == "Synthetic.mov", window.titleVisibility == .hidden, window.standardWindowButton(.closeButton)?.isHidden == true else { throw Failure(description: "Idle titlebar did not hide") }
            EditorWindowChrome.setVisible(true, on: window)
            guard window.titleVisibility == .visible, window.standardWindowButton(.closeButton)?.isHidden == false else { throw Failure(description: "Hovered native titlebar did not appear") }
            let chromeTracker = EditorChromeTracker(frame: window.contentView!.bounds)
            window.contentView!.addSubview(chromeTracker)
            chromeTracker.onHover = { EditorWindowChrome.setVisible($0, on: window) }
            let titlePoint = NSPoint(x: 120, y: window.frame.height - 8)
            guard let titleExit = NSEvent.enterExitEvent(with: .mouseExited, location: titlePoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil) else { throw Failure(description: "Could not create titlebar boundary event") }
            for _ in 0..<40 {
                chromeTracker.mouseEntered(with: titleExit)
                chromeTracker.mouseExited(with: titleExit)
                guard window.titleVisibility == .visible else { throw Failure(description: "Hovering over the titlebar hid chrome while pointer remained inside the window") }
            }
            chromeTracker.updateTrackingAreas()
            let firstTrackingArea = chromeTracker.trackingAreas.first
            for _ in 0..<40 { chromeTracker.updateTrackingAreas() }
            guard chromeTracker.trackingAreas.count == 1, chromeTracker.trackingAreas.first === firstTrackingArea else { throw Failure(description: "Chrome layout recreated its tracking area") }
            guard let outsideExit = NSEvent.enterExitEvent(with: .mouseExited, location: NSPoint(x: -10, y: titlePoint.y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil) else { throw Failure(description: "Could not create window exit event") }
            chromeTracker.mouseExited(with: outsideExit)
            guard window.titleVisibility == .hidden else { throw Failure(description: "Leaving the actual window did not hide chrome") }
            EditorWindowChrome.setVisible(false, on: window)
            guard window.contentView!.bounds.size == originalViewportSize else { throw Failure(description: "Titlebar visibility changed video layout") }
            for index in 0..<40 {
                EditorWindowSizing.apply(to: window, aspect: 9.0 / 16, free: false)
                EditorWindowSizing.apply(to: window, aspect: 9.0 / 16, free: true)
                guard window.contentResizeIncrements == NSSize(width: 1, height: 1) else { throw Failure(description: "Free crop is still aspect constrained") }
                window.setContentSize(NSSize(width: 400 + index * 2, height: 300 + index))
                guard window.frame.width.isFinite, window.frame.height.isFinite else { throw Failure(description: "Invalid free crop window size") }
            }
            window.close()
            print("Native editor checks passed: stable decoder, latest seek, deleted-gap playback, stationary trim cursor/geometry, one/ten-frame shortcuts and text focus, stepping over gaps, 40 window cycles, inline save/cancel/completion/error")
        } catch { fputs("Native editor check failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func ready(_ document: EditorDocument, output: Double, source: Double) async throws {
        for _ in 0..<200 {
            if document.player.currentItem?.status == .readyToPlay,
               abs(document.player.currentTime().seconds - source) < 0.05, abs(document.playhead - output) < 0.05 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if abs(document.player.currentTime().seconds - source) < 0.05 { return }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(description: "Expected output/source \(output)/\(source)s; observed \(document.playhead)/\(document.player.currentTime().seconds)s")
    }
}

/// Deterministic queue progress/cancellation boundary; real media export is covered separately.
private actor SlowEditorExporter: Exporting {
    func export(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        for step in 1...8 {
            try await Task.sleep(nanoseconds: 25_000_000)
            progress(Double(step) / 8)
        }
        if job.bitrate == .mbps20 { throw CocoaError(.fileWriteOutOfSpace) }
        return job.sourceURL.appendingPathExtension("simulated.mov")
    }
}
