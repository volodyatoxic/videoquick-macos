import SwiftUI
import AVKit
import VideoQuickCore
import Combine

@MainActor final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let player = AVPlayer()
    let editUndoManager = UndoManager()
    private struct EditState: Equatable {
        let timeline: ClipTimeline; let mute: Bool; let preset: String; let cursor: Double
        let preview: Double?; let cursorClip: ClipEdit?; let displayZoom: Double?
    }
    private var gestureState: EditState?
    private func editState(includeDisplayZoom: Bool = false) -> EditState? { timeline.map { EditState(timeline: $0, mute: mute, preset: cropPreset, cursor: sourcePlayhead, preview: boundaryPreviewTime, cursorClip: playheadClip, displayZoom: includeDisplayZoom ? timelineZoom : nil) } }
    private func hasEdits(_ before: EditState, _ after: EditState) -> Bool {
        before.timeline.clips != after.timeline.clips || before.timeline.aspect != after.timeline.aspect || before.mute != after.mute || before.preset != after.preset
    }
    func beginEditGesture() { guard !saveState.isActive else { return }; if gestureState == nil { gestureState = editState() } }
    func endEditGesture() { let before = gestureState; gestureState = nil; recordEdit(before) }
    func undoEdit() { guard !saveState.isActive else { return }; endEditGesture(); if editUndoManager.canUndo { editUndoManager.undo(); objectWillChange.send() } }
    func redoEdit() { guard !saveState.isActive else { return }; endEditGesture(); if editUndoManager.canRedo { editUndoManager.redo(); objectWillChange.send() } }
    private var pendingGestureEdits: Bool { if let before = gestureState, let after = editState() { return hasEdits(before, after) }; return false }
    var canUndoEdit: Bool { !saveState.isActive && (editUndoManager.canUndo || pendingGestureEdits) }
    var canRedoEdit: Bool { !saveState.isActive && editUndoManager.canRedo && !pendingGestureEdits }
    private func recordEdit(_ before: EditState?, force: Bool = false) {
        guard gestureState == nil, let before, let after = editState(), force || hasEdits(before, after) else { return }
        editUndoManager.beginUndoGrouping()
        editUndoManager.registerUndo(withTarget: self) { $0.restoreEdit(before) }
        editUndoManager.endUndoGrouping()
    }
    private func restoreEdit(_ state: EditState) {
        guard !saveState.isActive, let current = editState(includeDisplayZoom: state.displayZoom != nil) else { return }
        editUndoManager.registerUndo(withTarget: self) { $0.restoreEdit(current) }
        timeline = state.timeline; mute = state.mute; cropPreset = state.preset; saved = false; error = nil
        if let zoom = state.displayZoom { timelineZoom = zoom }
        playing = false; player.pause(); refreshPreview()
        sourcePlayhead = state.cursor; playheadClip = state.cursorClip
        playhead = state.timeline.outputTime(atSourceTime: state.cursor)
        boundaryPreviewTime = state.preview
        activeClipID = state.cursorClip?.id
        pendingSourceTime = state.preview ?? state.timeline.sourceTime(at: playhead)
        seekRevision += 1; startPendingSeek()
    }
    var clipAtPlayhead: ClipEdit? {
        guard let timeline else { return nil }
        return timeline.clips.first { sourcePlayhead >= $0.start - 0.000001 && sourcePlayhead < $0.end - 0.000001 }
            ?? (abs(sourcePlayhead - (timeline.clips.last?.end ?? -1)) < timeline.frameDuration / 2 ? timeline.clips.last : nil)
    }
    var canSplitAtPlayhead: Bool {
        guard let timeline, let clip = clipAtPlayhead else { return false }
        return sourcePlayhead - clip.start >= timeline.frameDuration - 0.000001 && clip.end - sourcePlayhead >= timeline.frameDuration - 0.000001
    }
    func deleteAtPlayhead() { guard let clip = clipAtPlayhead else { return }; selectClip(clip.id); deleteSelected() }
    @Published private(set) var info: MediaInfo?
    @Published private(set) var timeline: ClipTimeline?
    @Published private(set) var thumbnails: [NSImage] = []
    @Published var playhead = 0.0
    @Published private(set) var sourcePlayhead = 0.0
    private(set) var playheadClip: ClipEdit?
    @Published private(set) var timelineZoom = 1.0
    func zoomTimeline(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        let value = min(256, max(1, timelineZoom * factor))
        if value != timelineZoom { timelineZoom = value }
    }
    func resetTimelineZoom() { if timelineZoom != 1 { timelineZoom = 1 } }
    @Published var playing = false
    @Published var mute = false
    @Published private(set) var hasAudio = false
    @Published var cropEditing = false
    @Published var cropPreset = "auto"
    @Published var error: String?
    @Published var saved = false
    @Published private(set) var saveJob: ConversionJob?
    private var saveObserver: AnyCancellable?
    private var persistenceObserver: AnyCancellable?
    private weak var saveQueue: ConversionQueue?
    var saveState: EditorSaveState { EditorSaveState(job: saveJob) }
    private var imageTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var pendingSourceTime: Double?
    private var seekRevision = 0
    private var activeClipID: UUID?
    private var boundaryPreviewTime: Double?
    var boundaryPreviewClipID: UUID? { boundaryPreviewTime == nil ? nil : timeline?.selectedID }

    init(url: URL) {
        self.url = url
        editUndoManager.groupsByEvent = false; editUndoManager.levelsOfUndo = 100
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.updatePlayback(time: time.seconds) }
        }
    }
    deinit {
        seekTask?.cancel(); imageTask?.cancel(); statusObserver?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
    var plan: EditPlan {
        guard let timeline else { return EditPlan(mute: mute, metadataPolicy: .discard) }
        let framed = abs(timeline.aspect - timeline.sourceAspect) > 0.0000001 || timeline.clips.contains { $0.crop != CropRect(x: 0, y: 0, width: 1, height: 1) }
        return EditPlan(mute: mute, clips: timeline.clips, outputAspect: framed ? timeline.aspect : nil, metadataPolicy: .discard)
    }
    var previewCrop: CropRect { timeline?.selectedClip?.crop ?? CropRect(x: 0, y: 0, width: 1, height: 1) }
    var validationError: String? {
        guard let info else { return nil }
        if info.isHDR || info.bitDepth > 8 { return "HDR / 10-bit пока не поддерживается." }
        do {
            _ = try plan.retainedRanges(duration: info.duration)
            return nil
        } catch { return error.localizedDescription }
    }
    func load() async {
        guard info == nil else { return }
        do {
            let loaded = try await MediaInspector.inspect(url)
            let value = try ClipTimeline(duration: loaded.duration, aspect: Double(loaded.displayWidth) / Double(loaded.displayHeight), frameDuration: 1 / Double(max(1, loaded.nominalFrameRate)))
            hasAudio = !(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)).isEmpty
            info = loaded; timeline = value
            refreshPreview(); generateThumbnails(duration: loaded.duration)
        } catch { self.error = error.localizedDescription }
    }
    /// The decoder always holds the source. Framing is native viewport geometry;
    /// timing is mapped to retained source ranges, without replacing visible items.
    func refreshPreview() {
        guard timeline != nil else { return }
        player.isMuted = mute
        if player.currentItem == nil {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor in
                    guard let self else { return }
                    if status == .readyToPlay { self.startPendingSeek() }
                    if status == .failed { self.error = "Не удалось открыть предпросмотр видео." }
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.advancePlayback() }
            }
            requestSeek(to: playhead)
        }
    }
    func togglePlayback() {
        if playing { playing = false; player.pause() }
        else {
            if let timeline, playhead >= timeline.duration - timeline.frameDuration / 2 { playhead = 0 }
            playing = true; requestSeek(to: playhead)
        }
    }
    func seek(to time: Double) {
        playing = false; player.pause(); requestSeek(to: time)
    }
    func scrubSource(to sourceTime: Double, movingForward: Bool = true) {
        guard !saveState.isActive, let timeline else { return }
        seek(to: timeline.outputTime(atSourceTime: sourceTime, movingForward: movingForward))
    }
    func scrollScrub(delta: Double, viewportWidth: Double) {
        guard delta.isFinite, delta != 0, let timeline else { return }
        let source = sourcePlayhead + delta * timeline.sourceDuration / max(1, viewportWidth)
        scrubSource(to: source, movingForward: delta > 0)
    }
    func stepPlayhead(frames: Int) {
        guard !saveState.isActive, frames != 0, let timeline else { return }
        let current = timeline.outputTime(atSourceTime: sourcePlayhead, movingForward: frames > 0)
        seek(to: current + Double(frames) * timeline.frameDuration)
    }
    func beginTrim() {
        guard !saveState.isActive else { return }
        beginEditGesture()
        playing = false; player.pause(); boundaryPreviewTime = sourcePlayhead
    }
    private func requestSeek(to time: Double) {
        guard let timeline, time.isFinite else { return }
        boundaryPreviewTime = nil
        playhead = min(max(0, time), max(0, timeline.duration - timeline.frameDuration / 2))
        selectVisibleClip(at: playhead)
        guard let clip = self.timeline?.selectedClip else { return }
        sourcePlayhead = timeline.sourceTime(at: playhead); playheadClip = clip
        activeClipID = clip.id
        pendingSourceTime = sourcePlayhead
        seekRevision += 1
        startPendingSeek()
    }
    private func startPendingSeek() {
        guard seekTask == nil, pendingSourceTime != nil, player.currentItem?.status == .readyToPlay else { return }
        seekTask = Task {
            while let target = pendingSourceTime, !Task.isCancelled {
                let revision = seekRevision
                // Changing this limit during an in-flight seek can strand AVPlayer's
                // completion. Serialize it with seeking, and leave paused scrubbing
                // unconstrained: retained-range mapping already clamps its targets.
                let limit = playing ? CMTime(seconds: timeline?.selectedClip?.end ?? 0, preferredTimescale: 600_000) : .invalid
                if let item = player.currentItem, item.forwardPlaybackEndTime != limit { item.forwardPlaybackEndTime = limit }
                let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600_000), toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled else { return }
                if revision == seekRevision {
                    pendingSourceTime = nil
                    if finished && playing { player.play() }
                }
            }
            seekTask = nil
        }
    }
    private func updatePlayback(time: Double) {
        guard pendingSourceTime == nil, time.isFinite, let timeline else { return }
        if !playing {
            guard boundaryPreviewTime == nil else { return }
            // AVKit can seek internally (for example from a trackpad). Accept only
            // a current observation, never a stale callback from before our seek.
            let actual = player.currentTime().seconds
            guard actual.isFinite, abs(actual - time) <= timeline.frameDuration / 2,
                  abs(time - timeline.sourceTime(at: playhead)) > timeline.frameDuration / 2 + 0.000001 else { return }
            seek(to: timeline.outputTime(atSourceTime: time, movingForward: time > timeline.sourceTime(at: playhead)))
            return
        }
        guard let clip = timeline.clips.first(where: { $0.id == activeClipID }) else { return }
        playhead = timeline.outputStart(of: clip.id) + min(clip.duration, max(0, time - clip.start))
        sourcePlayhead = min(clip.end, max(clip.start, time)); playheadClip = clip
    }
    private func advancePlayback() {
        guard playing, pendingSourceTime == nil, let timeline,
              let index = timeline.clips.firstIndex(where: { $0.id == activeClipID }) else { return }
        if index + 1 < timeline.clips.count { requestSeek(to: timeline.outputStart(of: timeline.clips[index + 1].id)) }
        else { playing = false; player.pause(); playhead = timeline.duration; sourcePlayhead = timeline.clips.last?.end ?? 0; playheadClip = timeline.clips.last }
    }
    func selectClip(_ id: UUID, seek: Bool = false) {
        timeline?.select(id)
        if seek, let timeline { self.seek(to: timeline.selectedOutputStart + min(timeline.frameDuration / 2, (timeline.selectedClip?.duration ?? 0) / 2)) }
    }
    func change(_ operation: (inout ClipTimeline) throws -> Void) {
        guard !saveState.isActive, var value = timeline else { return }
        let oldEdit = editState()
        do {
            let before = value; try operation(&value)
            guard value != before else { return }
            timeline = value; saved = false; error = nil
            recordEdit(oldEdit)
            let timingChanged = before.clips.map { TimeSpan(start: $0.start, duration: $0.duration) } != value.clips.map { TimeSpan(start: $0.start, duration: $0.duration) }
            if timingChanged { seek(to: playhead) }
        } catch { self.error = error.localizedDescription }
    }
    func split() { change { try $0.split(at: playhead) } }
    func deleteSelected() {
        guard !saveState.isActive, var value = timeline else { return }
        let oldEdit = editState()
        do {
            try value.deleteSelected(); timeline = value; saved = false; error = nil
            recordEdit(oldEdit)
            seek(to: value.selectedOutputStart)
        } catch { self.error = error.localizedDescription }
    }
    func trim(start: Double, end: Double) {
        guard !saveState.isActive, var value = timeline else { return }
        let oldEdit = editState()
        let original = value.selectedClip
        if let original, abs(start - original.start) < 0.000001, abs(end - original.end) < 0.000001 { return }
        do {
            try value.trimSelected(start: start, end: end)
            guard value.selectedClip != original else { return }
            timeline = value; saved = false; error = nil
            recordEdit(oldEdit)
            // Montage time can change while the source cursor and its visual
            // geometry stay fixed. Boundary preview never moves that cursor.
            playhead = value.outputTime(atSourceTime: sourcePlayhead)
            if let clip = value.selectedClip {
                let changedStart = clip.start != original?.start
                playing = false; player.pause()
                boundaryPreviewTime = changedStart ? clip.start : max(clip.start, clip.end - value.frameDuration)
                pendingSourceTime = boundaryPreviewTime; seekRevision += 1; startPendingSeek()
            }
        } catch { self.error = error.localizedDescription }
    }
    func setPreset(_ preset: String) {
        guard !saveState.isActive else { return }
        endEditGesture(); beginEditGesture()
        cropPreset = preset == "Произвольный" ? "auto" : preset; cropEditing = true
        let ratio: Double?
        switch preset { case "1:1": ratio = 1; case "4:3": ratio = 4.0 / 3; case "16:9": ratio = 16.0 / 9; case "3:4": ratio = 3.0 / 4; case "9:16": ratio = 9.0 / 16; default: ratio = nil }
        if let ratio { change { try $0.setAspect(ratio) } }
        endEditGesture()
    }
    func setFreeAspect(_ aspect: Double) {
        guard !saveState.isActive else { return }
        let ownGesture = gestureState == nil
        if ownGesture { beginEditGesture() }
        cropPreset = "auto"; change { try $0.setAspect(aspect) }
        if ownGesture { endEditGesture() }
    }
    func toggleMute() {
        guard hasAudio, !saveState.isActive else { return }
        let before = editState(); mute.toggle(); saved = false; refreshPreview(); recordEdit(before)
    }
    func panImage(dx: Double, dy: Double, width: Double, height: Double) {
        guard let crop = timeline?.selectedClip?.crop else { return }
        change { $0.panSelected(dx: -dx / max(1, width) * crop.width, dy: -dy / max(1, height) * crop.height) }
    }
    func zoomImage(factor: Double) { change { try $0.zoomSelected(factor: factor) } }
    func toggleCrop() { guard !saveState.isActive else { return }; cropEditing.toggle(); playing = false; player.pause(); if cropEditing, let timeline { seek(to: timeline.selectedOutputStart) } }
    func save(in queue: ConversionQueue, bitrate: Bitrate) {
        guard !saveState.isActive else { return }
        if let validationError { error = validationError; return }
        endEditGesture(); stop()
        let request = ConversionRequest(action: .convert, files: [url], bitrate: bitrate, edits: plan)
        saveQueue = queue
        saveObserver = queue.$jobs.sink { [weak self] jobs in
            guard let self else { return }
            let previousState = self.saveJob?.state
            let previousError = self.saveJob?.error
            self.saveJob = jobs.last { $0.batchID == request.id }
            if let job = self.saveJob {
                if job.state == .failed, job.state != previousState || job.error != previousError { self.error = job.error; self.saved = false }
                if job.state == .cancelled { self.saved = false }
            }
        }
        persistenceObserver = queue.$persistenceError.sink { [weak self] message in
            if let message { self?.error = message }
        }
        do { try queue.enqueue(request, presentation: .editor); saved = true; error = nil }
        catch { saveObserver = nil; saveJob = nil; saved = false; self.error = error.localizedDescription }
    }
    func cancelSave() {
        guard let job = saveJob, !job.state.isTerminal else { return }
        saveQueue?.cancel(job.id)
    }
    func stop() {
        seekTask?.cancel(); seekTask = nil; pendingSourceTime = nil; seekRevision += 1
        player.currentItem?.cancelPendingSeeks(); player.pause(); playing = false
    }
    var canReset: Bool {
        guard !saveState.isActive, let info, let timeline else { return false }
        let clip = timeline.clips.first
        let original = timeline.clips.count == 1 && clip?.start == 0 && abs((clip?.duration ?? 0) - info.duration) < 0.000001
            && clip?.crop == CropRect(x: 0, y: 0, width: 1, height: 1) && abs(timeline.aspect - timeline.sourceAspect) < 0.000001
        return !original || mute || cropPreset != "auto" || timelineZoom != 1 || sourcePlayhead != 0 || playing || boundaryPreviewTime != nil || error != nil
    }
    func reset() {
        guard canReset, let info else { return }
        endEditGesture()
        let before = editState(includeDisplayZoom: true)
        do { timeline = try ClipTimeline(duration: info.duration, aspect: Double(info.displayWidth) / Double(info.displayHeight), frameDuration: 1 / Double(max(1, info.nominalFrameRate))) }
        catch { self.error = error.localizedDescription; return }
        mute = false; cropEditing = false; cropPreset = "auto"; timelineZoom = 1; saved = false; error = nil
        refreshPreview(); seek(to: 0); recordEdit(before, force: true)
    }
    func thumbnail(at sourceTime: Double) -> NSImage? {
        guard let duration = info?.duration, !thumbnails.isEmpty else { return nil }
        return thumbnails[min(thumbnails.count - 1, max(0, Int(sourceTime / duration * 16)))]
    }
    private func selectVisibleClip(at time: Double) {
        guard let value = timeline else { return }
        var cursor = 0.0
        for clip in value.clips {
            if time < cursor + clip.duration { if value.selectedID != clip.id { timeline?.select(clip.id) }; return }
            cursor += clip.duration
        }
    }
    private func generateThumbnails(duration: Double) {
        imageTask = Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = NSSize(width: 160, height: 100)
            for index in 0..<16 {
                guard !Task.isCancelled else { generator.cancelAllCGImageGeneration(); return }
                do {
                    let image = try await generator.image(at: CMTime(seconds: duration * (Double(index) + 0.5) / 16, preferredTimescale: 600)).image
                    thumbnails.append(NSImage(cgImage: image, size: .zero))
                } catch { return }
            }
        }
    }
}
