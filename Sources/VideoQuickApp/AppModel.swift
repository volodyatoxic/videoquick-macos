import AppKit
import SwiftUI
import FinderSync
import UniformTypeIdentifiers
import VideoQuickCore
import Combine
import OSLog

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    let queue: ConversionQueue
    @Published var error: String?
    @Published var hudSession = HUDSession(history: [])
    private var queueWindow: NSWindowController?
    private var historyWindow: NSWindowController?
    private let presentationLog = Logger(subsystem: "com.volodyatoxic.VideoQuick", category: "presentation")
    private var observations = Set<AnyCancellable>()
    private var hideTask: Task<Void, Never>?
    private var completionDelay = HUDCompletionDelay()
    private var editorWindow: NSWindowController?
    private var editorSession: EditorSession?
    static var supportDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoQuick") }
    private init() {
        queue = ConversionQueue(storeURL: Self.supportDirectory.appendingPathComponent("queue.json"), exporter: MediaExporter())
        // Clean only temporary paths belonging to persisted, unfinished job IDs.
        for job in queue.jobs where job.state != .completed {
            let temp = job.sourceURL.deletingLastPathComponent().appendingPathComponent(".videoquick-\(job.id.uuidString)").appendingPathExtension(job.sourceURL.pathExtension)
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: job.sourceURL.deletingLastPathComponent().appendingPathComponent(".videoquick-\(job.id.uuidString)"))
        }
        hudSession = HUDSession(history: queue.jobs)
        queue.$jobs.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] jobs in self?.jobsChanged(jobs) }.store(in: &observations)
    }
    func showQueue() {
        presentationLog.notice("Showing compact progress")
        hideTask?.cancel(); completionDelay.clear()
        if queueWindow == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: HUDMetrics.width, height: HUDMetrics.height), styleMask: [.titled, .utilityWindow, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = ""; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
            window.isFloatingPanel = true; window.hidesOnDeactivate = false; window.becomesKeyOnlyIfNeeded = true
            window.isMovableByWindowBackground = true; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
            let content = NSHostingView(rootView: QueueView(model: self, queue: queue)); content.sizingOptions = []
            window.contentView = content; window.setContentSize(NSSize(width: HUDMetrics.width, height: HUDMetrics.height)); window.isReleasedWhenClosed = false
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 18, y: screen.visibleFrame.minY + 18))
            }
            queueWindow = NSWindowController(window: window)
        }
        queueWindow?.window?.orderFrontRegardless()
    }
    func showHistory() {
        presentationLog.notice("Showing recent actions")
        if !queue.hasWork { queueWindow?.window?.orderOut(nil) }
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "VideoQuick"; window.minSize = NSSize(width: 480, height: 300)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            let content = NSHostingView(rootView: HistoryView(model: self, queue: queue)); content.sizingOptions = []
            window.contentView = content; window.setContentSize(NSSize(width: 640, height: 440)); window.center(); window.isReleasedWhenClosed = false
            historyWindow = NSWindowController(window: window)
        }
        historyWindow?.showWindow(nil); historyWindow?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    var isHistoryVisible: Bool { historyWindow?.window?.isVisible == true }
    func reopenHistorySource(_ url: URL) {
        guard HistoryMediaStore.sourceExists(url) else { return }
        showEditor([url])
        // Keep any open montage and select the newly opened original immediately.
        editorSession?.selection = editorSession?.documents.last?.id
    }
    func resumeQueue() { queue.resume(); if !hudSession.jobs(in: queue.jobs).isEmpty { showQueue() } }
    func reopen() {
        if let window = editorWindow?.window, window.isVisible, NSApp.mainWindow === window {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else { showHistory() }
    }
    func chooseFiles() -> [URL] {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.prompt = "Выбрать"
        return panel.runModal() == .OK ? panel.urls : []
    }
    @discardableResult func enqueue(_ request: ConversionRequest) -> Bool {
        do { try queue.enqueue(request); error = nil; showQueue(); return true } catch { self.error = error.localizedDescription; showQueue(); return false }
    }
    private func jobsChanged(_ jobs: [ConversionJob]) {
        let before = hudSession.jobIDs
        hudSession.update(jobs)
        let current = hudSession.jobs(in: jobs)
        if before != hudSession.jobIDs, !current.isEmpty { showQueue() }
        if completionDelay.update(session: hudSession, jobs: jobs) {
            hideTask?.cancel()
            if let ids = completionDelay.jobIDs {
                hideTask = Task {
                    do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
                    guard hudSession.jobIDs == ids, completionDelay.jobIDs == ids else { return }
                    hudSession.dismiss(); completionDelay.clear(); hideTask = nil; queueWindow?.window?.orderOut(nil)
                }
            }
        }
    }
    func cancelAndHide() {
        for job in hudSession.jobs(in: queue.jobs) { queue.cancel(job.id) }
        hideTask?.cancel(); completionDelay.clear(); hudSession.dismiss(); error = nil
        queueWindow?.window?.orderOut(nil)
    }
    func chooseBitrate(for urls: [URL]) {
        hideTask?.cancel(); completionDelay.clear()
        do { try ConversionRequest(action: .edit, files: urls).validate() }
        catch { self.error = error.localizedDescription; showQueue(); return }
        showQueue()
        // Return from the native drop/open event before starting menu tracking.
        DispatchQueue.main.async { [weak self] in self?.presentBitrateMenu(for: urls) }
    }
    private func presentBitrateMenu(for urls: [URL]) {
        guard let view = queueWindow?.window?.contentView else { return }
        let menu = NSMenu()
        for bitrate in Bitrate.allCases {
            let item = NSMenuItem(title: bitrate.label, action: #selector(convertDropped(_:)), keyEquivalent: "")
            item.target = self; item.tag = bitrate.rawValue; item.representedObject = urls; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 10, y: view.bounds.height), in: view)
    }
    @objc private func convertDropped(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], let bitrate = Bitrate(rawValue: sender.tag) else { return }
        enqueue(ConversionRequest(action: .convert, files: urls, bitrate: bitrate))
    }
    func showEditor(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if !queue.hasWork && hudSession.jobIDs.isEmpty { queueWindow?.window?.orderOut(nil) }
        if let session = editorSession, editorWindow?.window?.isVisible == true {
            session.add(urls)
        } else {
            let session = EditorSession(urls: urls); editorSession = session
            editorWindow = EditorWindowController(session: session, model: self)
        }
        editorWindow?.showWindow(nil); editorWindow?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func configureEditor(_ document: EditorDocument) { (editorWindow as? EditorWindowController)?.configure(document: document) }
    func handle(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.isFileURL { files.append(url); continue }
            do {
                _ = try RequestInbox.read(url, directory: RequestInbox.hostDirectory)
                consumePendingRequests()
            } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
                // The same event can arrive after startup already consumed it.
            } catch { self.error = error.localizedDescription; showQueue() }
        }
        if !files.isEmpty {
            chooseBitrate(for: files)
        }
    }
    @discardableResult func consumePendingRequests() -> Bool {
        guard let pending = try? RequestInbox.pending(directory: RequestInbox.hostDirectory) else { return false }
        for received in pending {
            do {
                if received.request.action == .edit { showEditor(received.request.files) }
                else { try queue.enqueue(received.request); error = nil; showQueue() }
                try? FileManager.default.removeItem(at: received.fileURL)
            } catch { self.error = error.localizedDescription; showQueue() }
        }
        return !pending.isEmpty
    }
    func configureFinder() { FIFinderSyncController.showExtensionManagementInterface() }
}
