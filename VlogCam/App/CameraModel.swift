import AVFoundation
import Observation
import SwiftUI

/// 撮影画面の状態と操作
@MainActor
@Observable
final class CameraModel {
    enum Authorization {
        case unknown
        case authorized
        case denied
    }

    let service = CameraService()
    private let store: ClipStore

    var authorization: Authorization = .unknown

    var mode: CaptureMode = .vlog { didSet { pushSettings() } }
    var filter: FilterKind = .normal { didSet { pushSettings() } }
    var aspect: VideoAspect = .portrait9x16 { didSet { pushSettings() } }
    var photoTimeEnabled = true { didSet { pushSettings() } }

    var flashOn = false
    var gridOn = false
    var hasFlash = true
    var zoom: CGFloat = 1

    /// VLOG（2秒）または VIDEO の録画中
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    /// 書き出し・保存処理中の短いメッセージ
    var toast: String?

    init(store: ClipStore) {
        self.store = store
        pushSettings()
    }

    private func pushSettings() {
        service.settings = CaptureSettings(
            mode: mode,
            filter: filter,
            aspect: aspect,
            photoTimeEnabled: photoTimeEnabled
        )
    }

    // MARK: - Lifecycle

    func start() async {
        let cameraGranted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraGranted = true
        case .notDetermined: cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        default: cameraGranted = false
        }
        guard cameraGranted else {
            authorization = .denied
            return
        }

        let micGranted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micGranted = true
        case .notDetermined: micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default: micGranted = false
        }

        authorization = .authorized
        service.start(includeAudio: micGranted) { [weak self] result in
            if case .failure(let error) = result {
                self?.showToast(error.localizedDescription)
            }
        }
    }

    // MARK: - Shutter

    func shutterTapped() {
        switch mode {
        case .vlog: recordVlogClip()
        case .video: isRecording ? stopVideo() : startVideo()
        case .photo: takePhoto()
        }
    }

    /// 1タップで2秒録画 → 自動停止 → アプリ内に保存
    private func recordVlogClip() {
        guard !isRecording else { return }
        let id = UUID()
        let startedAt = Date()
        let filter = self.filter
        isRecording = true
        recordingStartedAt = startedAt
        if flashOn { service.setTorch(true) }

        service.startRecording(
            to: ClipStore.newClipURL(id: id),
            maxDuration: VlogConfig.clipDuration,
            timeText: HourLabel.text(for: startedAt)
        ) { [weak self] result in
            guard let self else { return }
            self.isRecording = false
            self.recordingStartedAt = nil
            self.service.setTorch(false)
            switch result {
            case .success:
                self.store.add(Clip(id: id, recordedAt: startedAt, filter: filter))
            case .failure(let error):
                self.showToast(error.localizedDescription)
            }
        }
    }

    private func startVideo() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-\(UUID().uuidString).mov")
        isRecording = true
        recordingStartedAt = Date()
        if flashOn { service.setTorch(true) }

        service.startRecording(to: url, maxDuration: nil, timeText: nil) { [weak self] result in
            guard let self else { return }
            self.isRecording = false
            self.recordingStartedAt = nil
            self.service.setTorch(false)
            switch result {
            case .success(let url):
                Task {
                    do {
                        try await PhotoLibrarySaver.saveVideo(at: url)
                        self.showToast("写真アプリに保存しました")
                    } catch {
                        self.showToast(error.localizedDescription)
                    }
                    try? FileManager.default.removeItem(at: url)
                }
            case .failure(let error):
                self.showToast(error.localizedDescription)
            }
        }
    }

    private func stopVideo() {
        service.stopRecording()
    }

    private func takePhoto() {
        let timeText = photoTimeEnabled ? HourLabel.text(for: Date()) : nil
        service.capturePhoto(flash: flashOn && hasFlash, timeText: timeText) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                Task {
                    do {
                        try await PhotoLibrarySaver.savePhoto(data)
                    } catch {
                        self.showToast(error.localizedDescription)
                    }
                }
            case .failure(let error):
                self.showToast(error.localizedDescription)
            }
        }
    }

    // MARK: - Controls

    func switchCamera() {
        guard !isRecording else { return }
        service.switchCamera { [weak self] hasFlash in
            self?.hasFlash = hasFlash
            self?.zoom = 1
        }
    }

    func setZoom(_ factor: CGFloat) {
        service.setZoom(displayFactor: factor) { [weak self] actual in
            self?.zoom = actual
        }
    }

    func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if self.toast == message { self.toast = nil }
        }
    }
}
