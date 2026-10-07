import AVKit
import SwiftUI

/// 素材一覧。開くと今日のクリップを表示し、右上から過去の日に移動できる。
struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DayClipsView(date: Date())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("閉じる") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            DayListView()
                        } label: {
                            Image(systemName: "calendar")
                        }
                    }
                }
        }
    }
}

/// 日付ごとの一覧
struct DayListView: View {
    @Environment(ClipStore.self) private var store

    var body: some View {
        List(store.days) { day in
            NavigationLink {
                DayClipsView(date: day.date)
            } label: {
                HStack(spacing: 12) {
                    if let first = day.clips.first {
                        ClipThumbnail(clip: first)
                            .frame(width: 36, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(day.date.formatted(.dateTime.year().month().day()))
                        .font(.headline)
                    Spacer()
                    Text("\(day.clips.count)本")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if store.days.isEmpty {
                ContentUnavailableView("まだ動画がありません", systemImage: "video")
            }
        }
        .navigationTitle("日付")
    }
}

/// 1日分のクリップ一覧（撮影順）。タップで再生、長押しで削除、下のボタンで連結保存。
struct DayClipsView: View {
    let date: Date

    @Environment(ClipStore.self) private var store
    @State private var playing: Clip?
    @State private var isExporting = false
    @State private var message: String?

    private var clips: [Clip] { store.clips(on: date) }
    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack(alignment: .bottom) {
            if clips.isEmpty {
                ContentUnavailableView(
                    "まだ動画がありません",
                    systemImage: "video",
                    description: Text("VLOGモードで撮影すると、ここに追加されます")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(clips) { clip in
                            ClipCell(clip: clip)
                                .onTapGesture { playing = clip }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.delete(clip)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.bottom, 110)
                }
            }

            saveDayButton
        }
        .overlay {
            if let message {
                VStack {
                    ToastView(message: message).padding(.top, 8)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
        .navigationTitle(date.formatted(.dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $playing) { clip in
            ClipPlayerView(clip: clip)
                .environment(store)
        }
    }

    private var saveDayButton: some View {
        Button {
            saveDay()
        } label: {
            HStack(spacing: 8) {
                if isExporting {
                    ProgressView().tint(.black)
                }
                Text(isExporting ? "保存中…" : (isToday ? "今日のVLOGを保存" : "この日のVLOGを保存"))
                if !isExporting, !clips.isEmpty {
                    Text("\(clips.count)本").opacity(0.6)
                }
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.white, in: Capsule())
        }
        .disabled(clips.isEmpty || isExporting)
        .opacity(clips.isEmpty ? 0.4 : 1)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// 撮影順にそのまま連結して写真アプリに保存
    private func saveDay() {
        let urls = clips.map { store.url(for: $0) }
        guard !urls.isEmpty else { return }
        isExporting = true

        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("VLOG-\(stamp).mov")

        Task {
            do {
                try await VlogComposer.concatenate(urls, to: output)
                try await PhotoLibrarySaver.saveVideo(at: output)
                show("写真アプリに保存しました")
            } catch {
                show(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: output)
            isExporting = false
        }
    }

    private func show(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if message == text { message = nil }
        }
    }
}

private struct ClipCell: View {
    let clip: Clip

    var body: some View {
        ClipThumbnail(clip: clip)
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if clip.filter != .normal {
                    Text(clip.filter.displayName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
    }
}

/// クリップのサムネイル（非同期読み込み）
struct ClipThumbnail: View {
    let clip: Clip

    @Environment(ClipStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: clip.id) {
                image = await Thumbnails.image(
                    videoURL: store.url(for: clip),
                    thumbnailURL: store.thumbnailURL(for: clip)
                )
            }
    }
}

/// クリップの再生・個別保存・削除
struct ClipPlayerView: View {
    let clip: Clip

    @Environment(ClipStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VideoPlayer(player: player)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    save()
                } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(.black) }
                        Text("この動画を保存")
                    }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white, in: Capsule())
                }
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .overlay(alignment: .top) {
                if let message {
                    ToastView(message: message).padding(.top, 8)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
            .navigationTitle("\(clip.recordedAt.formatted(.dateTime.month().day())) \(clip.hourLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            player?.pause()
                            store.delete(clip)
                            dismiss()
                        } label: {
                            Label("この動画を削除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .onAppear {
            let player = AVPlayer(url: store.url(for: clip))
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await PhotoLibrarySaver.saveVideo(at: store.url(for: clip))
                show("写真アプリに保存しました")
            } catch {
                show(error.localizedDescription)
            }
            isSaving = false
        }
    }

    private func show(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if message == text { message = nil }
        }
    }
}
