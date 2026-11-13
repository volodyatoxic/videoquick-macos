import SwiftUI
import AppKit
import VideoQuickCore

/// Native viewport bridge for anchored display zoom and cursor visibility.
struct TimelineScrollRegion: NSViewRepresentable {
    let document: EditorDocument
    let layout: TimelineDisplayLayout
    let following: Bool
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) { view.update(document: document, layout: layout, following: following) }
    final class Region: NSView {
        private struct Anchor { let time: Double; let clip: UUID?; let localX: Double }
        private weak var document: EditorDocument?
        private var layout: TimelineDisplayLayout?
        private var zoom = 1.0
        private var sourceCursor = 0.0
        private var gestureAnchor: Anchor?
        private var requestedAnchor: Anchor?
        private var scheduledAnchor: Anchor?
        private var scrollTask: Task<Void, Never>?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { scrollTask?.cancel(); gestureAnchor = nil; requestedAnchor = nil; scheduledAnchor = nil }
            register()
        }
        private func register() {
            guard let window = window as? EditorScrubWindow else { return }
            window.timelineScrollRegion = self
            window.timelineMagnificationHandler = { [weak self] event in self?.magnifyTimeline(event) }
        }
        func update(document: EditorDocument, layout: TimelineDisplayLayout, following: Bool) {
            register()
            let zoomChanged = self.layout != nil && zoom != document.timelineZoom
            let cursorChanged = sourceCursor != document.sourcePlayhead
            if zoomChanged, let old = self.layout, let scroll = scrollView() {
                let anchor = requestedAnchor ?? scheduledAnchor ?? keyboardAnchor(old, scroll: scroll, document: document)
                requestedAnchor = nil; scheduledAnchor = anchor
                scheduleScroll(anchor: anchor)
            } else if following, cursorChanged, document.timelineZoom > 1, let scroll = scrollView() {
                let cursor = layout.x(at: document.sourcePlayhead, preferredClip: document.playheadClip?.id)
                let visible = scroll.contentView.bounds
                if cursor < Double(visible.minX) + 16 || cursor > Double(visible.maxX) - 16 { scheduleScroll(anchor: nil) }
            }
            self.document = document; self.layout = layout; zoom = document.timelineZoom; sourceCursor = document.sourcePlayhead
        }
        private func magnifyTimeline(_ event: NSEvent) {
            guard let document, let layout, let scroll = scrollView() else { return }
            if event.phase.contains(.began) || gestureAnchor == nil {
                gestureAnchor = anchor(layout, scroll: scroll, localX: Double(convert(event.locationInWindow, from: nil).x))
            }
            let previous = document.timelineZoom
            document.zoomTimeline(by: max(0.1, 1 + Double(event.magnification)))
            if previous != document.timelineZoom { requestedAnchor = gestureAnchor }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.phase.isEmpty { gestureAnchor = nil }
        }
        private func anchor(_ layout: TimelineDisplayLayout, scroll: NSScrollView, localX: Double) -> Anchor {
            let local = min(Double(bounds.width), max(0, localX))
            let x = Double(scroll.contentView.bounds.minX) + local
            let clip = layout.items.first { x >= $0.x && x < $0.x + $0.width }?.clipID
            return Anchor(time: layout.sourceTime(atX: x, trimming: true), clip: clip, localX: local)
        }
        private func keyboardAnchor(_ layout: TimelineDisplayLayout, scroll: NSScrollView, document: EditorDocument) -> Anchor {
            let x = layout.x(at: document.sourcePlayhead, preferredClip: document.playheadClip?.id)
            let local = x - Double(scroll.contentView.bounds.minX)
            if local >= 0, local <= Double(bounds.width) { return Anchor(time: document.sourcePlayhead, clip: document.playheadClip?.id, localX: local) }
            return anchor(layout, scroll: scroll, localX: Double(bounds.midX))
        }
        private func scheduleScroll(anchor: Anchor?) {
            scrollTask?.cancel()
            scrollTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let document = self.document, let layout = self.layout, let scroll = self.scrollView() else { return }
                if anchor != nil { self.window?.contentView?.layoutSubtreeIfNeeded() }
                var x = Double(scroll.contentView.bounds.minX)
                if let anchor { x = layout.x(at: anchor.time, preferredClip: anchor.clip) - anchor.localX }
                else {
                    let cursor = layout.x(at: document.sourcePlayhead, preferredClip: document.playheadClip?.id)
                    let visible = Double(scroll.contentSize.width)
                    if cursor < x + 16 { x = cursor - 16 }
                    else if cursor > x + visible - 16 { x = cursor - visible + 16 }
                }
                let maximum = max(0, Double(scroll.documentView?.frame.width ?? 0) - Double(scroll.contentSize.width))
                let target = min(maximum, max(0, x))
                if abs(target - Double(scroll.contentView.bounds.minX)) > 0.01 {
                    scroll.contentView.scroll(to: NSPoint(x: target, y: scroll.contentView.bounds.minY))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                self.scheduledAnchor = nil; self.scrollTask = nil
            }
        }
        private func scrollView() -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                for child in view.subviews { if let scroll = find(child) { return scroll } }
                return nil
            }
            var root = superview
            while let view = root { if let scroll = find(view) { return scroll }; root = view.superview }
            return nil
        }
    }
}
