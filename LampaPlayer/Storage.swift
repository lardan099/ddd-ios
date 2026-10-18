import Foundation

/// Позиции просмотра. Lampa не получает прогресс обратно от внешнего плеера на iOS,
/// поэтому источник правды — здесь.
enum ResumeStore {
    private static let key = "resumePositions"
    private static let limit = 500

    private struct Entry: Codable {
        var position: Double
        var duration: Double
        var updated: Date
        var watched: Bool?
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: Entry]) {
        var dict = dict
        if dict.count > limit {
            let stale = dict.sorted { $0.value.updated < $1.value.updated }.prefix(dict.count - limit)
            for (k, _) in stale { dict.removeValue(forKey: k) }
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func position(for key: String) -> Double? {
        load()[key]?.position
    }

    static func progress(for key: String) -> Double? {
        guard let e = load()[key], e.duration > 0 else { return nil }
        if e.watched == true { return 1 }
        return min(max(e.position / e.duration, 0), 1)
    }

    static func store(_ position: Double, duration: Double, for key: String) {
        var dict = load()
        // Досмотрено: дальше начинаем с начала, но прогресс 100% в истории оставляем.
        let watched = duration > 0 && (position > duration - 60 || position / duration > 0.95)
        dict[key] = Entry(position: watched ? 0 : position, duration: duration, updated: Date(), watched: watched)
        save(dict)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var items: [PlayItem]
    var index: Int
    var updated: Date
}

enum HistoryStore {
    private static let key = "history"
    private static let limit = 50

    static func load() -> [HistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return list
    }

    static func record(items: [PlayItem], index: Int) {
        guard items.indices.contains(index) else { return }
        // Одна запись на плейлист: id по первому элементу, чтобы серии одного сезона не плодили строки.
        let id = items[0].resumeKey + "#\(items.count)"
        var list = load().filter { $0.id != id }
        list.insert(HistoryEntry(id: id, title: items[index].displayTitle, items: items, index: index, updated: Date()), at: 0)
        save(Array(list.prefix(limit)))
    }

    static func remove(id: String) {
        save(load().filter { $0.id != id })
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ list: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
