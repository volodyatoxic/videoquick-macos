import AppKit
import AVFoundation
import VideoQuickCore

@main struct NativeEditorCommandChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            let document = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])); await document.load()
            guard document.timeline != nil else { throw Failure(description: "Fixture did not load") }
            let resetDocument = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])); await resetDocument.load()
            guard resetDocument.hasAudio, !resetDocument.canReset else { throw Failure(description: "Reset fixture must start pristine with audio") }
            resetDocument.reset()
            guard !resetDocument.editUndoManager.canUndo else { throw Failure(description: "A pristine reset created undo history") }
            resetDocument.seek(to: 3); resetDocument.split(); resetDocument.seek(to: 7); resetDocument.split()
            resetDocument.selectClip(resetDocument.timeline!.clips[1].id); resetDocument.deleteSelected()
            resetDocument.setPreset("1:1"); resetDocument.zoomImage(factor: 1.5)
            resetDocument.panImage(dx: 20, dy: 10, width: 640, height: 360)
            resetDocument.toggleMute(); resetDocument.zoomTimeline(by: 4); resetDocument.seek(to: 1)
            let beforeReset = resetDocument.plan, beforeResetZoom = resetDocument.timelineZoom
            resetDocument.reset()
            guard resetDocument.timelineZoom == 1 else { throw Failure(description: "Reset left the timeline magnified") }
            guard resetDocument.timeline!.clips.count == 1, resetDocument.timeline!.clips[0].start == 0,
                  abs(resetDocument.timeline!.duration - 12) < 0.001, !resetDocument.mute,
                  resetDocument.cropPreset == "auto", resetDocument.sourcePlayhead == 0,
                  resetDocument.previewCrop == CropRect(x: 0, y: 0, width: 1, height: 1) else { throw Failure(description: "Reset did not restore the original video") }
            resetDocument.undoEdit()
            guard resetDocument.plan == beforeReset, resetDocument.timelineZoom == beforeResetZoom,
                  resetDocument.cropPreset == "1:1", resetDocument.sourcePlayhead == 1 else { throw Failure(description: "One undo did not restore the complete reset state") }
            resetDocument.redoEdit()
            guard resetDocument.timeline!.clips.count == 1, resetDocument.timelineZoom == 1, !resetDocument.mute else { throw Failure(description: "Redo reset did not restore defaults") }
            resetDocument.editUndoManager.removeAllActions(); resetDocument.zoomTimeline(by: 2); resetDocument.reset()
            resetDocument.undoEdit()
            guard resetDocument.timelineZoom == 2 else { throw Failure(description: "Zoom-only reset was not undoable") }
            resetDocument.reset(); resetDocument.toggleMute(); resetDocument.editUndoManager.removeAllActions(); resetDocument.reset()
            resetDocument.undoEdit()
            guard resetDocument.mute else { throw Failure(description: "Mute-only reset was not undoable") }
            resetDocument.reset(); resetDocument.editUndoManager.removeAllActions(); resetDocument.seek(to: 5); resetDocument.zoomTimeline(by: 2)
            let beforePendingTrim = resetDocument.plan
            resetDocument.beginTrim(); resetDocument.trim(start: 1, end: 9)
            let pendingTrim = resetDocument.plan
            resetDocument.reset(); resetDocument.undoEdit()
            guard resetDocument.plan == pendingTrim, resetDocument.sourcePlayhead == 5, resetDocument.timelineZoom == 2,
                  resetDocument.boundaryPreviewClipID != nil else { throw Failure(description: "Reset during trim did not undo to the boundary preview") }
            resetDocument.undoEdit()
            guard resetDocument.plan == beforePendingTrim, resetDocument.sourcePlayhead == 5 else { throw Failure(description: "Pending trim and reset were merged into one undo") }
            resetDocument.redoEdit(); resetDocument.redoEdit()
            guard resetDocument.timelineZoom == 1, resetDocument.sourcePlayhead == 0 else { throw Failure(description: "Trim/reset redo sequence lost defaults") }
            resetDocument.setPreset("1:1"); resetDocument.zoomTimeline(by: 3); resetDocument.undoEdit()
            guard resetDocument.cropPreset == "auto", resetDocument.timelineZoom == 3 else { throw Failure(description: "Ordinary edit undo restored unrelated display zoom") }
            resetDocument.stop()
            let original = document.plan
            document.seek(to: 3); document.split()
            guard document.editUndoManager.canUndo else { throw Failure(description: "Split has no undo entry") }
            document.undoEdit()
            guard document.plan == original else { throw Failure(description: "Undo did not restore split") }
            document.redoEdit()
            guard document.timeline!.clips.count == 2 else { throw Failure(description: "Redo did not restore split") }
            document.setPreset("9:16")
            let framed = document.plan
            document.beginEditGesture()
            for _ in 0..<20 { document.change { try $0.zoomSelected(factor: 1.01); $0.panSelected(dx: 0.002, dy: 0) } }
            document.endEditGesture()
            let moved = document.plan
            document.undoEdit()
            guard document.plan == framed else { throw Failure(description: "Pan/zoom gesture was not one undo step") }
            document.redoEdit()
            guard document.plan == moved else { throw Failure(description: "Redo lost framing") }
            document.undoEdit(); document.change { $0.panSelected(dx: -0.01, dy: 0) }
            guard !document.editUndoManager.canRedo else { throw Failure(description: "New edit kept an obsolete redo branch") }
            document.reset(); document.seek(to: 3); document.split(); document.seek(to: 6); document.split()
            let first = document.timeline!.clips[0].id, last = document.timeline!.clips[2].id
            document.seek(to: 1); document.selectClip(last); document.deleteAtPlayhead()
            guard !document.timeline!.clips.contains(where: { $0.id == first }), document.timeline!.clips.contains(where: { $0.id == last }) else { throw Failure(description: "Delete targeted selection instead of the cursor's clip") }
            document.undoEdit()
            guard document.timeline!.clips.count == 3 else { throw Failure(description: "Undo lost deleted source ranges") }
            let keyWindow = EditorScrubWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            keyWindow.isReleasedWhenClosed = false; keyWindow.editorDocument = document
            func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags, repeating: Bool = false, type: NSEvent.EventType = .keyDown) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: keyWindow.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: repeating, keyCode: code)!
            }
            keyWindow.sendEvent(key("b", code: 11, modifiers: [.command]))
            guard document.timeline!.clips.count == 4 else { throw Failure(description: "Cmd-B was lost after removing the scissors button") }
            keyWindow.sendEvent(key("z", code: 6, modifiers: [.command]))
            guard document.timeline!.clips.count == 3 else { throw Failure(description: "Cmd-Z failed") }
            keyWindow.sendEvent(key("z", code: 6, modifiers: [.command, .shift]))
            guard document.timeline!.clips.count == 4 else { throw Failure(description: "Shift-Cmd-Z failed") }
            keyWindow.sendEvent(key("я", code: 6, modifiers: [.command]))
            guard document.timeline!.clips.count == 3 else { throw Failure(description: "Russian Cmd-Z did not undo") }
            keyWindow.sendEvent(key("Я", code: 6, modifiers: [.command, .shift]))
            guard document.timeline!.clips.count == 4 else { throw Failure(description: "Russian Shift-Cmd-Z did not redo") }
            document.seek(to: 2)
            keyWindow.sendEvent(key("и", code: 11, modifiers: [.command]))
            guard document.timeline!.clips.count == 5 else { throw Failure(description: "Russian Cmd-B did not split at the playhead") }
            document.reset(); document.seek(to: 3); document.split(); document.seek(to: 7); document.split()
            let middle = document.timeline!.clips[1].id
            document.selectClip(middle); document.deleteSelected(); document.setPreset("1:1"); document.seek(to: 1)
            let playbackViewport = CropPlayerViewport(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            playbackViewport.video.player = document.player
            keyWindow.contentView = playbackViewport; keyWindow.makeFirstResponder(playbackViewport.video)
            try await Task.sleep(nanoseconds: 200_000_000)
            let space = key(" ", code: 49, modifiers: [])
            keyWindow.sendEvent(space)
            guard document.playing else { throw Failure(description: "Space reached AVKit instead of editor playback after cut and square crop") }
            keyWindow.sendEvent(key(" ", code: 49, modifiers: [], repeating: true))
            keyWindow.sendEvent(key(" ", code: 49, modifiers: [], type: .keyUp))
            guard document.playing else { throw Failure(description: "Space autorepeat/release toggled playback twice") }
            let playbackStart = document.sourcePlayhead
            try await Task.sleep(nanoseconds: 350_000_000)
            guard document.playing, document.sourcePlayhead > playbackStart + 0.1, document.player.rate > 0 else { throw Failure(description: "Space advanced only one frame instead of continuing playback") }
            keyWindow.sendEvent(space)
            guard !document.playing else { throw Failure(description: "Second Space did not pause editor playback") }
            let pausedTime = document.sourcePlayhead
            try await Task.sleep(nanoseconds: 150_000_000)
            guard abs(document.sourcePlayhead - pausedTime) <= document.timeline!.frameDuration else { throw Failure(description: "Space pause did not stop the decoder") }
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
            keyWindow.contentView?.addSubview(text); keyWindow.makeFirstResponder(text); keyWindow.sendEvent(space)
            guard text.string == " ", !document.playing else { throw Failure(description: "Playback shortcut stole a text field's space") }
            text.removeFromSuperview(); keyWindow.makeFirstResponder(playbackViewport.video)
            document.reset(); document.seek(to: 3)
            let beforeTrim = document.plan
            document.beginTrim()
            for index in 1...12 { document.trim(start: Double(index) / 25, end: 11) }
            document.endEditGesture(); let afterTrim = document.plan
            document.undoEdit(); guard document.plan == beforeTrim else { throw Failure(description: "A trim gesture took more than one undo") }
            document.redoEdit(); guard document.plan == afterTrim else { throw Failure(description: "Trim redo failed") }
            document.reset(); document.seek(to: 5); document.trim(start: 0, end: 3)
            document.undoEdit(); document.redoEdit()
            guard abs(document.sourcePlayhead - 5) < 0.0001 else { throw Failure(description: "Redo clamped the stationary cursor into trimmed footage") }
            document.reset(); document.setPreset("9:16"); document.seek(to: 3); document.split(); document.seek(to: 6); document.split()
            document.seek(to: 5); document.trim(start: 3, end: 4); document.zoomImage(factor: 1.2)
            guard abs(document.sourcePlayhead - 5) < 0.0001 else { throw Failure(description: "Direct framing still seeks a cursor in an inactive gap") }
            let gestureDocument = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])); await gestureDocument.load()
            gestureDocument.setPreset("9:16"); gestureDocument.zoomImage(factor: 2)
            let beforeTouch = gestureDocument.plan
            let touchView = ScrubPlayerView()
            touchView.beginEdit = { gestureDocument.beginEditGesture() }; touchView.endEdit = { gestureDocument.endEditGesture() }
            touchView.pan = { dx, dy in gestureDocument.panImage(dx: dx, dy: dy, width: 320, height: 180) }
            func phased(_ phase: CGScrollPhase) -> NSEvent {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: phase == .ended ? 0 : 20, wheel3: 0)!
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)); return NSEvent(cgEvent: event)!
            }
            touchView.scrollWheel(with: phased(.began)); touchView.scrollWheel(with: phased(.changed))
            try await Task.sleep(nanoseconds: 300_000_000)
            touchView.scrollWheel(with: phased(.changed)); touchView.scrollWheel(with: phased(.ended))
            try await Task.sleep(nanoseconds: 250_000_000)
            gestureDocument.undoEdit()
            guard gestureDocument.plan == beforeTouch else { throw Failure(description: "A pause within one native touch gesture split its undo history") }
            gestureDocument.stop()
            let view = ScrubPlayerView(); var wheelZoom = 0.0, fingerPan = 0.0
            view.zoom = { wheelZoom = $0 }; view.pan = { dx, _ in fingerPan = dx }
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0)!
            view.scrollWheel(with: NSEvent(cgEvent: wheel)!)
            guard wheelZoom > 1 else { throw Failure(description: "Mouse wheel does not zoom") }
            let touch = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 20, wheel3: 0)!
            view.scrollWheel(with: NSEvent(cgEvent: touch)!)
            guard fingerPan != 0 else { throw Failure(description: "Two fingers do not position the image") }
            let beforeVertical = gestureDocument.previewCrop
            let verticalTouch = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0)!
            touchView.scrollWheel(with: NSEvent(cgEvent: verticalTouch)!)
            let afterVertical = gestureDocument.previewCrop
            guard afterVertical.y < beforeVertical.y else { throw Failure(description: "Vertical touch pan moves the canvas against the requested finger direction") }
            let camera = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])); await camera.load()
            guard camera.plan.metadataPolicy == .discard else { throw Failure(description: "Editor did not mark queued saves as metadata-discarding") }
            camera.trim(start: 0.4, end: 8)
            guard camera.validationError == nil else { throw Failure(description: "Editor still blocks camera timecode trimming: \(camera.validationError!)") }
            camera.stop()
            if CommandLine.arguments.count > 3 {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoQuickCameraCheck-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let source = URL(fileURLWithPath: CommandLine.arguments[3])
                let link = folder.appendingPathComponent("camera.mov")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
                let actual = EditorDocument(url: link); await actual.load()
                guard let info = actual.info else { throw Failure(description: "Actual camera source failed to load: \(actual.error ?? "unknown")") }
                actual.setPreset("1:1"); actual.trim(start: 0.4, end: min(2.4, info.duration))
                let queue = ConversionQueue(storeURL: folder.appendingPathComponent("queue.json"), exporter: MediaExporter())
                actual.save(in: queue, bitrate: .mbps5)
                for _ in 0..<1800 where queue.hasWork { try await Task.sleep(nanoseconds: 50_000_000) }
                guard let job = queue.jobs.first, job.state == .completed, let output = job.outputURL else {
                    queue.cancelAll(); throw Failure(description: "Actual camera editor save failed: \(actual.error ?? queue.jobs.first?.error ?? "timeout")")
                }
                let result = try await MediaInspector.inspect(output)
                let types = try await AVURLAsset(url: output).load(.tracks).map(\.mediaType)
                guard !types.contains(.timecode), abs(result.duration - 2) < 0.1, result.width == result.height else { throw Failure(description: "Actual camera edit retained invalid timecode, duration or crop") }
                actual.stop()
                print("Actual camera editor save passed: \(result.width)×\(result.height), \(result.duration) s, video/audio only; temporary result removed")
            }
            keyWindow.close()
            print("Native editor command checks passed: undo/redo keys, coalesced trim/framing, redo invalidation, cursor-target deletion, direct wheel zoom and touch pan")
            document.stop()
        } catch { fputs("Native editor command check failed: \(error)\n", stderr); exit(1) }
    }
}
