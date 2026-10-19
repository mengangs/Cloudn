// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Observation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    var source: String
    var createdAt = Date()
}

/// 收藏的链接与最近解析记录（JSON 文件）
@MainActor
@Observable
final class BookmarkStore {
    private(set) var bookmarks: [Bookmark] = []
    private(set) var history: [Bookmark] = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let historyURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("bookmarks.json")
        historyURL = directory.appendingPathComponent("history.json")
        bookmarks = Self.load(fileURL)
        history = Self.load(historyURL)
    }

    private static func load(_ url: URL) -> [Bookmark] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    func isBookmarked(_ text: String) -> Bool { bookmarks.contains { $0.text == text } }

    func add(title: String, text: String, source: String) {
        guard !isBookmarked(text) else { return }
        bookmarks.insert(Bookmark(title: title, text: text, source: source), at: 0)
        save()
    }

    func remove(_ ids: Set<UUID>) {
        bookmarks.removeAll { ids.contains($0.id) }
        save()
    }

    func toggle(title: String, text: String, source: String) {
        if let existing = bookmarks.first(where: { $0.text == text }) {
            remove([existing.id])
        } else {
            add(title: title, text: text, source: source)
        }
    }

    func rename(_ id: UUID, title: String) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].title = title
        save()
    }

    /// 最近解析：同一链接只保留最新一条，最多 30 条
    func record(title: String, text: String, source: String) {
        history.removeAll { $0.text == text }
        history.insert(Bookmark(title: title, text: text, source: source), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        write(history, to: historyURL)
    }

    func removeHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        write(history, to: historyURL)
    }

    func clearHistory() {
        history = []
        write(history, to: historyURL)
    }

    private func save() { write(bookmarks, to: fileURL) }

    private func write(_ list: [Bookmark], to url: URL) {
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: [.atomic]) }
    }
}
