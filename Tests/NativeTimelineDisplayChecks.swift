import SwiftUI
import AppKit
import VideoQuickCore

@main struct NativeTimelineDisplayChecks {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let document = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        await document.load()
        guard let timeline = document.timeline else { throw Failure(message: "Fixture did not load") }
        for _ in 0..<300 where document.thumbnails.count < 16 { try await Task.sleep(nanoseconds: 10_000_000) }
        let window = EditorScrubWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.editorDocument = document
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ClipTimelineView(document: document).padding(12).frame(width: 900, height: 80).background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []; window.contentView = host; window.setContentSize(NSSize(width: 900, height: 80))
        document.change { try $0.split(at: timeline.frameDuration) }
        document.selectClip(document.timeline!.clips[0].id, seek: true)
        try await snapshot(host, name: "single-frame")
        guard window.timelineScrollRegion != nil else { throw Failure(message: "Real timeline did not register its native wheel region") }
        document.reset(); document.seek(to: 3); document.trim(start: 0, end: 3)
        try await snapshot(host, name: "inner-right-edge")
        document.reset(); document.seek(to: 3); document.trim(start: 3, end: 12)
        try await snapshot(host, name: "inner-left-edge")
        document.reset(); document.seek(to: 3)
        try await snapshot(host, name: "frame-square-aperture")
        guard let zoomScroll = findScroll(host), let zoomContent = zoomScroll.documentView else { throw Failure(message: "No native timeline scroll view") }
        document.editUndoManager.removeAllActions()
        let baselineWidth = zoomContent.frame.width
        let originalPlan = document.plan, originalCursor = document.sourcePlayhead
        func key(_ code: UInt16, _ character: String, shift: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        window.sendEvent(key(24, "+", shift: true))
        try await snapshot(host, name: "timeline-keyboard-zoom")
        guard zoomContent.frame.width > baselineWidth * 1.2 else { throw Failure(message: "Cmd-plus did not expand the timeline") }
        window.sendEvent(key(27, "−"))
        try await Task.sleep(nanoseconds: 100_000_000)
        guard abs(zoomContent.frame.width - baselineWidth) < 1 else { throw Failure(message: "Cmd-minus did not contract timeline zoom") }
        window.sendEvent(key(69, "+")); window.sendEvent(key(82, "0"))
        try await Task.sleep(nanoseconds: 100_000_000)
        guard abs(zoomContent.frame.width - baselineWidth) < 1 else { throw Failure(message: "Numpad zoom/reset failed") }
        guard let region = window.timelineScrollRegion else { throw Failure(message: "Timeline gesture region missing") }
        let anchorX = 13 + (region.bounds.width - 26) / 4
        let location = region.convert(NSPoint(x: anchorX, y: region.bounds.midY), to: nil)
        window.sendEvent(Pinch(location: location, amount: 0.5, phase: .began))
        window.sendEvent(Pinch(location: location, amount: 0, phase: .ended))
        try await snapshot(host, name: "timeline-pinch-zoom")
        guard zoomContent.frame.width > baselineWidth * 1.45 else { throw Failure(message: "Timeline pinch did not expand its content") }
        guard abs(zoomScroll.contentView.bounds.minX - baselineWidth / 8) < 2 else { throw Failure(message: "Pinch did not preserve source time under the pointer: offset \(zoomScroll.contentView.bounds.minX)") }
        guard document.plan == originalPlan, document.sourcePlayhead == originalCursor else { throw Failure(message: "Display zoom changed the montage or cursor") }
        guard !document.editUndoManager.canUndo else { throw Failure(message: "Display zoom polluted edit undo history") }
        document.scrubSource(to: 11)
        try await snapshot(host, name: "timeline-zoom-cursor-follow")
        guard zoomScroll.contentView.bounds.minX > baselineWidth / 3 else { throw Failure(message: "Zoomed cursor was left outside the visible viewport") }
        window.sendEvent(key(29, "0"))
        try await snapshot(host, name: "timeline-zoom-reset")
        guard abs(zoomContent.frame.width - baselineWidth) < 1 else { throw Failure(message: "Cmd-0 did not restore fit zoom") }
        document.reset()
        document.change { value in for index in 1..<100 { try value.split(at: Double(index) * timeline.frameDuration) } }
        document.selectClip(document.timeline!.clips[0].id, seek: true)
        try await snapshot(host, name: "hundred-clips")
        guard let scroll = findScroll(host), let content = scroll.documentView, content.frame.width >= 2200 else { throw Failure(message: "Hundred clips did not create native horizontal overflow") }
        let before = document.sourcePlayhead
        scroll.contentView.scroll(to: NSPoint(x: min(2200, content.frame.width - scroll.contentSize.width), y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        try await snapshot(host, name: "hundred-clips-panned")
        guard scroll.contentView.bounds.minX > 1000, document.sourcePlayhead == before else { throw Failure(message: "Native panning moved the source cursor or failed to scroll") }
        print("Native timeline display checks passed: one-frame preview, both inner edges, 100 readable clips, native horizontal panning with unchanged cursor")
        document.stop(); window.close()
    }
    @MainActor static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = findScroll(child) { return found } }
        return nil
    }
    @MainActor static func snapshot(_ host: NSView, name: String) async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "Native snapshot is unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "Could not encode native snapshot") }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name + ".png"))
    }
}

private final class Pinch: NSEvent {
    private let point: NSPoint
    private let amount: CGFloat
    private let eventPhase: NSEvent.Phase
    init(location: NSPoint, amount: CGFloat, phase: NSEvent.Phase) { point = location; self.amount = amount; eventPhase = phase; super.init() }
    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { .magnify }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { amount }
    override var phase: NSEvent.Phase { eventPhase }
}
