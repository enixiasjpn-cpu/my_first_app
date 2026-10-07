import AVFoundation

enum MovieRecorderError: LocalizedError {
    case noFrames
    case writerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noFrames: return "映像を記録できませんでした"
        case .writerFailed(let error): return error?.localizedDescription ?? "動画の書き出しに失敗しました"
        }
    }
}

/// 加工済みフレーム（時刻・フィルター適用後）と音声を AVAssetWriter で動画ファイルに書き込む。
/// すべてのメソッドはカメラのデータキュー上から呼ぶこと。
final class MovieRecorder {
    let url: URL
    let outputSize: CGSize
    /// 指定した場合、最初のフレームからこの長さに達した時点で書き込みをやめる（VLOGの2秒）
    let maxDuration: CMTime?

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    private(set) var startTime: CMTime?
    private var lastVideoTime: CMTime?
    private(set) var isFinishing = false

    init(url: URL, outputSize: CGSize, audioSettings: [String: Any]?, maxDuration: CMTime?) throws {
        self.url = url
        self.outputSize = outputSize
        self.maxDuration = maxDuration

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 6,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
            ] as [String: Any],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )

        guard writer.canAdd(videoInput) else { throw MovieRecorderError.writerFailed(nil) }
        writer.add(videoInput)

        if let audioSettings,
           writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
    }

    /// 最初のフレームから maxDuration に達したか（VLOG の2秒）
    func hasReachedMaxDuration(at time: CMTime) -> Bool {
        guard let maxDuration, let startTime else { return false }
        return CMTimeCompare(CMTimeSubtract(time, startTime), maxDuration) >= 0
    }

    /// 加工済みフレーム（時刻・フィルター適用後）を1枚書き込む
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !isFinishing else { return }

        if startTime == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        guard !hasReachedMaxDuration(at: time),
              writer.status == .writing,
              videoInput.isReadyForMoreMediaData else { return }

        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing,
              let audioInput,
              let startTime,
              writer.status == .writing,
              audioInput.isReadyForMoreMediaData else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(time, startTime) >= 0 else { return }
        if let maxDuration,
           CMTimeCompare(time, CMTimeAdd(startTime, maxDuration)) >= 0 { return }
        audioInput.append(sampleBuffer)
    }

    /// 書き込みを終了する。endTime を省略すると最後のフレーム + 1フレーム分で終わる。
    func finish(endTime: CMTime? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true

        guard let startTime, lastVideoTime != nil, writer.status == .writing else {
            writer.cancelWriting()
            completion(.failure(MovieRecorderError.noFrames))
            return
        }

        let frameDuration = CMTime(value: 1, timescale: 30)
        var end = endTime ?? CMTimeAdd(lastVideoTime!, frameDuration)
        if let maxDuration {
            end = CMTimeMinimum(end, CMTimeAdd(startTime, maxDuration))
        }
        writer.endSession(atSourceTime: end)
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        let writer = self.writer
        let url = self.url
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(MovieRecorderError.writerFailed(writer.error)))
            }
        }
    }
}
