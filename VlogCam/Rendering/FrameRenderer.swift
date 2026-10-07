import CoreImage

/// 1フレームをどう加工するかの指定。
/// 録画中はこの値を録画開始時に固定し、2秒間（または録画終了まで）同じ指定で描画する。
struct RenderSpec {
    enum Rotation {
        case none
        /// 反時計回り 90°
        case ccw90
        /// 時計回り 90°
        case cw90

        var inverse: Rotation {
            switch self {
            case .none: return .none
            case .ccw90: return .cw90
            case .cw90: return .ccw90
            }
        }

        var angle: CGFloat {
            switch self {
            case .none: return 0
            case .ccw90: return .pi / 2
            case .cw90: return -.pi / 2
            }
        }
    }

    var filter: FilterKind
    /// 縦向き（端末基準で正立）のカメラ映像を、出力用にどう回転させるか
    var rotation: Rotation
    /// 最終的な出力サイズ。中央を基準に切り抜いて拡大縮小する。nil の場合は回転後のサイズのまま。
    var outputSize: CGSize?
    /// 焼き付ける時刻文字（"12:00" など）。nil なら焼き付けない。
    var timeText: String?
}

/// カメラ映像 → 回転 → 切り抜き/拡大縮小 → フィルター → 時刻文字の焼き付け
/// を CIImage のグラフとして組み立てる。プレビュー・動画・写真で同じ処理を使うため、
/// 画面で見えるものと保存されるものが一致する。
final class FrameRenderer: @unchecked Sendable {
    private let overlay = TimeOverlayRenderer()

    func render(_ source: CIImage, spec: RenderSpec) -> CIImage {
        var image = source.normalizedToOrigin()

        if spec.rotation != .none {
            image = image
                .transformed(by: CGAffineTransform(rotationAngle: spec.rotation.angle))
                .normalizedToOrigin()
        }

        if let outputSize = spec.outputSize {
            image = image.aspectFilled(to: outputSize)
        }

        image = spec.filter.filter.apply(to: image)

        if let text = spec.timeText {
            image = overlay.composite(text: text, over: image)
        }

        return image
    }
}

extension CIImage {
    /// extent の原点を (0,0) に移動する
    func normalizedToOrigin() -> CIImage {
        let origin = extent.origin
        guard origin != .zero else { return self }
        return transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// 中央を基準に、指定サイズを埋めるよう拡大縮小して切り抜く。結果の原点は (0,0)。
    func aspectFilled(to size: CGSize) -> CIImage {
        let source = normalizedToOrigin()
        let w = source.extent.width
        let h = source.extent.height
        guard w > 0, h > 0 else { return source }

        let scale = max(size.width / w, size.height / h)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = ((scaled.extent.width - size.width) / 2).rounded(.down)
        let y = ((scaled.extent.height - size.height) / 2).rounded(.down)
        return scaled
            .cropped(to: CGRect(x: x, y: y, width: size.width, height: size.height))
            .normalizedToOrigin()
    }
}
