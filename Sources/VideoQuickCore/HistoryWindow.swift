import Foundation

public enum HistoryWindow {
    public static func recentJobs(from jobs: [ConversionJob], now: Date = Date()) -> [ConversionJob] {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        return jobs.reversed().filter { ($0.createdAt ?? $0.historyImportedAt ?? .distantPast) >= cutoff }
    }
}
