import AVFoundation

enum VlogComposerError: LocalizedError {
    case noClips
    case exportFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noClips: return "保存できる動画がありません"
        case .exportFailed(let error): return error?.localizedDescription ?? "VLOGの書き出しに失敗しました"
        }
    }
}

/// その日のクリップを撮影順にそのまま連結して1本の動画にする。
/// トランジション・エフェクト・速度変更は一切なし（動画1 → 動画2 → 動画3 …）。
/// 各クリップの映像には時刻が焼き付け済みなので、連結後もそれぞれの時刻が残る。
enum VlogComposer {
    static func concatenate(_ urls: [URL], to outputURL: URL) async throws {
        guard !urls.isEmpty else { throw VlogComposerError.noClips }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VlogComposerError.exportFailed(nil) }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var hasAudio = false

        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let videoRange = try await sourceVideo.load(.timeRange)
            try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: cursor)

            if let audioTrack, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange)
                let range = CMTimeRangeGetIntersection(videoRange, otherRange: audioRange)
                if CMTimeCompare(range.duration, .zero) > 0 {
                    let offset = CMTimeSubtract(range.start, videoRange.start)
                    try audioTrack.insertTimeRange(range, of: sourceAudio, at: CMTimeAdd(cursor, offset))
                    hasAudio = true
                }
            }

            cursor = CMTimeAdd(cursor, videoRange.duration)
        }

        guard CMTimeCompare(cursor, .zero) > 0 else { throw VlogComposerError.noClips }
        if !hasAudio, let audioTrack {
            composition.removeTrack(audioTrack)
        }

        // 再エンコードせずにそのままつなぐ。失敗した場合のみ高画質で再エンコードする。
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: outputURL)
        } catch {
            try await export(composition, preset: AVAssetExportPresetHighestQuality, to: outputURL)
        }
    }

    private static func export(_ asset: AVAsset, preset: String, to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VlogComposerError.exportFailed(nil)
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        await session.export()
        guard session.status == .completed else {
            throw VlogComposerError.exportFailed(session.error)
        }
    }
}
