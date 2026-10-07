import AVFoundation
import CoreImage
import Metal
import UIKit

/// プレビュー・録画・写真に共通する、現在の撮影設定
struct CaptureSettings {
    var mode: CaptureMode = .vlog
    var filter: FilterKind = .normal
    var aspect: VideoAspect = .portrait9x16
    var photoTimeEnabled: Bool = true
}

enum CameraError: LocalizedError {
    case noCamera
    case notReady
    case busy

    var errorDescription: String? {
        switch self {
        case .noCamera: return "カメラを起動できませんでした"
        case .notReady: return "カメラの準備ができていません"
        case .busy: return "録画中です"
        }
    }
}

/// AVCaptureSession を管理し、全フレームを加工してプレビュー・録画に流す。
///
/// 構成:
///   カメラ → AVCaptureVideoDataOutput（端末基準で縦向き正立の BGRA フレーム）
///          → FrameRenderer（回転・切り抜き・フィルター・時刻焼き付け）
///          → PreviewSink（画面表示） / MovieRecorder（AVAssetWriter でファイルに書き込み）
///   マイク → AVCaptureAudioDataOutput → MovieRecorder
///   写真   → AVCapturePhotoOutput → PhotoCaptureProcessor（同じ FrameRenderer で加工）
final class CameraService: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let previewSink = PreviewSink()
    let orientationMonitor = OrientationMonitor()

    private let sessionQueue = DispatchQueue(label: "vlogcam.session")
    private let dataQueue = DispatchQueue(label: "vlogcam.data", qos: .userInitiated)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false

    /// 表示上の「1x」に相当する videoZoomFactor（超広角を含む仮想カメラでは 2.0 など）
    private var baseZoomFactor: CGFloat = 1

    private let renderer = FrameRenderer()
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    // メインスレッドから更新され、データキューから読まれる値
    private let stateLock = NSLock()
    private var _settings = CaptureSettings()
    private var _position: AVCaptureDevice.Position = .back

    var settings: CaptureSettings {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _settings }
        set { stateLock.lock(); _settings = newValue; stateLock.unlock() }
    }

    private var position: AVCaptureDevice.Position {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _position }
        set { stateLock.lock(); _position = newValue; stateLock.unlock() }
    }

    // ここから下はデータキュー専用
    private struct ActiveRecording {
        let recorder: MovieRecorder
        let spec: RenderSpec
        let completion: (Result<URL, Error>) -> Void
        var stopRequested = false
    }

    private var activeRecording: ActiveRecording?
    private var lastSourceSize: CGSize?

    // セッションキュー専用
    private var photoProcessors: [Int64: PhotoCaptureProcessor] = [:]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
    }

    // MARK: - Session

    /// セッションを構成して起動する。completion はメインスレッドで呼ばれる。
    func start(includeAudio: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        orientationMonitor.start()
        sessionQueue.async {
            do {
                if !self.isConfigured {
                    try self.configureSession(includeAudio: includeAudio)
                    self.isConfigured = true
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSession(includeAudio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1920x1080

        guard let device = Self.bestDevice(for: .back) else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.noCamera }
        session.addInput(input)
        videoDeviceInput = input
        position = .back

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.noCamera }
        session.addOutput(videoOutput)

        if includeAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput),
           session.canAddOutput(audioOutput) {
            session.addInput(micInput)
            audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
            session.addOutput(audioOutput)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        applyDeviceDefaults(device)
        configureConnections()
    }

    private static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        if position == .back {
            types = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        } else {
            types = [.builtInWideAngleCamera]
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        ).devices
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return devices.first
    }

    /// ズームの基準値・写真の最大解像度を設定する（セッション構成中に呼ぶ）
    private func applyDeviceDefaults(_ device: AVCaptureDevice) {
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        if hasUltraWide, let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            baseZoomFactor = CGFloat(truncating: first)
        } else {
            baseZoomFactor = 1
        }
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                         min(baseZoomFactor, device.maxAvailableVideoZoomFactor))
            device.unlockForConfiguration()
        }

        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = dimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
    }

    /// すべてのフレームを「端末基準で縦向き正立」に揃える。インカメラは鏡像。
    private func configureConnections() {
        let mirrored = position == .front
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let connection else { continue }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }

    // MARK: - Camera controls

    /// インカメラ / アウトカメラ切り替え。completion(新しいカメラがフラッシュ対応か) はメインスレッドで呼ばれる。
    func switchCamera(completion: @escaping (_ hasFlash: Bool) -> Void) {
        sessionQueue.async {
            let newPosition: AVCaptureDevice.Position = self.position == .back ? .front : .back
            guard let device = Self.bestDevice(for: newPosition),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            if let current = self.videoDeviceInput {
                self.session.removeInput(current)
            }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoDeviceInput = input
                self.position = newPosition
            } else if let current = self.videoDeviceInput {
                self.session.addInput(current)
            }
            if let active = self.videoDeviceInput?.device {
                self.applyDeviceDefaults(active)
            }
            self.configureConnections()
            self.session.commitConfiguration()

            let hasFlash = self.videoDeviceInput?.device.hasFlash ?? false
            DispatchQueue.main.async { completion(hasFlash) }
        }
    }

    /// 表示倍率（1.0 = 標準の広角）でズームする。実際に設定された表示倍率を返す。
    func setZoom(displayFactor: CGFloat, completion: ((CGFloat) -> Void)? = nil) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            let maxFactor = min(device.maxAvailableVideoZoomFactor, self.baseZoomFactor * 10)
            let target = max(device.minAvailableVideoZoomFactor, min(displayFactor * self.baseZoomFactor, maxFactor))
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = target
            device.unlockForConfiguration()
            let display = target / self.baseZoomFactor
            DispatchQueue.main.async { completion?(display) }
        }
    }

    /// 動画撮影中のライト（フラッシュON時）
    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device, device.hasTorch else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            if on, device.isTorchModeSupported(.on) {
                try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else if device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Recording

    /// 録画を開始する。設定・端末の向き・時刻はこの時点の値で固定される。
    /// - Parameters:
    ///   - maxDuration: VLOG では 2 秒。nil の場合は `stopRecording()` まで録画する。
    ///   - timeText: 焼き付ける時刻文字。nil なら焼き付けない。
    ///   - completion: 書き込み完了時にメインスレッドで呼ばれる。
    func startRecording(
        to url: URL,
        maxDuration: Double?,
        timeText: String?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let settings = self.settings
        let orientation = orientationMonitor.current
        dataQueue.async {
            let finish: (Result<URL, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            guard self.activeRecording == nil else { finish(.failure(CameraError.busy)); return }
            guard let sourceSize = self.lastSourceSize else { finish(.failure(CameraError.notReady)); return }

            let spec = Self.makeSpec(
                settings: settings,
                orientation: orientation,
                sourceSize: sourceSize,
                timeText: timeText
            )
            guard let outputSize = spec.outputSize else { finish(.failure(CameraError.notReady)); return }

            let audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                as? [String: Any]
            do {
                let recorder = try MovieRecorder(
                    url: url,
                    outputSize: outputSize,
                    audioSettings: audioSettings,
                    maxDuration: maxDuration.map { CMTime(seconds: $0, preferredTimescale: 600) }
                )
                self.activeRecording = ActiveRecording(recorder: recorder, spec: spec, completion: finish)
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// VIDEO モードの録画停止
    func stopRecording() {
        dataQueue.async {
            self.activeRecording?.stopRequested = true
        }
    }

    private func finishActiveRecording(endTime: CMTime?) {
        guard let recording = activeRecording else { return }
        activeRecording = nil
        recording.recorder.finish(endTime: endTime, completion: recording.completion)
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        dataQueue.async {
            self.finishActiveRecording(endTime: nil)
        }
    }

    // MARK: - Photo

    /// 写真を撮影し、加工済み JPEG データを返す。completion はメインスレッドで呼ばれる。
    func capturePhoto(flash: Bool, timeText: String?, completion: @escaping (Result<Data, Error>) -> Void) {
        var settings = self.settings
        settings.mode = .photo
        let orientation = orientationMonitor.current

        sessionQueue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { completion(.failure(CameraError.notReady)) }
                return
            }

            var spec = Self.makeSpec(
                settings: settings,
                orientation: orientation,
                sourceSize: CGSize(width: 3, height: 4),
                timeText: timeText
            )
            // 写真はセンサー本来の比率（4:3）のまま、切り抜かない
            spec.outputSize = nil

            let photoSettings = AVCapturePhotoSettings()
            photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if flash, self.photoOutput.supportedFlashModes.contains(.on) {
                photoSettings.flashMode = .on
            } else if self.photoOutput.supportedFlashModes.contains(.off) {
                photoSettings.flashMode = .off
            }

            let id = photoSettings.uniqueID
            let processor = PhotoCaptureProcessor(
                spec: spec,
                renderer: self.renderer,
                context: self.ciContext
            ) { [weak self] result in
                self?.sessionQueue.async { self?.photoProcessors[id] = nil }
                DispatchQueue.main.async { completion(result) }
            }
            self.photoProcessors[id] = processor
            self.photoOutput.capturePhoto(with: photoSettings, delegate: processor)
        }
    }

    // MARK: - Render spec

    /// モード・向きに応じて、回転・出力サイズ・フィルター・時刻を決める。
    ///
    /// - VLOG / VIDEO 9:16 : 縦 1080x1920
    /// - VIDEO 16:9 : 横 1920x1080。端末を横に持っていれば全画角、縦持ちなら中央を横長に切り抜く
    /// - PHOTO : 端末の向きに合わせて縦 3:4 / 横 4:3（プレビューもこの比率）
    static func makeSpec(
        settings: CaptureSettings,
        orientation: DeviceOrientation,
        sourceSize: CGSize,
        timeText: String?
    ) -> RenderSpec {
        let shortSide = min(sourceSize.width, sourceSize.height)
        let long169 = (shortSide * 16 / 9 / 2).rounded() * 2
        let long43 = (shortSide * 4 / 3 / 2).rounded() * 2

        let landscapeRotation: RenderSpec.Rotation
        switch orientation {
        case .landscapeLeft: landscapeRotation = .ccw90
        case .landscapeRight: landscapeRotation = .cw90
        default: landscapeRotation = .none
        }

        switch settings.mode {
        case .vlog:
            return RenderSpec(
                filter: settings.filter,
                rotation: .none,
                outputSize: CGSize(width: shortSide, height: long169),
                timeText: timeText
            )
        case .video:
            switch settings.aspect {
            case .portrait9x16:
                return RenderSpec(
                    filter: settings.filter,
                    rotation: .none,
                    outputSize: CGSize(width: shortSide, height: long169),
                    timeText: timeText
                )
            case .landscape16x9:
                return RenderSpec(
                    filter: settings.filter,
                    rotation: landscapeRotation,
                    outputSize: CGSize(width: long169, height: shortSide),
                    timeText: timeText
                )
            }
        case .photo:
            let size = landscapeRotation == .none
                ? CGSize(width: shortSide, height: long43)
                : CGSize(width: long43, height: shortSide)
            return RenderSpec(
                filter: settings.filter,
                rotation: landscapeRotation,
                outputSize: size,
                timeText: timeText
            )
        }
    }

    /// プレビューに表示する時刻（録画していない時）
    private static func liveTimeText(for settings: CaptureSettings) -> String? {
        switch settings.mode {
        case .vlog: return HourLabel.text(for: Date())
        case .video: return nil
        case .photo: return settings.photoTimeEnabled ? HourLabel.text(for: Date()) : nil
        }
    }
}

// MARK: - Sample buffer delegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            activeRecording?.recorder.appendAudio(sampleBuffer)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        lastSourceSize = source.extent.size

        let spec: RenderSpec
        if let recording = activeRecording {
            spec = recording.spec
        } else {
            let settings = self.settings
            spec = Self.makeSpec(
                settings: settings,
                orientation: orientationMonitor.current,
                sourceSize: source.extent.size,
                timeText: Self.liveTimeText(for: settings)
            )
        }

        let frame = renderer.render(source, spec: spec)

        if let recording = activeRecording {
            if recording.stopRequested {
                finishActiveRecording(endTime: time)
            } else if recording.recorder.appendVideo(frame, at: time, context: ciContext) {
                finishActiveRecording(endTime: nil)
            }
        }

        // 横向きに回転して出力するフレームは、縦固定の画面上では元の向きに戻して表示する
        let display: CIImage
        if spec.rotation == .none {
            display = frame
        } else {
            display = frame
                .transformed(by: CGAffineTransform(rotationAngle: spec.rotation.inverse.angle))
                .normalizedToOrigin()
        }
        previewSink.enqueue(display, at: time, context: ciContext)
    }
}
