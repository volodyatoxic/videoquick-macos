import AppKit
import SwiftUI

@MainActor final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private var aspect = 16.0 / 9
    private var adjusting = false
    private var liveResizing = false
    private weak var editorDocument: EditorDocument?
    private var resizeTask: Task<Void, Never>?
    init(session: EditorSession, model: AppModel) {
        let window = EditorScrubWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        EditorWindowChrome.configure(window, title: "VideoQuick")
        let content = NSHostingView(rootView: EditorView(session: session, model: model)); content.sizingOptions = []
        window.contentView = content; window.setContentSize(NSSize(width: 960, height: 540)); window.center(); window.delegate = self
        let trackingHost = content.superview ?? content
        let tracker = EditorChromeTracker(frame: trackingHost.bounds); tracker.autoresizingMask = [.width, .height]
        tracker.onHover = { [weak self] in self?.setHeaderVisible($0) }; trackingHost.addSubview(tracker, positioned: .below, relativeTo: nil)
        EditorWindowSizing.apply(to: window, aspect: aspect, free: true)
    }
    required init?(coder: NSCoder) { nil }
    func configure(document: EditorDocument) {
        guard let window else { return }
        (window as? EditorScrubWindow)?.editorDocument = document; window.title = document.url.lastPathComponent
        guard let timeline = document.timeline else { return }
        let changedDocument = editorDocument !== document, changedAspect = abs(aspect - timeline.aspect) > 0.00001
        editorDocument = document; aspect = timeline.aspect
        adjusting = true; EditorWindowSizing.apply(to: window, aspect: aspect, free: !document.saveState.isActive)
        if changedDocument || changedAspect {
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 40, dy: 40) ?? NSRect(x: 0, y: 0, width: 1100, height: 760)
            let heightLimit = max(220, visible.height - 32)
            var width = min(960, visible.width), height = width / aspect
            if height > heightLimit { height = heightLimit; width = height * aspect }
            window.setContentSize(NSSize(width: width, height: height)); window.center()
        }
        adjusting = false
    }
    func setHeaderVisible(_ visible: Bool) { if let window { EditorWindowChrome.setVisible(visible, on: window) } }
    func windowWillStartLiveResize(_ notification: Notification) {
        guard let document = editorDocument, !document.saveState.isActive else { return }
        liveResizing = true; document.beginEditGesture(); document.cropPreset = "auto"
    }
    func windowDidResize(_ notification: Notification) {
        guard liveResizing, !adjusting, let document = editorDocument, !document.saveState.isActive, let size = window?.contentView?.bounds.size, size.height > 0 else { return }
        let value = Double(size.width / size.height)
        guard value.isFinite, value > 0, abs(value - aspect) > 0.00001 else { return }
        aspect = value; resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }; self.editorDocument?.setFreeAspect(value)
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard liveResizing else { return }
        resizeTask?.cancel()
        if let size = window?.contentView?.bounds.size, size.height > 0 { aspect = Double(size.width / size.height); editorDocument?.setFreeAspect(aspect) }
        liveResizing = false
        editorDocument?.endEditGesture()
    }
    func windowWillClose(_ notification: Notification) { resizeTask?.cancel(); editorDocument?.endEditGesture(); editorDocument?.stop() }
}
