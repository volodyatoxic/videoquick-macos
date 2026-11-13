import Foundation
import Combine
import AVFoundation

@MainActor public final class ConversionQueue: ObservableObject {
    @Published public private(set) var jobs: [ConversionJob] = []
    @Published public private(set) var needsRecovery = false
    @Published public private(set) var persistenceError: String?
    private let storeURL: URL
    private let exporter: any Exporting
    private var received = Set<UUID>()
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private struct Snapshot: Codable { var jobs: [ConversionJob]; var received: Set<UUID> }
    public init(storeURL: URL, exporter: any Exporting) {
        self.storeURL = storeURL; self.exporter = exporter
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: storeURL))
                let importedAt = Date()
                var importedLegacy = false
                jobs = snapshot.jobs.map { job in
                    var j = job
                    if j.createdAt == nil && j.historyImportedAt == nil { j.historyImportedAt = importedAt; importedLegacy = true }
                    if !j.state.isTerminal { j.state = .waiting; j.progress = 0 }
                    return j
                }
                received = snapshot.received
                needsRecovery = jobs.contains { !$0.state.isTerminal }
                if importedLegacy { save() }
            } catch { persistenceError = "Не удалось прочитать сохранённую очередь: \(error.localizedDescription)" }
        }
        backfillHistoryStatistics()
    }
    public var hasWork: Bool { jobs.contains { !$0.state.isTerminal } }
    public var activeJob: ConversionJob? { jobs.first { $0.state == .running } }
    public func setDuration(for url: URL, duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        for i in jobs.indices where jobs[i].sourceURL == url {
            if let ranges = try? jobs[i].edits.retainedRanges(duration: duration) { jobs[i].duration = ranges.reduce(0) { $0 + $1.duration } }
        }
    }
    public func enqueue(_ request: ConversionRequest, presentation: JobPresentation = .compact) throws {
        try request.validate()
        guard request.action == .convert, let bitrate = request.bitrate else { throw VideoQuickError("Это запрос редактора, а не конвертации.") }
        guard !received.contains(request.id) else { return }
        let old = jobs
        jobs += request.files.map {
            var job = ConversionJob(batchID: request.id, sourceURL: $0, bitrate: bitrate, edits: request.edits ?? EditPlan(), createdAt: request.createdAt ?? Date())
            job.presentation = presentation
            return job
        }
        received.insert(request.id)
        do { try persist() } catch { jobs = old; received.remove(request.id); throw error }
        startNext()
    }
    public func resume() { needsRecovery = false; startNext() }
    public func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].state.isTerminal else { return }
        jobs[i].state = .cancelled
        if activeID == id { worker?.cancel() }
        save()
    }
    public func cancelAll() { for id in jobs.filter({ !$0.state.isTerminal }).map(\.id) { cancel(id) }; needsRecovery = false }
    public func retry(_ id: UUID) throws {
        guard let job = jobs.first(where: { $0.id == id }), job.state.isTerminal else { return }
        try enqueue(ConversionRequest(action: .convert, files: [job.sourceURL], bitrate: job.bitrate, edits: job.edits), presentation: job.presentation ?? .compact)
    }
    public func clearFinished() { jobs.removeAll { $0.state.isTerminal }; save() }
    /// Metadata-only repair for visible legacy history. Never estimates an old elapsed time.
    public func backfillHistoryStatistics() {
        var changed = false
        for i in jobs.indices.suffix(100) where jobs[i].state.isTerminal {
            if jobs[i].sourceBytes == nil, let bytes = Self.fileSize(at: jobs[i].sourceURL) {
                jobs[i].sourceBytes = bytes; changed = true
            }
            if jobs[i].state == .completed, jobs[i].outputBytes == nil, let output = jobs[i].outputURL,
               let bytes = Self.fileSize(at: output) {
                jobs[i].outputBytes = bytes; changed = true
            }
        }
        if changed { save() }
    }
    public func backfillSourceBitrates() async {
        let sources = Set(jobs.suffix(100).filter { $0.state.isTerminal && $0.sourceBitrateMbps == nil }.map(\.sourceURL))
        var rates: [URL: Double] = [:]
        for source in sources {
            guard !Task.isCancelled else { return }
            if let rate = await Self.sourceBitrate(at: source) { rates[source] = rate }
        }
        // Merge into current state after awaits so progress/new jobs are never replaced.
        var changed = false
        for index in jobs.indices.suffix(100) where jobs[index].sourceBitrateMbps == nil {
            if let rate = rates[jobs[index].sourceURL] { jobs[index].sourceBitrateMbps = rate; changed = true }
        }
        if changed { save() }
    }
    private static func sourceBitrate(at url: URL) async -> Double? {
        guard let size = fileSize(at: url), size > 0 else { return nil }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current,
           values.ubiquitousItemDownloadingStatus != .downloaded { return nil }
        do {
            guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return nil }
            let rate = try await track.load(.estimatedDataRate)
            return rate.isFinite && rate > 0 ? Double(rate) / 1_000_000 : nil
        } catch { return nil }
    }
    private static func fileSize(at url: URL) -> Int64? {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else { return nil }
        return size.int64Value
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Snapshot(jobs: jobs, received: received)).write(to: storeURL, options: .atomic)
        persistenceError = nil
    }
    private func save() { do { try persist() } catch { persistenceError = "Не удалось сохранить очередь: \(error.localizedDescription)" } }
    private func startNext() {
        guard worker == nil, !needsRecovery, let i = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        jobs[i].state = .running; activeID = jobs[i].id
        jobs[i].sourceBytes = Self.fileSize(at: jobs[i].sourceURL)
        jobs[i].outputBytes = nil; jobs[i].exportElapsedSeconds = nil
        save()
        let job = jobs[i]
        worker = Task { [weak self, exporter] in
            let rate = await Self.sourceBitrate(at: job.sourceURL)
            if let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }), self.jobs[index].state == .running {
                self.jobs[index].sourceBitrateMbps = rate
            }
            let clock = ContinuousClock()
            let started = clock.now
            do {
                try Task.checkCancellation()
                let output = try await exporter.export(job) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, let i = self.jobs.firstIndex(where: { $0.id == job.id }), self.jobs[i].state == .running else { return }
                        self.jobs[i].progress = min(1, max(0, progress))
                    }
                }
                let elapsed = started.duration(to: clock.now).components
                if let self, let i = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    // Once atomically published, completion wins a simultaneous cancel.
                    self.jobs[i].state = .completed; self.jobs[i].progress = 1; self.jobs[i].outputURL = output
                    self.jobs[i].outputBytes = Self.fileSize(at: output)
                    self.jobs[i].exportElapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                }
            } catch {
                let elapsed = started.duration(to: clock.now).components
                if let self, let i = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[i].state = (error is CancellationError || self.jobs[i].state == .cancelled) ? .cancelled : .failed
                    self.jobs[i].error = self.jobs[i].state == .failed ? error.localizedDescription : nil
                    self.jobs[i].exportElapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                }
            }
            guard let self else { return }
            self.worker = nil; self.activeID = nil; self.save(); self.startNext()
        }
    }
}
