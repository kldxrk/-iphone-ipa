import UIKit
import ImageIO

/// 素材加载器：在 `AssetSource` 之上再加一层图片解码与缓存。
///
/// 相比 1.1 的两处改进：
///  * 素材可以来自 XP3 封包（不再是"只能读目录里的散文件"）；
///  * 图片经 ImageIO 降采样，不再把 4K 级 CG 按原始尺寸全解进内存——
///    KiriKiri 游戏的背景/立绘常常是 1280×720 起步甚至更大，原样解码很容易吃光内存。
final class AssetLoader {
    let source: AssetSource
    /// 长边像素上限。2732 覆盖到 iPad Pro 12.9" 的物理宽度，再大就是浪费内存。
    private let maxPixelSize: Int
    private let imageCache = NSCache<NSString, UIImage>()

    init(source: AssetSource, maxPixelSize: Int = 2732) {
        self.source = source
        self.maxPixelSize = maxPixelSize
        imageCache.countLimit = 48
        // 只限个数远远不够：48 张 2732×2732 的解码位图约 1.4GB，会被系统直接杀掉。
        // 再按字节数设一道总成本上限，让 NSCache 在内存吃紧前就开始回收。
        imageCache.totalCostLimit = 96 * 1024 * 1024
    }

    var sourceDescription: String { source.sourceDescription }
    var warnings: [String] { source.warnings }

    func contains(_ path: String) -> Bool { source.contains(path) }
    func listFiles() -> [String] { source.listFiles() }

    func data(for path: String) throws -> Data { try source.data(for: path) }
    func fileURL(for path: String) throws -> URL { try source.fileURL(for: path) }

    func image(_ path: String) -> UIImage? {
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        guard let data = try? source.data(for: path),
              let image = AssetLoader.decode(data, maxPixelSize: maxPixelSize) else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        imageCache.setObject(image, forKey: path as NSString, cost: cost)
        return image
    }

    func clearImageCache() { imageCache.removeAllObjects() }

    /// 小图直接解码，大图走缩略图管线降采样。
    static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           max(width, height) <= maxPixelSize {
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
