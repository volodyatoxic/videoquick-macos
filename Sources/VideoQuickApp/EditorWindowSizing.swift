import AppKit

@MainActor enum EditorWindowSizing {
    static func apply(to window: NSWindow, aspect: Double, free: Bool) {
        guard aspect.isFinite, aspect > 0 else { return }
        // Aspect and increments are mutually exclusive. A zero aspect is not an
        // unlock flag; AppKit can divide by it during native live resizing.
        if free { window.contentResizeIncrements = NSSize(width: 1, height: 1) }
        else { window.contentAspectRatio = NSSize(width: aspect, height: 1) }
        window.contentMinSize = free ? NSSize(width: 320, height: 220) : NSSize(width: max(320, 180 * aspect), height: max(180, 320 / aspect))
    }
}
