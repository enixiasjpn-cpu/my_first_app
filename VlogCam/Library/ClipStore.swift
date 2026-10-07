import AVFoundation
import Foundation
import Observation
import UIKit

/// VLOGモードで撮影した2秒クリップ
struct Clip: Codable, Identifiable, Hashable {
    let id: UUID
    /// 撮影開始時刻（並び順と日付・時刻表示の基準）
    let recordedAt: Date
    let filter: FilterKind

    var fileName: String { "\(id.uuidString).mov" }
    var thumbnailName: String { "\(id.uuidString).jpg" }
    var hourLabel: String { HourLabel.text(for: recordedAt) }
}

/// 1日分のクリップ
struct VlogDay: Identifiable, Hashable {
    let date: Date
    let clips: [Clip]
    var id: Date { date }
}

/// クリップをアプリ内（Documents/Clips）に保存し、撮影順・日付単位で管理する。
@Observable
final class ClipStore {
    private(set) var clips: [Clip] = []

    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static var indexURL: URL { directory.appendingPathComponent("clips.json") }

    init() {
        load()
    }

    // MARK: - Query

    /// 日付ごとにまとめたクリップ（新しい日が先、日の中は撮影順）
    var days: [VlogDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: clips) { calendar.startOfDay(for: $0.recordedAt) }
        return grouped
            .map { VlogDay(date: $0.key, clips: $0.value.sorted { $0.recordedAt < $1.recordedAt }) }
            .sorted { $0.date > $1.date }
    }

    /// 指定日のクリップ（撮影順）
    func clips(on date: Date) -> [Clip] {
        let calendar = Calendar.current
        return clips
            .filter { calendar.isDate($0.recordedAt, inSameDayAs: date) }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    var latestClip: Clip? { clips.max { $0.recordedAt < $1.recordedAt } }

    // MARK: - Files

    func url(for clip: Clip) -> URL {
        Self.directory.appendingPathComponent(clip.fileName)
    }

    func thumbnailURL(for clip: Clip) -> URL {
        Self.directory.appendingPathComponent(clip.thumbnailName)
    }

    /// これから録画するクリップの保存先
    static func newClipURL(id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).mov")
    }

    // MARK: - Mutation

    func add(_ clip: Clip) {
        clips.append(clip)
        clips.sort { $0.recordedAt < $1.recordedAt }
        save()
    }

    func delete(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        try? FileManager.default.removeItem(at: url(for: clip))
        try? FileManager.default.removeItem(at: thumbnailURL(for: clip))
        Thumbnails.removeFromCache(thumbnailURL(for: clip))
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([Clip].self, from: data) else { return }
        // ファイルが存在するものだけ残す
        clips = decoded
            .filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}
