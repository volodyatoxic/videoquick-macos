import SwiftUI
import AppKit
import VideoQuickCore

@MainActor final class AppModel: ObservableObject {
    let queue: ConversionQueue
    weak var controller: EditorWindowController?
    init(store: URL) { queue = ConversionQueue(storeURL: store, exporter: IconPreviewExporter()) }
    func configureEditor(_ document: EditorDocument) { controller?.configure(document: document) }
}
private struct IconPreviewExporter: Exporting {
    func export(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { throw CancellationError() }
}
@main struct NativeIconEditorChecks {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        for name in ["ToolbarVolumeOn", "ToolbarVolumeOff", "ToolbarReset", "ToolbarSave", "ToolbarChevron", "ToolbarCancel", "ToolbarWarning"] {
            guard NSImage(named: NSImage.Name(name)) != nil else { throw Failure(message: "Bundled toolbar icon missing: \(name)") }
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let model = AppModel(store: directory.appendingPathComponent("queue.json"))
        defer { try? FileManager.default.removeItem(at: directory.appendingPathComponent("queue.json")) }
        let session = EditorSession(urls: [URL(fileURLWithPath: CommandLine.arguments[1])])
        let document = session.current!; await document.load()
        guard document.hasAudio else { throw Failure(message: "Audio source lost its sound control") }
        let controller = EditorWindowController(session: session, model: model); model.controller = controller
        controller.configure(document: document)
        try await Task.sleep(nanoseconds: 300_000_000)
        let host = controller.window!.contentView!
        func viewport(in view: NSView) -> CropPlayerViewport? {
            if let result = view as? CropPlayerViewport { return result }
            for child in view.subviews { if let result = viewport(in: child) { return result } }
            return nil
        }
        guard let viewport = viewport(in: host) else { throw Failure(message: "No native video viewport") }
        let point = host.convert(NSPoint(x: viewport.bounds.midX, y: viewport.bounds.midY), from: viewport)
        let hit = host.hitTest(point)
        guard hit === viewport.video else { throw Failure(message: "Mouse drag is intercepted by \(String(describing: hit.map { type(of: $0) })) instead of the framing player") }
        document.zoomImage(factor: 2)
        let beforeDrag = document.previewCrop, cursor = document.sourcePlayhead
        let start = viewport.convert(NSPoint(x: viewport.bounds.midX, y: viewport.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        hit!.mouseDown(with: mouse(.leftMouseDown, at: start))
        hit!.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: start.x + 20, y: start.y - 12)))
        hit!.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: start.x + 20, y: start.y - 12)))
        guard document.previewCrop.x < beforeDrag.x, document.previewCrop.y < beforeDrag.y,
              document.sourcePlayhead == cursor else { throw Failure(message: "Mouse drag must move the canvas right/down without seeking") }
        document.undoEdit()
        guard document.previewCrop == beforeDrag else { throw Failure(message: "Mouse drag was not one undo step") }
        document.undoEdit()
        document.seek(to: 3); document.split()
        controller.window!.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(nanoseconds: 150_000_000)
        let soundOnWidth = try toolbarWidth(controller)
        document.toggleMute(); guard document.mute else { throw Failure(message: "Mute command failed") }
        try await Task.sleep(nanoseconds: 150_000_000)
        let soundOffWidth = try toolbarWidth(controller)
        guard soundOnWidth == soundOffWidth else { throw Failure(message: "Mute changes toolbar width: \(soundOnWidth) to \(soundOffWidth)") }
        document.undoEdit(); guard !document.mute else { throw Failure(message: "Mute did not undo") }
        document.toggleMute()
        try await snapshot(controller, directory, "muted-dark", appearance: .darkAqua)
        document.undoEdit()
        try await snapshot(controller, directory, "landscape-dark", appearance: .darkAqua)
        try await snapshot(controller, directory, "landscape-light", appearance: .aqua)
        document.setPreset("9:16"); controller.configure(document: document)
        try await snapshot(controller, directory, "portrait-dark", appearance: .darkAqua)
        document.zoomTimeline(by: 2)
        let priorResetPlan = document.plan
        document.reset(); controller.configure(document: document)
        guard document.cropPreset == "auto", document.timelineZoom == 1, document.timeline!.clips.count == 1 else { throw Failure(message: "Reset did not restore native editor defaults") }
        let resetSize = controller.window!.contentView!.bounds.size
        guard abs(Double(resetSize.width / resetSize.height) - 640.0 / 360) < 0.01 else { throw Failure(message: "Reset did not restore source window aspect") }
        document.undoEdit(); controller.configure(document: document)
        guard document.plan == priorResetPlan, document.timelineZoom == 2, document.cropPreset == "9:16" else { throw Failure(message: "Reset undo did not restore the complete native editor") }
        let notification = Notification(name: NSWindow.didResizeNotification)
        controller.windowWillStartLiveResize(notification)
        controller.window!.setContentSize(NSSize(width: 430, height: 600)); controller.windowDidResize(notification); controller.windowDidEndLiveResize(notification)
        guard document.cropPreset == "auto", abs(document.timeline!.aspect - 430.0 / 600) < 0.001 else { throw Failure(message: "Manual resize did not switch to auto") }
        document.undoEdit(); controller.configure(document: document)
        guard document.cropPreset == "9:16" else { throw Failure(message: "Resize did not undo as one gesture") }
        document.redoEdit(); controller.configure(document: document)
        guard document.cropPreset == "auto" else { throw Failure(message: "Resize did not redo") }
        controller.windowWillStartLiveResize(notification); controller.window!.setContentSize(NSSize(width: 320, height: 500)); controller.windowDidEndLiveResize(notification)
        try await snapshot(controller, directory, "narrow-auto", appearance: .darkAqua)
        let silent = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])); await silent.load()
        guard !silent.hasAudio else { throw Failure(message: "Silent source gained an audio track") }
        session.documents = [silent]; session.selection = silent.id; controller.configure(document: silent)
        try await snapshot(controller, directory, "silent-dark", appearance: .darkAqua)
        controller.window?.close(); document.stop(); silent.stop()
        print("Native icon editor checks passed: audio/mute undo, resize auto/undo/redo, native dark/light/portrait/narrow/silent renders")
    }
    @MainActor static func toolbarWidth(_ controller: NSWindowController) throws -> Int {
        guard let host = controller.window?.contentView, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "No toolbar render") }
        host.layoutSubtreeIfNeeded(); host.cacheDisplay(in: host.bounds, to: bitmap)
        var left = bitmap.pixelsWide, right = -1
        // The actual offscreen player layer is black; the top material capsule is the visible nonblack region.
        for y in 0..<min(200, bitmap.pixelsHigh / 3) { for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5,
               max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.04 {
                left = min(left, x); right = max(right, x)
            }
        } }
        guard right >= left else { throw Failure(message: "Toolbar pixels unavailable") }
        return right - left + 1
    }
    @MainActor static func snapshot(_ controller: NSWindowController, _ directory: URL, _ name: String, appearance: NSAppearance.Name) async throws {
        controller.window?.appearance = NSAppearance(named: appearance)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard let host = controller.window?.contentView, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "No native snapshot") }
        host.layoutSubtreeIfNeeded(); host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "No rendered image") }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
