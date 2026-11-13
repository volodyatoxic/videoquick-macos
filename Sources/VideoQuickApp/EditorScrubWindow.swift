import AppKit

/// Own editor playback/commands before AVKit can bypass retained-range state.
@MainActor final class EditorScrubWindow: NSWindow {
    weak var editorDocument: EditorDocument?
    weak var timelineScrollRegion: NSView?
    weak var videoFramingRegion: NSView?
    var framingScrollHandler: ((NSEvent) -> Void)?
    var timelineMagnificationHandler: ((NSEvent) -> Void)?
    private var magnifyingTimeline: Bool?
    override var undoManager: UndoManager? { editorDocument?.editUndoManager ?? super.undoManager }
    @objc func undo(_ sender: Any?) {
        if firstResponder is NSTextView { NSApp.sendAction(#selector(undo(_:)), to: firstResponder, from: sender) }
        else { editorDocument?.undoEdit() }
    }
    @objc func redo(_ sender: Any?) {
        if firstResponder is NSTextView { NSApp.sendAction(#selector(redo(_:)), to: firstResponder, from: sender) }
        else { editorDocument?.redoEdit() }
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return (firstResponder as? NSTextView)?.undoManager?.canUndo ?? (editorDocument?.canUndoEdit == true) }
        if menuItem.action == #selector(redo(_:)) { return (firstResponder as? NSTextView)?.undoManager?.canRedo ?? (editorDocument?.canRedoEdit == true) }
        return super.validateMenuItem(menuItem)
    }
    override func sendEvent(_ event: NSEvent) {
        if [.keyDown, .keyUp].contains(event.type), event.keyCode == 49,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           !(firstResponder is NSTextView), !(firstResponder is NSTextField), let document = editorDocument {
            if event.type == .keyDown, !event.isARepeat, !document.saveState.isActive, document.timeline != nil {
                document.togglePlayback()
            }
            return
        }
        if event.type == .keyDown, !(firstResponder is NSTextView), !(firstResponder is NSTextField), let document = editorDocument {
            let modifiers = event.modifierFlags
            if modifiers.contains(.command), modifiers.intersection([.option, .control]).isEmpty {
                // Physical ANSI positions keep these bindings independent of the input language.
                switch event.keyCode {
                case 6: if modifiers.contains(.shift) { document.redoEdit() } else { document.undoEdit() }; return // Z
                case 11: document.split(); return // B
                case 24, 69: document.zoomTimeline(by: 1.25); return // + / numpad +
                case 27, 78: document.zoomTimeline(by: 0.8); return // - / numpad -
                case 29, 82: document.resetTimelineZoom(); return // 0 / numpad 0
                default: break
                }
            }
            if [UInt16(51), UInt16(117)].contains(event.keyCode), modifiers.intersection([.command, .option, .control]).isEmpty { document.deleteAtPlayhead(); return }
        }
        if event.type == .keyDown, [UInt16(123), UInt16(124)].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           !(firstResponder is NSTextView), !(firstResponder is NSTextField), let document = editorDocument {
            let count = event.modifierFlags.contains(.shift) ? 10 : 1
            document.stepPlayhead(frames: event.keyCode == 123 ? -count : count)
            return
        }
        if [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged].contains(event.type) {
            EditorWindowChrome.setVisible(EditorWindowChrome.containsPointer(event, in: self), on: self)
        }
        if event.type == .magnify {
            if event.phase.contains(.began) || magnifyingTimeline == nil {
                magnifyingTimeline = timelineScrollRegion.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            }
            let routeToTimeline = magnifyingTimeline == true
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.phase.isEmpty { magnifyingTimeline = nil }
            if routeToTimeline { timelineMagnificationHandler?(event); return }
        }
        if event.type == .scrollWheel, editorDocument != nil, let contentView,
           contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil)),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if let region = timelineScrollRegion, region.bounds.contains(region.convert(event.locationInWindow, from: nil)) {
                super.sendEvent(event)
                return
            }
            if let region = videoFramingRegion, region.bounds.contains(region.convert(event.locationInWindow, from: nil)) {
                framingScrollHandler?(event); return
            }
        }
        super.sendEvent(event)
    }
}
