import CoreImage
import UIKit

/// 撮影時刻を「HH:00」形式（24時間表示・分は常に00）に変換する。
/// 12:03 → "12:00", 12:59 → "12:00", 13:01 → "13:00"
enum HourLabel {
    static func text(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        return String(format: "%02d:00", hour)
    }
}

/// 時刻文字の画像を生成し、フレームの中央に合成する。
/// 生成した文字画像は (文字列, キャンバスサイズ) ごとにキャッシュし、毎フレーム描画し直さない。
final class TimeOverlayRenderer: @unchecked Sendable {
    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    /// `image` の extent は原点 (0,0) であること。
    func composite(text: String, over image: CIImage) -> CIImage {
        let size = image.extent.size
        let overlay = overlayImage(text: text, canvasSize: size)
        return overlay.composited(over: image).cropped(to: image.extent)
    }

    private func overlayImage(text: String, canvasSize: CGSize) -> CIImage {
        let key = "\(text)|\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let rendered = Self.renderText(text, canvasSize: canvasSize)

        lock.lock()
        if cache.count > 16 { cache.removeAll() }
        cache[key] = rendered
        lock.unlock()
        return rendered
    }

    /// 白文字・セミボールド・ごく薄い影。キャンバスの中央に配置した CIImage を返す。
    private static func renderText(_ text: String, canvasSize: CGSize) -> CIImage {
        let shortSide = min(canvasSize.width, canvasSize.height)
        let fontSize = (shortSide * 0.2).rounded()

        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = fontSize * 0.08
        shadow.shadowOffset = .zero

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ])

        let textSize = attributed.size()
        let padding = (fontSize * 0.3).rounded()
        let imageSize = CGSize(
            width: ceil(textSize.width + padding * 2),
            height: ceil(textSize.height + padding * 2)
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let uiImage = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
            attributed.draw(at: CGPoint(x: padding, y: padding))
        }
        guard let cgImage = uiImage.cgImage else { return CIImage.empty() }

        let x = ((canvasSize.width - imageSize.width) / 2).rounded()
        let y = ((canvasSize.height - imageSize.height) / 2).rounded()
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
