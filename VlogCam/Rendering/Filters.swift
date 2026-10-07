import CoreImage

/// 撮影時に適用するフィルター。
/// 新しいフィルターを追加する場合は `CaptureFilter` に準拠した型を作り、
/// `FilterKind` に case を1つ追加して `filter` で返すだけでよい。
protocol CaptureFilter {
    func apply(to image: CIImage) -> CIImage
}

enum FilterKind: String, Codable, CaseIterable, Identifiable {
    case normal
    case retro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "NORMAL"
        case .retro: return "RETRO"
        }
    }

    var filter: CaptureFilter {
        switch self {
        case .normal: return NormalFilter()
        case .retro: return RetroFilter()
        }
    }

    /// 次のフィルター（上部ボタンのタップで順番に切り替える）
    var next: FilterKind {
        let all = FilterKind.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// 自然な映像（無加工）
struct NormalFilter: CaptureFilter {
    func apply(to image: CIImage) -> CIImage { image }
}

/// インスタントカメラ / フィルムカメラ風。
/// 少し色あせ・黒の浮き・暖色寄り・わずかな甘さ・軽い周辺減光・控えめな粒子。
struct RetroFilter: CaptureFilter {
    func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        // 1080px を基準に、解像度が上がっても見た目の強さが変わらないようにする
        let scale = max(1, min(extent.width, extent.height) / 1080)

        // 1. 彩度とコントラストを少し落とす
        var output = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.78,
            kCIInputContrastKey: 0.95,
            kCIInputBrightnessKey: 0.0,
        ])

        // 2. 黒を少し持ち上げ、白を少し抑える（色あせ感）
        output = output.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.0, y: 0.06),
            "inputPoint1": CIVector(x: 0.25, y: 0.27),
            "inputPoint2": CIVector(x: 0.5, y: 0.52),
            "inputPoint3": CIVector(x: 0.75, y: 0.76),
            "inputPoint4": CIVector(x: 1.0, y: 0.95),
        ])

        // 3. わずかに暖色寄り、青を抑えつつシャドウに少しだけ青みを残す
        output = output.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.04, y: 0.02, z: 0.0, w: 0),
            "inputGVector": CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0),
            "inputBVector": CIVector(x: 0.0, y: 0.03, z: 0.90, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.01, y: 0.005, z: 0.02, w: 0),
        ])

        // 4. ごくわずかに甘く（少し粗い感じ）
        output = output
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 0.6 * scale)
            .cropped(to: extent)

        // 5. 軽い周辺減光
        output = output.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: 0.35,
            kCIInputRadiusKey: 1.6,
        ])

        // 6. 粒子（フレームごとに位置をずらしてフィルムのように揺らぐ）
        output = addGrain(to: output, extent: extent, scale: scale)

        return output.cropped(to: extent)
    }

    private func addGrain(to image: CIImage, extent: CGRect, scale: CGFloat) -> CIImage {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }

        // 0.5 のグレーを中心に振れ幅を小さくしたモノクロノイズ
        let strength: CGFloat = 0.16
        let bias = 0.5 - 0.5 * strength
        let offset = CGAffineTransform(
            translationX: CGFloat.random(in: 0...1000),
            y: CGFloat.random(in: 0...1000)
        )
        let grainScale = 1.5 * scale

        let grain = random
            .transformed(by: offset)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
            ])
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .cropped(to: extent)

        return grain.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image,
        ])
    }
}
