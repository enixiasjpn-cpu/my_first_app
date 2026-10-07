import Photos

enum PhotoLibraryError: LocalizedError {
    case denied

    var errorDescription: String? {
        "写真アプリへの保存が許可されていません（設定 > VlogCam > 写真）"
    }
}

/// iPhone の写真アプリへ保存する（追加のみの権限を使用）
enum PhotoLibrarySaver {
    static func saveVideo(at url: URL) async throws {
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    static func savePhoto(_ data: Data) async throws {
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    private static func ensureAccess() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.denied
        }
    }
}
