import AppKit
import AVFoundation
import Combine

@MainActor final class HistoryMediaStore: ObservableObject {
    struct Entry { var available = false; var image: NSImage? }
    @Published private(set) var entries: [URL: Entry] = [:]
    private let cache = NSCache<NSString, NSImage>()
    private var attempted: [URL: String] = [:]
    init() { cache.countLimit = 120; cache.totalCostLimit = 16 * 1_024 * 1_024 }

    static func sourceExists(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
    func refresh(_ urls: [URL]) async {
        let unique = Array(Set(urls))
        let retained = Set(unique)
        entries = entries.filter { retained.contains($0.key) }
        attempted = attempted.filter { retained.contains($0.key) }
        for url in unique {
            let available = Self.sourceExists(url)
            if entries[url]?.available != available {
                var entry = entries[url] ?? Entry(); entry.available = available; entries[url] = entry
                attempted[url] = nil
            }
        }
        // One small frame at a time, only for rows currently on screen.
        for url in unique {
            guard !Task.isCancelled else { return }
            guard entries[url]?.available == true,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { continue }
            // Never download cloud-only sources just to draw the history list.
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current,
               values.ubiquitousItemDownloadingStatus != .downloaded { continue }
            let signature = "\(url.path)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(values.fileSize ?? 0)"
            if attempted[url] == signature { continue }
            if let image = cache.object(forKey: signature as NSString) { entries[url]?.image = image; attempted[url] = signature; continue }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            do {
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { attempted[url] = signature; continue }
                let frame = try await withTaskCancellationHandler {
                    try await generator.image(at: CMTime(seconds: duration / 2, preferredTimescale: 600)).image
                } onCancel: { generator.cancelAllCGImageGeneration() }
                try Task.checkCancellation()
                guard Self.sourceExists(url) else { entries[url]?.available = false; continue }
                let image = NSImage(cgImage: frame, size: .zero)
                cache.setObject(image, forKey: signature as NSString, cost: frame.bytesPerRow * frame.height)
                entries[url]?.image = image
                attempted[url] = signature
            } catch is CancellationError { return }
            catch {
                if Task.isCancelled { return }
                attempted[url] = signature // Keep the native placeholder for unreadable media.
            }
        }
    }
}
