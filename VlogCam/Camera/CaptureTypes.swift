import Foundation

/// 撮影モード
enum CaptureMode: String, CaseIterable, Identifiable {
    case vlog
    case video
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vlog: return "VLOG"
        case .video: return "VIDEO"
        case .photo: return "PHOTO"
        }
    }
}

/// VIDEOモードの出力アスペクト比
enum VideoAspect: String, CaseIterable, Identifiable {
    case portrait9x16
    case landscape16x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait9x16: return "9:16"
        case .landscape16x9: return "16:9"
        }
    }
}

/// 端末の物理的な向き（画面の回転ロックに関係なく加速度センサーで判定）
enum DeviceOrientation {
    case portrait
    case portraitUpsideDown
    /// 端末上部が左側（ホームボタン/インジケータが右側）
    case landscapeLeft
    /// 端末上部が右側
    case landscapeRight

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

/// VLOGクリップの長さ
enum VlogConfig {
    static let clipDuration: Double = 2.0
}
