import AVFoundation

public struct MediaInfo {
    public let duration: Double
    public let width: Int, height: Int, displayWidth: Int, displayHeight: Int
    public let codec: String
    public let transform: CGAffineTransform
    public let isHDR: Bool
    public let bitDepth: Int
    public let nominalFrameRate: Float
}
public enum MediaInspector {
    public static func inspect(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        guard url.isFileURL, ["mov", "mp4"].contains(url.pathExtension.lowercased()) else { throw VideoQuickError("Поддерживаются локальные MOV и MP4.") }
        guard !(try await asset.load(.hasProtectedContent)) else { throw VideoQuickError("Защищённое видео нельзя конвертировать.") }
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard videos.count == 1, let track = videos.first else { throw VideoQuickError("Нужна ровно одна видеодорожка. Многокамерное/пространственное видео пока не поддерживается.") }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { throw VideoQuickError("Не удалось прочитать видеодорожку.") }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let codec: String
        switch subtype { case kCMVideoCodecType_H264: codec = "H.264"; case kCMVideoCodecType_HEVC: codec = "HEVC"; default: throw VideoQuickError("Кодек исходника пока не поддерживается. Первая версия сохраняет H.264 и HEVC; ProRes не меняется автоматически.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(x: 0, y: 0, width: Int(dimensions.width), height: Int(dimensions.height)).applying(transform)
        let extensions = CMFormatDescriptionGetExtensions(format).map { $0 as NSDictionary } ?? NSDictionary()
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String ?? ""
        let hdr = track.hasMediaCharacteristic(.containsHDRVideo) || transfer.contains("2084") || transfer.contains("HLG") || transfer.contains("2100")
        var depth = (extensions["BitsPerComponent"] as? NSNumber)?.intValue ?? 8
        if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Data] {
            if let config = atoms["hvcC"], config.count > 18 { depth = max(depth, 8 + Int(config[17] & 7)); if config[1] & 31 == 2 { depth = max(depth, 10) } }
            if let config = atoms["avcC"], config.count > 1, ![66,77,88,100].contains(Int(config[1])) { depth = max(depth, 10) }
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, dimensions.width > 0, dimensions.height > 0 else { throw VideoQuickError("Видео повреждено или имеет нулевую длительность.") }
        return MediaInfo(duration: duration, width: Int(dimensions.width), height: Int(dimensions.height), displayWidth: Int(abs(rect.width).rounded()), displayHeight: Int(abs(rect.height).rounded()), codec: codec, transform: transform, isHDR: hdr, bitDepth: depth, nominalFrameRate: try await track.load(.nominalFrameRate))
    }
}
