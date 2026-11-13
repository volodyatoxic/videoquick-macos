import SwiftUI
import AVKit
import VideoQuickCore

struct NativeCropPlayer: NSViewRepresentable {
    let player: AVPlayer
    let crop: CropRect
    let editing: Bool
    let onPan: (Double, Double, Double, Double) -> Void
    let onZoom: (Double) -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> CropPlayerViewport { CropPlayerViewport() }
    func updateNSView(_ view: CropPlayerViewport, context: Context) {
        if view.video.player !== player { view.video.player = player }
        if view.crop != crop { view.crop = crop; view.needsLayout = true }
        if view.editing != editing { view.editing = editing; view.window?.invalidateCursorRects(for: view) }
        view.video.isFramingEnabled = editing
        view.video.pan = { [weak view] dx, dy in onPan(dx, dy, Double(view?.bounds.width ?? 1), Double(view?.bounds.height ?? 1)) }
        view.video.zoom = onZoom; view.video.beginEdit = onBegin; view.video.endEdit = onEnd
        view.layoutSubtreeIfNeeded()
    }
}
final class CropPlayerViewport: NSView {
    let video = ScrubPlayerView()
    var crop = CropRect(x: 0, y: 0, width: 1, height: 1)
    var editing = true
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        video.controlsStyle = .none; video.videoGravity = .resize; video.allowsVideoFrameAnalysis = false
        addSubview(video)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window as? EditorScrubWindow {
            window.videoFramingRegion = self
            window.framingScrollHandler = { [weak video = self.video] event in video?.scrollWheel(with: event) }
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = PreviewViewport.frame(crop: crop, size: bounds.size)
        CATransaction.commit()
    }
    override func resetCursorRects() { if editing { addCursorRect(bounds, cursor: .openHand) } }
}
final class ScrubPlayerView: AVPlayerView {
    var isFramingEnabled = true { didSet { if !isFramingEnabled { finishGesture() } } }
    var pan: ((Double, Double) -> Void)?
    var zoom: ((Double) -> Void)?
    var beginEdit: (() -> Void)?
    var endEdit: (() -> Void)?
    private var lastPoint: NSPoint?
    private var endTask: Task<Void, Never>?
    private enum Gesture: Equatable { case mouse, touch, wheel, pinch }
    private var activeGesture: Gesture?
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AVKit's private content subview otherwise consumes drags before our framing handlers.
        guard isFramingEnabled, super.hitTest(point) != nil else { return super.hitTest(point) }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard isFramingEnabled else { return }
        window?.makeFirstResponder(self); beginGesture(.mouse, newPhysicalGesture: true); lastPoint = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard isFramingEnabled, let previous = lastPoint else { return }
        let point = event.locationInWindow; lastPoint = point
        pan?(Double(point.x - previous.x), -Double(point.y - previous.y))
    }
    override func mouseUp(with event: NSEvent) { lastPoint = nil; if activeGesture == .mouse { finishGesture() } }
    override func scrollWheel(with event: NSEvent) {
        guard isFramingEnabled else { return }
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        beginGesture(phased ? .touch : .wheel, newPhysicalGesture: event.phase.contains(.began))
        if event.hasPreciseScrollingDeltas { pan?(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY)) }
        else { zoom?(exp(Double(event.scrollingDeltaY) * 0.04)) }
        if !phased { finishSoon(after: 200_000_000) }
        else if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { finishGesture() }
        else if event.phase.contains(.ended) && event.momentumPhase.isEmpty { finishSoon(after: 50_000_000) }
    }
    override func magnify(with event: NSEvent) {
        guard isFramingEnabled else { return }
        let phased = !event.phase.isEmpty
        beginGesture(.pinch, newPhysicalGesture: event.phase.contains(.began))
        zoom?(max(0.1, 1 + Double(event.magnification)))
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { finishGesture() }
        else if !phased { finishSoon(after: 200_000_000) }
    }
    private func beginGesture(_ kind: Gesture, newPhysicalGesture: Bool = false) {
        if activeGesture != kind || newPhysicalGesture { finishGesture(); activeGesture = kind }
        endTask?.cancel(); endTask = nil; beginEdit?()
    }
    private func finishGesture() {
        endTask?.cancel(); endTask = nil
        guard activeGesture != nil else { return }; activeGesture = nil; endEdit?()
    }
    private func finishSoon(after delay: UInt64) {
        endTask?.cancel()
        endTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.finishGesture()
        }
    }
}
