import SwiftUI

/// 撮影画面
/// 上部: フラッシュ・グリッド・フィルター（＋モード別の設定）
/// 中央: プレビュー（時刻入り）
/// 下部: ズーム / モード切り替え / 素材一覧・シャッター・カメラ切り替え
struct CameraScreen: View {
    @Environment(CameraModel.self) private var camera
    @Environment(ClipStore.self) private var store

    @State private var showLibrary = false
    @State private var pinchStartZoom: CGFloat?
    @State private var shutterBlink = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.authorization {
            case .denied:
                PermissionView()
            case .unknown, .authorized:
                cameraContent
            }

            if let toast = camera.toast {
                VStack {
                    ToastView(message: toast)
                        .padding(.top, 64)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: camera.toast)
        .task { await camera.start() }
        .fullScreenCover(isPresented: $showLibrary) {
            LibraryView()
                .environment(store)
        }
    }

    // MARK: - Layout

    private var cameraContent: some View {
        ZStack(alignment: .top) {
            preview

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomControls
            }
        }
    }

    private var preview: some View {
        CameraPreviewView(sink: camera.service.previewSink)
            .aspectRatio(9 / 16, contentMode: .fit)
            .overlay {
                if camera.gridOn { GridOverlay() }
            }
            .overlay {
                Color.white
                    .opacity(shutterBlink ? 0.6 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if camera.isRecording, camera.mode == .video, let start = camera.recordingStartedAt {
                    RecordingTimer(start: start)
                        .padding(.top, 60)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStartZoom == nil { pinchStartZoom = camera.zoom }
                        camera.setZoom((pinchStartZoom ?? 1) * value.magnification)
                    }
                    .onEnded { _ in pinchStartZoom = nil }
            )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            IconButton(
                systemName: camera.flashOn ? "bolt.fill" : "bolt.slash",
                isActive: camera.flashOn
            ) {
                camera.flashOn.toggle()
            }
            .disabled(!camera.hasFlash || camera.isRecording)
            .opacity(camera.hasFlash ? 1 : 0.35)

            IconButton(systemName: "grid", isActive: camera.gridOn) {
                camera.gridOn.toggle()
            }

            Spacer()

            if camera.mode == .video {
                ChipButton(title: camera.aspect.title) {
                    camera.aspect = camera.aspect == .portrait9x16 ? .landscape16x9 : .portrait9x16
                }
                .disabled(camera.isRecording)
            }

            if camera.mode == .photo {
                ChipButton(
                    title: camera.photoTimeEnabled ? "時刻 ON" : "時刻 OFF",
                    systemName: "clock",
                    isActive: camera.photoTimeEnabled
                ) {
                    camera.photoTimeEnabled.toggle()
                }
            }

            ChipButton(title: camera.filter.displayName, isActive: camera.filter != .normal) {
                camera.filter = camera.filter.next
            }
            .disabled(camera.isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            Button {
                camera.setZoom(1)
            } label: {
                Text(zoomText)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            ModePicker(selection: Binding(
                get: { camera.mode },
                set: { camera.mode = $0 }
            ))
            .disabled(camera.isRecording)

            HStack {
                Button {
                    showLibrary = true
                } label: {
                    LibraryThumbnail(clip: store.latestClip)
                }
                .disabled(camera.isRecording)
                .frame(width: 64)

                Spacer()

                ShutterButton(
                    mode: camera.mode,
                    isRecording: camera.isRecording,
                    recordingStartedAt: camera.recordingStartedAt
                ) {
                    if camera.mode == .photo { blink() }
                    camera.shutterTapped()
                }

                Spacer()

                Button {
                    camera.switchCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .disabled(camera.isRecording)
                .frame(width: 64)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var zoomText: String {
        let value = (camera.zoom * 10).rounded() / 10
        if value == value.rounded() {
            return "\(Int(value))x"
        }
        return String(format: "%.1fx", value)
    }

    private func blink() {
        shutterBlink = true
        withAnimation(.easeOut(duration: 0.25)) {
            shutterBlink = false
        }
    }
}

// MARK: - Parts

private struct ModePicker: View {
    @Binding var selection: CaptureMode

    var body: some View {
        HStack(spacing: 28) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(selection == mode ? Color.yellow : Color.white.opacity(0.75))
                }
            }
        }
    }
}

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let recordingStartedAt: Date?
    let action: () -> Void

    private let size: CGFloat = 80

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 5)
                    .frame(width: size, height: size)

                if mode == .vlog, isRecording, let start = recordingStartedAt {
                    TimelineView(.animation) { context in
                        let progress = min(1, context.date.timeIntervalSince(start) / VlogConfig.clipDuration)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: size, height: size)
                    }
                }

                inner
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    @ViewBuilder
    private var inner: some View {
        switch mode {
        case .vlog:
            Circle()
                .fill(Color.red.opacity(isRecording ? 0.5 : 1))
                .frame(width: size - 16, height: size - 16)
        case .video:
            RoundedRectangle(cornerRadius: isRecording ? 8 : (size - 16) / 2)
                .fill(Color.red)
                .frame(width: isRecording ? 32 : size - 16, height: isRecording ? 32 : size - 16)
        case .photo:
            Circle()
                .fill(Color.white)
                .frame(width: size - 16, height: size - 16)
        }
    }
}

private struct LibraryThumbnail: View {
    let clip: Clip?

    var body: some View {
        Group {
            if let clip {
                ClipThumbnail(clip: clip)
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.15))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.8), lineWidth: 1.5))
    }
}

private struct IconButton: View {
    let systemName: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Color.yellow : Color.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
        }
    }
}

private struct ChipButton: View {
    let title: String
    var systemName: String?
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemName {
                    Image(systemName: systemName)
                }
                Text(title)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isActive ? Color.yellow : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.black.opacity(0.35), in: Capsule())
        }
    }
}

private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width
                let h = geometry.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

private struct RecordingTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
        }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
    }
}

private struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 40))
                .foregroundStyle(.white)
            Text("カメラへのアクセスを許可してください")
                .font(.headline)
                .foregroundStyle(.white)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
