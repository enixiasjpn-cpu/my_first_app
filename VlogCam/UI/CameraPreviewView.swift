import AVFoundation
import SwiftUI

/// 加工済みフレーム（フィルター・時刻入り）を表示するプレビュー
struct CameraPreviewView: UIViewRepresentable {
    let sink: PreviewSink

    func makeUIView(context: Context) -> DisplayLayerView {
        let view = DisplayLayerView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        sink.layer = view.displayLayer
        return view
    }

    func updateUIView(_ uiView: DisplayLayerView, context: Context) {
        if sink.layer !== uiView.displayLayer {
            sink.layer = uiView.displayLayer
        }
    }

    final class DisplayLayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }
}
