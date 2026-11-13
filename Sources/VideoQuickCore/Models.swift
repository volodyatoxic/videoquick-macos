import Foundation

public enum Bitrate: Int, Codable, CaseIterable, Identifiable, Sendable {
    case mbps1 = 1, mbps3 = 3, mbps5 = 5, mbps10 = 10, mbps20 = 20
    public var id: Int { rawValue }
    public var bitsPerSecond: Int { rawValue * 1_000_000 }
    public var label: String { "\(rawValue) Mbps" }
}
public struct VideoQuickError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct TimeSpan: Codable, Equatable, Sendable {
    public let start: Double
    public let duration: Double
    public init(start: Double, duration: Double) { self.start = start; self.duration = duration }
}
public struct ClipEdit: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var start: Double
    public var duration: Double
    public var crop: CropRect
    public var end: Double { start + duration }
    public init(id: UUID = UUID(), start: Double, duration: Double, crop: CropRect = CropRect(x: 0, y: 0, width: 1, height: 1)) {
        self.id = id; self.start = start; self.duration = duration; self.crop = crop
    }
}
/// Normalized rectangle in displayed video coordinates, origin at top-left.
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001 }
}
public enum MetadataPolicy: String, Codable, Sendable { case preserve, discard }
public struct EditPlan: Codable, Equatable, Sendable {
    public var trimStart: Double
    public var trimEnd: Double?
    public var cutStart: Double?
    public var cutEnd: Double?
    public var mute: Bool
    public var crop: CropRect?
    public var clips: [ClipEdit]?
    public var outputAspect: Double?
    /// Nil on legacy jobs means preserve. Editor saves explicitly discard source service metadata.
    public var metadataPolicy: MetadataPolicy?
    public init(trimStart: Double = 0, trimEnd: Double? = nil, cutStart: Double? = nil, cutEnd: Double? = nil, mute: Bool = false, crop: CropRect? = nil, clips: [ClipEdit]? = nil, outputAspect: Double? = nil, metadataPolicy: MetadataPolicy? = nil) {
        self.trimStart = trimStart; self.trimEnd = trimEnd; self.cutStart = cutStart; self.cutEnd = cutEnd; self.mute = mute; self.crop = crop
        self.clips = clips; self.outputAspect = outputAspect; self.metadataPolicy = metadataPolicy
    }
    public var isEdited: Bool { self != EditPlan() }
    public func retainedRanges(duration: Double) throws -> [TimeSpan] {
        if let clips {
            guard duration.isFinite, duration > 0, !clips.isEmpty, trimStart == 0, trimEnd == nil, cutStart == nil, cutEnd == nil,
                  outputAspect.map({ $0.isFinite && $0 > 0 }) ?? true else { throw VideoQuickError("Проверьте фрагменты видео.") }
            var ranges: [TimeSpan] = []
            var previousEnd = 0.0
            for clip in clips {
                guard clip.start.isFinite, clip.duration.isFinite, clip.start >= previousEnd - 0.00000001, clip.duration > 0,
                      clip.end <= duration + 0.000001, clip.crop.isValid else { throw VideoQuickError("Фрагменты должны находиться внутри видео и не перекрываться.") }
                if let last = ranges.last, abs(last.start + last.duration - clip.start) < 0.00000001 {
                    ranges[ranges.count - 1] = TimeSpan(start: last.start, duration: clip.end - last.start)
                } else { ranges.append(TimeSpan(start: clip.start, duration: clip.duration)) }
                previousEnd = clip.end
            }
            return ranges
        }
        let end = trimEnd ?? duration
        guard duration.isFinite, duration > 0, trimStart.isFinite, end.isFinite, trimStart >= 0, trimStart < end, end <= duration + 0.001 else { throw VideoQuickError("Проверьте начало и конец видео.") }
        guard crop?.isValid != false else { throw VideoQuickError("Область кадрирования выходит за границы видео.") }
        guard cutStart != nil || cutEnd != nil else { return [TimeSpan(start: trimStart, duration: end - trimStart)] }
        guard let a = cutStart, let b = cutEnd, a.isFinite, b.isFinite, a >= trimStart, b <= end, a < b else { throw VideoQuickError("Удаляемый фрагмент должен находиться внутри выбранного видео.") }
        let ranges = [TimeSpan(start: trimStart, duration: a - trimStart), TimeSpan(start: b, duration: end - b)].filter { $0.duration > 0.000001 }
        guard !ranges.isEmpty else { throw VideoQuickError("Нельзя удалить всё видео.") }
        return ranges
    }
}
public struct ConversionRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case convert, edit }
    public let id: UUID
    public var action: Action
    public var files: [URL]
    public var bitrate: Bitrate?
    public var edits: EditPlan?
    public var createdAt: Date?
    public init(id: UUID = UUID(), action: Action, files: [URL], bitrate: Bitrate? = nil, edits: EditPlan? = nil, createdAt: Date = Date()) { self.id = id; self.action = action; self.files = files; self.bitrate = bitrate; self.edits = edits; self.createdAt = createdAt }
    public func validate() throws {
        guard !files.isEmpty, files.count <= 20_000, files.allSatisfy({ $0.isFileURL && ["mov","mp4"].contains($0.pathExtension.lowercased()) }) else { throw VideoQuickError("Выберите только локальные файлы MOV или MP4.") }
        guard action != .convert || bitrate != nil else { throw VideoQuickError("Выберите битрейт.") }
    }
}
public enum JobState: String, Codable, Sendable {
    case waiting, running, completed, failed, cancelled
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}
public enum JobPresentation: String, Codable, Sendable { case compact, editor }
public struct ConversionJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let batchID: UUID
    public let sourceURL: URL
    public let bitrate: Bitrate
    public let edits: EditPlan
    /// Actual enqueue/request date; absent in legacy snapshots.
    public var createdAt: Date?
    /// Visibility baseline for undated legacy actions, never an inferred action date.
    public var historyImportedAt: Date?
    public var state: JobState = .waiting
    public var progress: Double = 0
    public var outputURL: URL?
    public var error: String?
    public var duration: Double?
    public var sourceBytes: Int64?
    public var outputBytes: Int64?
    /// Video-track metadata rate; the requested output rate remains `bitrate`.
    public var sourceBitrateMbps: Double?
    /// Measured with a monotonic clock around export; excludes time waiting in FIFO.
    public var exportElapsedSeconds: Double?
    /// Absent on older queues; those jobs retain the compact service presentation.
    public var presentation: JobPresentation?
    public var savedBytes: Int64? {
        guard let sourceBytes, let outputBytes, sourceBytes >= 0, outputBytes >= 0 else { return nil }
        return sourceBytes - outputBytes
    }
    public var savedPercentage: Double? {
        guard let sourceBytes, sourceBytes > 0, let savedBytes else { return nil }
        return Double(savedBytes) / Double(sourceBytes) * 100
    }
    public init(id: UUID = UUID(), batchID: UUID = UUID(), sourceURL: URL, bitrate: Bitrate, edits: EditPlan = EditPlan(), createdAt: Date = Date()) { self.id = id; self.batchID = batchID; self.sourceURL = sourceURL; self.bitrate = bitrate; self.edits = edits; self.createdAt = createdAt }
}
public protocol Exporting: Sendable {
    func export(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
