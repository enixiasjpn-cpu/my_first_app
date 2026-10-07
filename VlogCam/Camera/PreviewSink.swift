import AVFoundation
import CoreImage

/// 加工済みフレームを AVSampleBufferDisplayLayer に表示する。
/// 録画・写真と同じ描画結果（フィルター・時刻入り）をそのままプレビューに出すため、
/// AVCaptureVideoPreviewLayer は使わない。
final class PreviewSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _layer: AVSampleBufferDisplayLayer?
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var layer: AVSampleBufferDisplayLayer? {
        get { lock.lock(); defer { lock.unlock() }; return _layer }
        set { lock.lock(); _layer = newValue; lock.unlock() }
    }

    /// カメラのデータキューから呼ぶ
    func enqueue(_ image: CIImage, at time: CMTime, context: CIContext) {
        guard let layer else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }

        let size = CGSize(width: image.extent.width.rounded(), height: image.extent.height.rounded())
        guard size.width > 0, size.height > 0, let pixelBuffer = makePixelBuffer(size: size) else { return }

        context.render(image, to: pixelBuffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        renderer.enqueue(sampleBuffer)
    }

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                attributes as CFDictionary,
                &newPool
            )
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
