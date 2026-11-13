import AppKit
import AVFoundation

@main struct NativeHistoryChecks {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let copy = source.deletingLastPathComponent().appendingPathComponent("availability.mov")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let media = HistoryMediaStore()
        await media.refresh([copy])
        guard media.entries[copy]?.available == true, let image = media.entries[copy]?.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(message: "Existing source has no midpoint preview")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
              color.greenComponent > 0.3, color.redComponent < 0.1, color.blueComponent < 0.1 else {
            throw Failure(message: "Preview is not the green middle of the red/green/blue source")
        }
        guard max(cgImage.width, cgImage.height) <= 160 else { throw Failure(message: "History decoded a full-size frame") }
        await media.refresh([copy])
        guard media.entries[copy]?.image === image else { throw Failure(message: "Unchanged source was decoded again") }
        try FileManager.default.removeItem(at: copy)
        await media.refresh([copy])
        guard media.entries[copy]?.available == false else { throw Failure(message: "Deleted source remains actionable") }
        try FileManager.default.copyItem(at: source, to: copy)
        await media.refresh([copy])
        guard media.entries[copy]?.available == true, media.entries[copy]?.image != nil else { throw Failure(message: "Restored source remains disabled") }
        print("Native history checks passed: midpoint frame, small cached image, source deletion/restoration")
    }
}
