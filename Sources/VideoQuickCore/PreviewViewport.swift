import Foundation

/// Source display rect in a top-left-origin viewport, using export CropRect units.
public enum PreviewViewport {
    public static func frame(crop: CropRect, size: CGSize) -> CGRect {
        guard crop.isValid, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let width = size.width / crop.width, height = size.height / crop.height
        return CGRect(x: -crop.x * width, y: -crop.y * height, width: width, height: height)
    }
}
