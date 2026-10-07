import AVFoundation
import CoreImage
import Metal
import UIKit

/// プレビュー・録画・写真に共通する、現在の撮影設定
struct CaptureSettings {
    var mode: CaptureMode = .vlog
    var filter: FilterKind = .normal
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
///          → FrameRenderer（切り抜き・フィルター・時刻焼き付け）
///          → PreviewSink（画面表示用のバッファに描画）→ 同じバッファを MovieRecorder に書き込み
///   マイク → AVCaptureAudioDataOutput → MovieRecorder
///   写真   → AVCapturePhotoOutput → PhotoCaptureProcessor（同じ FrameRenderer で加工）
///
/// VIDEO モードでは1フレームから 9:16 と 16:9 の2つの出力を作り、2本の動画を同時に書き込む。
final class CameraService: NSObject, @unchecked Sendable {
    /// 出力サイズ（VLOG / VIDEO 共通）
    static let portraitSize = CGSize(width: 1080, height: 1920)
    static let landscapeSize = CGSize(width: 1920, height: 1080)

    let session = AVCaptureSession()
    /// [0] = メイン（VLOG / PHOTO / VIDEO の 9:16）、[1] = VIDEO の 16:9
    let previewSinks = [PreviewSink(), PreviewSink()]
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

    // メインスレッドから更新され、データキュー・セッションキューから読まれる値
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
        /// specs[i] で描画したフレームを recorders[i] に書き込む
        let specs: [RenderSpec]
        let recorders: [MovieRecorder]
        let completion: (Result<[URL], Error>) -> Void
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

        applyPreset()
        applyDeviceDefaults(device)
        configureConnections()
    }

    /// VIDEO モードは 16:9 を縦画面の中央から切り抜くため 4K で取り込み、横動画も 1920x1080 の画質を保つ。
    /// それ以外は 1080p。（セッション構成中に呼ぶ）
    private func applyPreset() {
        if settings.mode == .video, session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else {
            session.sessionPreset = .hd1920x1080
        }
    }

    /// モード切り替え時に取り込み解像度を変更する。completion はメインスレッドで呼ばれる（ズームは 1x に戻る）。
    func updateForModeChange(completion: @escaping () -> Void) {
        sessionQueue.async {
            guard self.isConfigured else { return }
            let wanted: AVCaptureSession.Preset =
                (self.settings.mode == .video && self.session.canSetSessionPreset(.hd4K3840x2160))
                ? .hd4K3840x2160 : .hd1920x1080
            guard self.session.sessionPreset != wanted else { return }

            self.session.beginConfiguration()
            self.applyPreset()
            if let device = self.videoDeviceInput?.device {
                self.applyDeviceDefaults(device)
            }
            self.configureConnections()
            self.session.commitConfiguration()
            DispatchQueue.main.async { completion() }
        }
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
            // 新しいカメラが 4K 非対応でも追加できるよう、一旦 1080p にしてから選び直す
            self.session.sessionPreset = .hd1920x1080
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoDeviceInput = input
                self.position = newPosition
            } else if let current = self.videoDeviceInput {
                self.session.addInput(current)
            }
            self.applyPreset()
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

    /// 現在のモードで録画したときに書き出される動画の本数（VLOG = 1, VIDEO = 2）
    static func outputCount(for mode: CaptureMode) -> Int {
        mode == .video ? 2 : 1
    }

    /// 録画を開始する。設定・時刻はこの時点の値で固定される。
    /// - Parameters:
    ///   - urls: 出力先。VLOG は1つ、VIDEO は [9:16, 16:9] の2つ。
    ///   - maxDuration: VLOG では 2 秒。nil の場合は `stopRecording()` まで録画する。
    ///   - timeText: 焼き付ける時刻文字。nil なら焼き付けない。
    ///   - completion: 書き込み完了時にメインスレッドで呼ばれる。成功した動画の URL を返す。
    func startRecording(
        to urls: [URL],
        maxDuration: Double?,
        timeText: String?,
        completion: @escaping (Result<[URL], Error>) -> Void
    ) {
        let settings = self.settings
        let orientation = orientationMonitor.current
        dataQueue.async {
            let finish: (Result<[URL], Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            guard self.activeRecording == nil else { finish(.failure(CameraError.busy)); return }
            guard let sourceSize = self.lastSourceSize else { finish(.failure(CameraError.notReady)); return }

            let specs = Array(Self.makeSpecs(
                settings: settings,
                orientation: orientation,
                sourceSize: sourceSize,
                timeText: timeText
            ).prefix(urls.count))

            let audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
            do {
                let recorders = try zip(urls, specs).map { url, spec in
                    try MovieRecorder(
                        url: url,
                        outputSize: spec.outputSize ?? Self.portraitSize,
                        audioSettings: audioSettings,
                        maxDuration: maxDuration.map { CMTime(seconds: $0, preferredTimescale: 600) }
                    )
                }
                guard !recorders.isEmpty else { throw CameraError.notReady }
                self.activeRecording = ActiveRecording(specs: specs, recorders: recorders, completion: finish)
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

        let group = DispatchGroup()
        let lock = NSLock()
        var results = [Result<URL, Error>?](repeating: nil, count: recording.recorders.count)
        for (index, recorder) in recording.recorders.enumerated() {
            group.enter()
            recorder.finish(endTime: endTime) { result in
                lock.lock()
                results[index] = result
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: dataQueue) {
            let urls = results.compactMap { try? $0?.get() }
            if !urls.isEmpty {
                recording.completion(.success(urls))
            } else {
                let error: Error = results.compactMap { result -> Error? in
                    if case .failure(let error) = result { return error }
                    return nil
                }.first ?? MovieRecorderError.noFrames
                recording.completion(.failure(error))
            }
        }
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

            guard var spec = Self.makeSpecs(
                settings: settings,
                orientation: orientation,
                sourceSize: CGSize(width: 3, height: 4),
                timeText: timeText
            ).first else { return }
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

    /// モード・向きに応じて、出力ごとの回転・サイズ・フィルター・時刻を決める。
    ///
    /// - VLOG  : [縦 1080x1920]
    /// - VIDEO : [縦 1080x1920, 横 1920x1080]  横は縦画面の中央を切り抜く
    /// - PHOTO : [端末の向きに合わせて縦 3:4 / 横 4:3]（プレビュー用。保存時は切り抜かない）
    static func makeSpecs(
        settings: CaptureSettings,
        orientation: DeviceOrientation,
        sourceSize: CGSize,
        timeText: String?
    ) -> [RenderSpec] {
        switch settings.mode {
        case .vlog:
            return [
                RenderSpec(filter: settings.filter, rotation: .none, outputSize: portraitSize, timeText: timeText),
            ]
        case .video:
            return [
                RenderSpec(filter: settings.filter, rotation: .none, outputSize: portraitSize, timeText: timeText),
                RenderSpec(filter: settings.filter, rotation: .none, outputSize: landscapeSize, timeText: timeText),
            ]
        case .photo:
            let rotation: RenderSpec.Rotation
            switch orientation {
            case .landscapeLeft: rotation = .ccw90
            case .landscapeRight: rotation = .cw90
            default: rotation = .none
            }
            let shortSide = min(sourceSize.width, sourceSize.height)
            let long43 = (shortSide * 4 / 3 / 2).rounded() * 2
            let size = rotation == .none
                ? CGSize(width: shortSide, height: long43)
                : CGSize(width: long43, height: shortSide)
            return [
                RenderSpec(filter: settings.filter, rotation: rotation, outputSize: size, timeText: timeText),
            ]
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
        } else if output === audioOutput, let recording = activeRecording {
            for recorder in recording.recorders {
                recorder.appendAudio(sampleBuffer)
            }
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        lastSourceSize = source.extent.size

        // 停止要求・2秒到達ならこのフレームは書き込まずに終了
        if let recording = activeRecording {
            if recording.stopRequested {
                finishActiveRecording(endTime: time)
            } else if recording.recorders.first?.hasReachedMaxDuration(at: time) == true {
                finishActiveRecording(endTime: nil)
            }
        }

        let recording = activeRecording
        let specs: [RenderSpec]
        if let recording {
            specs = recording.specs
        } else {
            let settings = self.settings
            specs = Self.makeSpecs(
                settings: settings,
                orientation: orientationMonitor.current,
                sourceSize: source.extent.size,
                timeText: Self.liveTimeText(for: settings)
            )
        }

        for (index, spec) in specs.enumerated() where index < previewSinks.count {
            let frame = renderer.render(source, spec: spec)
            let sink = previewSinks[index]

            if spec.rotation == .none {
                // プレビュー用に描画したバッファをそのまま動画にも書き込む（画面と保存内容が完全に一致）
                let buffer = sink.render(frame, at: time, context: ciContext)
                if let recording, index < recording.recorders.count, let buffer {
                    recording.recorders[index].appendVideo(buffer, at: time)
                }
            } else {
                // 横向きに回転した写真プレビューは、縦固定の画面上では元の向きに戻して表示する
                let display = frame
                    .transformed(by: CGAffineTransform(rotationAngle: spec.rotation.inverse.angle))
                    .normalizedToOrigin()
                sink.render(display, at: time, context: ciContext)
            }
        }
    }
}
