import AppKit

@MainActor enum EditorWindowChrome {
    static func configure(_ window: NSWindow, title: String) {
        window.styleMask.insert(.fullSizeContentView)
        window.title = title
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        setVisible(false, on: window)
    }
    static func setVisible(_ visible: Bool, on window: NSWindow) {
        guard window.titleVisibility != (visible ? .visible : .hidden) || window.standardWindowButton(.closeButton)?.isHidden != !visible else { return }
        window.titleVisibility = visible ? .visible : .hidden
        window.titlebarAppearsTransparent = !visible
        window.standardWindowButton(.closeButton)?.isHidden = !visible
    }
    static func containsPointer(_ event: NSEvent, in window: NSWindow) -> Bool {
        window.frame.contains(window.convertPoint(toScreen: event.locationInWindow))
    }
}

/// Geometric tracking stays active over the embedded AVKit view and while dragging.
final class EditorChromeTracker: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard area == nil else { return }
        let value = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
        area = value; addTrackingArea(value)
    }
    private func pointerChanged(_ event: NSEvent) {
        guard let window else { return }
        onHover?(EditorWindowChrome.containsPointer(event, in: window))
    }
    override func mouseEntered(with event: NSEvent) { pointerChanged(event) }
    override func mouseMoved(with event: NSEvent) { pointerChanged(event) }
    override func mouseExited(with event: NSEvent) { pointerChanged(event) }
}
