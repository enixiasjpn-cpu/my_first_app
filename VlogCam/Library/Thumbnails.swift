import AVFoundation
import UIKit

/// クリップのサムネイル。初回に動画から切り出して JPEG として保存し、以降はそれを読む。
enum Thumbnails {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(videoURL: URL, thumbnailURL: URL) async -> UIImage? {
        if let cached = cache.object(forKey: thumbnailURL as NSURL) {
            return cached
        }
        if let data = try? Data(contentsOf: thumbnailURL), let image = UIImage(data: data) {
            cache.setObject(image, forKey: thumbnailURL as NSURL)
            return image
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 640)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            let image = UIImage(cgImage: cgImage)
            if let data = image.jpegData(compressionQuality: 0.8) {
                try? data.write(to: thumbnailURL, options: .atomic)
            }
            cache.setObject(image, forKey: thumbnailURL as NSURL)
            return image
        } catch {
            return nil
        }
    }

    static func removeFromCache(_ thumbnailURL: URL) {
        cache.removeObject(forKey: thumbnailURL as NSURL)
    }
}
