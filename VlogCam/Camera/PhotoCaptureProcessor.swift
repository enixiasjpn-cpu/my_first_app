import AVFoundation
import CoreImage

/// 撮影した写真に、プレビューと同じ処理（向き・フィルター・時刻）を適用して JPEG データにする。
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let spec: RenderSpec
    private let renderer: FrameRenderer
    private let context: CIContext
    private let completion: (Result<Data, Error>) -> Void
    private var result: Result<Data, Error>?

    init(
        spec: RenderSpec,
        renderer: FrameRenderer,
        context: CIContext,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        self.spec = spec
        self.renderer = renderer
        self.context = context
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            result = .failure(error)
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            result = .failure(PhotoError.processingFailed)
            return
        }

        let rendered = renderer.render(image, spec: spec)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let jpeg = context.jpegRepresentation(
            of: rendered,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        ) else {
            result = .failure(PhotoError.processingFailed)
            return
        }
        result = .success(jpeg)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error, result == nil {
            result = .failure(error)
        }
        completion(result ?? .failure(PhotoError.processingFailed))
    }
}

enum PhotoError: LocalizedError {
    case processingFailed

    var errorDescription: String? { "写真の処理に失敗しました" }
}
