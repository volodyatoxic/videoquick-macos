import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQuickCore

enum HUDMetrics {
    static let width: CGFloat = 600
    static let height: CGFloat = 40
    static let progressWidth = width - 48
}

/// A service HUD: no permanent text or application-management controls.
struct QueueView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: ConversionQueue
    @State private var dropTarget = false
    @State private var detail: HUDSegment?
    @State private var showError = false
    private var segments: [HUDSegment] { model.hudSession.segments(in: queue.jobs, availableWidth: Double(HUDMetrics.progressWidth)) }
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                if let error = model.error ?? queue.persistenceError {
                    Button { showError.toggle() } label: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).help(error).accessibilityLabel(error)
                        .popover(isPresented: $showError) { Text(error).textSelection(.enabled).padding(14).frame(maxWidth: 280) }
                } else if segments.isEmpty {
                    progress(dropTarget ? 1 : 0)
                        .help("Перетащите MOV или MP4").accessibilityLabel("Перетащите видео")
                } else {
                    ForEach(segments) { segment in
                        Button {
                            if queue.needsRecovery { queue.resume() }
                            else { detail = segment }
                        } label: {
                            progress(segment.progress)
                                .colorMultiply(segment.failed ? .red : segment.completed ? .green : .white)
                                .frame(width: CGFloat(segment.width), height: 20)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(description(segment)).accessibilityLabel(description(segment))
                    }
                }
            }.frame(width: HUDMetrics.progressWidth)
            Button { model.cancelAndHide() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 20, height: 20)
            }.buttonStyle(.plain).help("Отменить").accessibilityLabel("Отменить обработку")
        }
        .padding(10).frame(width: HUDMetrics.width, height: HUDMetrics.height).background(.regularMaterial)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.chooseBitrate(for: urls)
            return true
        } isTargeted: { dropTarget = $0 }
        .popover(item: $detail, arrowEdge: .top) { segment in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(segment.jobs) { snapshot in
                        let job = queue.jobs.first { $0.id == snapshot.id } ?? snapshot
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.sourceURL.lastPathComponent).font(.headline).lineLimit(2)
                            if let error = job.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                            HStack {
                                if let output = job.outputURL { Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                                if job.state == .failed || job.state == .cancelled { Button("Повторить") { detail = nil; do { try queue.retry(job.id) } catch { model.error = error.localizedDescription } } }
                                if !job.state.isTerminal { Button("Отменить") { queue.cancel(job.id); detail = nil } }
                            }
                        }
                    }
                }.padding(14)
            }.frame(width: 280, height: min(260, CGFloat(segment.jobs.count) * 100 + 28))
        }
    }
    @ViewBuilder private func progress(_ value: Double) -> some View {
        if value <= 0 {
            // AppKit's native zero-progress fill has a visible minimum cap.
            // Waiting files show only the track, with no implied progress.
            Capsule().fill(.quaternary).frame(height: 6)
        } else {
            ProgressView(value: value).progressViewStyle(.linear).controlSize(.small)
        }
    }
    private func description(_ segment: HUDSegment) -> String {
        if queue.needsRecovery { return "Очередь приостановлена. Нажмите, чтобы продолжить." }
        return segment.jobs.map { job in
            let state: String
            switch job.state { case .waiting: state = "В очереди"; case .running: state = "\(Int(job.progress * 100))%"; case .completed: state = "Готово"; case .failed: state = job.error ?? "Ошибка"; case .cancelled: state = "Отменено" }
            return "\(job.sourceURL.lastPathComponent) · \(job.bitrate.label) · \(state)"
        }.joined(separator: "\n")
    }
}
