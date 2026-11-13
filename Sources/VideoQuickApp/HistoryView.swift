import SwiftUI
import AppKit
import Combine
import VideoQuickCore

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: ConversionQueue
    @StateObject private var media = HistoryMediaStore()
    @State private var visibleIDs = Set<UUID>()
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var recentJobs: [ConversionJob] { HistoryWindow.recentJobs(from: queue.jobs, now: now) }
    private var visibleSources: [URL] { Array(Set(recentJobs.filter { visibleIDs.contains($0.id) }.map(\.sourceURL))).sorted { $0.path < $1.path } }

    var body: some View {
        VStack(spacing: 0) {
            if queue.needsRecovery && queue.hasWork {
                HStack { Spacer(); Button("Продолжить") { model.resumeQueue() } }.padding(12)
            }
            if let error = model.error ?? queue.persistenceError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            List(recentJobs) { job in
                let available = media.entries[job.sourceURL]?.available ?? HistoryMediaStore.sourceExists(job.sourceURL)
                HStack(spacing: 12) {
                    Image(systemName: symbol(job)).foregroundStyle(color(job)).frame(width: 20).accessibilityLabel(state(job))
                    Group {
                        if let image = media.entries[job.sourceURL]?.image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.quaternary).overlay { Image(systemName: "film").foregroundStyle(.tertiary) }
                        }
                    }.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(statistics(job)).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            .help("\(statistics(job))\nБитрейт видеодорожки из метаданных → выбранный битрейт. Размеры и время измеряются при экспорте.")
                        if let error = job.error {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                        }
                    }.help(job.sourceURL.path)
                    Spacer(minLength: 8)
                    if let output = job.outputURL {
                        Button {
                            guard HistoryMediaStore.sourceExists(job.sourceURL) else { return }
                            NSWorkspace.shared.activateFileViewerSelecting([output])
                        } label: { Image(systemName: "folder") }
                            .help("Показать в Finder").accessibilityLabel("Показать в Finder")
                    }
                    Button { model.reopenHistorySource(job.sourceURL) } label: { Image(systemName: "slider.horizontal.3") }
                        .help("Открыть исходник в редакторе").accessibilityLabel("Открыть исходник в редакторе")
                    if job.state == .failed || job.state == .cancelled {
                        Button {
                            guard HistoryMediaStore.sourceExists(job.sourceURL) else { return }
                            do { try queue.retry(job.id); model.error = nil }
                            catch { model.error = error.localizedDescription }
                        } label: { Image(systemName: "arrow.clockwise") }
                            .help("Повторить").accessibilityLabel("Повторить")
                    } else if !job.state.isTerminal {
                        Button { queue.cancel(job.id) } label: { Image(systemName: "xmark") }
                            .help("Отменить").accessibilityLabel("Отменить")
                    }
                }.buttonStyle(.borderless).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if available { model.reopenHistorySource(job.sourceURL) } }
                    .disabled(!available).saturation(available ? 1 : 0).opacity(available ? 1 : 0.4)
                    .onAppear { visibleIDs.insert(job.id) }.onDisappear { visibleIDs.remove(job.id) }
            }.listStyle(.inset)
                .overlay {
                    if recentJobs.isEmpty { ContentUnavailableView("Нет действий", systemImage: "clock") }
                }
        }
        .onAppear { queue.backfillHistoryStatistics() }
        .task { await queue.backfillSourceBitrates() }
        .onReceive(clock) { date in if model.isHistoryVisible { now = date } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = Date() }
        .task(id: visibleSources) {
            while !Task.isCancelled {
                if model.isHistoryVisible { await media.refresh(visibleSources) }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.chooseBitrate(for: urls); return true }
    }

    private func statistics(_ job: ConversionJob) -> String {
        let source: String
        if let rate = job.sourceBitrateMbps, rate.isFinite, rate > 0 {
            source = "\(rate.formatted(.number.precision(.fractionLength(0...(rate < 1 ? 3 : 1))))) Mbps"
        } else { source = "—" }
        var sizes = "\(fileSize(job.sourceBytes)) → \(fileSize(job.outputBytes))"
        if let percentage = job.savedPercentage { sizes += " (\(percentage.formatted(.number.precision(.fractionLength(0...1))))%)" }
        var parts = ["\(source) → \(job.bitrate.label)", sizes]
        if let elapsed = job.exportElapsedSeconds, elapsed.isFinite, elapsed >= 0 {
            parts.append("\(elapsed.formatted(.number.precision(.fractionLength(0...1)))) с")
        } else { parts.append("— с") }
        return parts.joined(separator: " · ")
    }
    private func fileSize(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func state(_ job: ConversionJob) -> String {
        switch job.state {
        case .waiting: return queue.needsRecovery ? "Приостановлено" : "В очереди"
        case .running: return "\(Int(job.progress * 100))%"
        case .completed: return "Готово"
        case .failed: return "Ошибка"
        case .cancelled: return "Отменено"
        }
    }
    private func symbol(_ job: ConversionJob) -> String {
        switch job.state {
        case .waiting: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
    private func color(_ job: ConversionJob) -> Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .red
        case .running: return .accentColor
        default: return .secondary
        }
    }
}
