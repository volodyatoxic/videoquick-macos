import AppKit
import AVFoundation
import Darwin
import VideoQuickCore

@main struct NativeLongVideoChecks {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let began = Date()
        let document = EditorDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        await document.load()
        guard let info = document.info else { throw Failure(message: document.error ?? "Source did not load") }
        let opening = Date().timeIntervalSince(began)
        for _ in 0..<1000 where document.thumbnails.count < 16 { try await Task.sleep(nanoseconds: 10_000_000) }
        guard document.thumbnails.count == 16 else { throw Failure(message: "Long source failed to generate the bounded filmstrip") }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        document.player.currentItem!.add(output)
        for fraction in [0.1, 0.5, 0.99] {
            let target = info.duration * fraction
            document.seek(to: target)
            var decoded = false
            for _ in 0..<300 {
                var displayed = CMTime.invalid
                if output.copyPixelBuffer(forItemTime: document.player.currentTime(), itemTimeForDisplay: &displayed) != nil,
                   abs(displayed.seconds - target) < 0.05 { decoded = true; break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard decoded else { throw Failure(message: "Random seek failed to decode its target frame on long source") }
        }
        let thumbnailBytes = document.thumbnails.reduce(0) { total, image in
            guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return total }
            return total + frame.bytesPerRow * frame.height
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let peakMiB = Double(usage.ru_maxrss) / 1_048_576
        guard peakMiB < 512 else { throw Failure(message: "Small-resolution duration probe exceeded 512 MiB") }
        print("Duration \(Int(info.duration)) s; open \(String(format: "%.3f", opening)) s; peak resident \(String(format: "%.1f", peakMiB)) MiB; thumbnails \(document.thumbnails.count), \(thumbnailBytes) decoded bytes; random seeks passed")
        document.stop()
    }
}
