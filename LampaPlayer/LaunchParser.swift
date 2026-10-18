import Foundation

/// Разбирает ссылки, которыми Lampa на iPhone открывает «внешний плеер»
/// (см. lampa-source: src/interaction/player.js и src/core/infusePlayer.js).
///
///  senplayer://x-callback-url/play?url=<encoded>
///  infuse://x-callback-url/play?url=A&position=120&filename=A.mkv&sub=S&url=B&filename=B.mkv...&x-success=...
///  infuse://x-callback-url/play?url=A&position=120&playlist=[{"url":..,"filename":..}]   (вариант Apple TV)
///  infuse://x-callback-url/save?url=...&x-success=infuse://x-callback-url/play?...      (режим save_and_play)
///  lampaplayer://play?url=<encoded>&title=<encoded>&position=<sec>&sub=<encoded>
enum LaunchParser {
    static func parse(_ url: URL) -> PlaybackRequest? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return PlaybackRequest(items: [PlayItem(url: url.absoluteString)], startIndex: 0, source: "link")
        case "lampaplayer" where url.host?.lowercased() == "lampa":
            return parseLampaPlugin(url)
        case "senplayer", "lampaplayer":
            return parseSingle(url, source: scheme)
        case "infuse":
            return parseInfuse(url)
        default:
            return nil
        }
    }

    /// Ввод руками на главном экране: обычная ссылка или любая из схем выше.
    static func parse(text: String) -> PlaybackRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return parse(url)
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded), url.scheme != nil {
            return parse(url)
        }
        return nil
    }

    private static func parseSingle(_ url: URL, source: String) -> PlaybackRequest? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first(where: { $0.name.lowercased() == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let target = value("url") else { return nil }
        var item = PlayItem(url: target)
        item.title = value("title") ?? value("filename")
        item.sub = value("sub")
        item.position = value("position").flatMap(Double.init)
        return PlaybackRequest(items: [item], startIndex: 0, source: source, successURL: value("x-success"))
    }

    /// lampaplayer://lampa?d=<base64url(JSON)> — от нашего плагина Lampa (plugin/lampa-player.js).
    /// JSON: { v, i, c: {title, original, poster}, items: [{ u, t, s: [{u, l}], g: {a, s, d}, v, h, p }] }
    private static func parseLampaPlugin(_ url: URL) -> PlaybackRequest? {
        guard let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "d" })?.value else { return nil }
        var b64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = root["items"] as? [[String: Any]] else { return nil }

        func number(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let s = any as? String { return Double(s) }
            return nil
        }
        func ranges(_ any: Any?) -> [[Double]] {
            (any as? [[Any]] ?? []).compactMap { pair in
                guard pair.count == 2, let a = number(pair[0]), let b = number(pair[1]), b > a else { return nil }
                return [a, b]
            }
        }

        let items: [PlayItem] = rawItems.compactMap { raw in
            guard let link = raw["u"] as? String, !link.isEmpty else { return nil }
            var item = PlayItem(url: link)
            if let title = raw["t"] as? String, !title.isEmpty { item.title = title }
            if let subs = raw["s"] as? [[String: Any]] {
                let refs = subs.compactMap { s -> SubtitleRef? in
                    guard let u = s["u"] as? String, !u.isEmpty else { return nil }
                    return SubtitleRef(url: u, label: (s["l"] as? String) ?? "")
                }
                if !refs.isEmpty { item.subs = refs }
            }
            if let seg = raw["g"] as? [String: Any] {
                let segments = SkipSegments(ads: ranges(seg["a"]), skips: ranges(seg["s"]),
                                            referenceDuration: (number(seg["d"]) ?? 0) / 1000)
                if !segments.ads.isEmpty || !segments.skips.isEmpty { item.segments = segments }
            }
            if let thumbs = raw["v"] as? String, !thumbs.isEmpty { item.thumbnails = thumbs }
            if let hash = raw["h"] as? String, !hash.isEmpty { item.lampaHash = hash }
            else if let hash = number(raw["h"]) { item.lampaHash = String(Int64(hash)) }
            if let position = number(raw["p"]), position > 0 { item.position = position }
            return item
        }
        guard !items.isEmpty else { return nil }

        // Название сериала из карточки + «Серия N» из плейлиста.
        let show = ((root["c"] as? [String: Any])?["title"] as? String) ?? ""
        let titled = items.map { item -> PlayItem in
            var copy = item
            if !show.isEmpty, let t = copy.title, !t.localizedCaseInsensitiveContains(show), t.count < 40 {
                copy.title = show + " — " + t.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            }
            return copy
        }

        let start = min(max(Int(number(root["i"]) ?? 0), 0), titled.count - 1)
        return PlaybackRequest(items: titled, startIndex: start, source: "lampa-plugin")
    }

    private static func parseInfuse(_ url: URL) -> PlaybackRequest? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = url.path.lowercased()

        // save_and_play: настоящий запуск лежит в x-success.
        if action.hasSuffix("save"),
           let next = query.first(where: { $0.name == "x-success" })?.value,
           next.lowercased().hasPrefix("infuse:"),
           let nextURL = URL(string: next),
           let request = parseInfuse(nextURL) {
            return request
        }

        var items: [PlayItem] = []
        var playlistJSON: String?
        var success: String?

        // Порядок параметров важен: position/filename/sub относятся к последнему url.
        for entry in query {
            let value = entry.value ?? ""
            switch entry.name {
            case "url":
                if !value.isEmpty { items.append(PlayItem(url: value)) }
            case "position":
                if !items.isEmpty, let seconds = Double(value), seconds > 0 { items[items.count - 1].position = seconds }
            case "filename":
                if !items.isEmpty, !value.isEmpty { items[items.count - 1].title = value }
            case "sub":
                if !items.isEmpty, !value.isEmpty { items[items.count - 1].sub = value }
            case "playlist":
                playlistJSON = value
            case "x-success":
                success = value
            default:
                break
            }
        }

        var startIndex = 0

        if items.count <= 1, let playlistJSON, let list = decodePlaylist(playlistJSON), list.count > 1 {
            let current = items.first
            items = list
            if let current, let i = list.firstIndex(where: { $0.url == current.url }) {
                startIndex = i
                if items[i].position == nil { items[i].position = current.position }
                if items[i].sub == nil { items[i].sub = current.sub }
            }
        } else if items.count > 1 {
            // Lampa поворачивает список так, чтобы выбранная серия была первой: 5,6,…,10,1,2,3,4.
            (items, startIndex) = unrotate(items)
        }

        guard !items.isEmpty else { return nil }
        return PlaybackRequest(items: items, startIndex: startIndex, source: "infuse", successURL: success)
    }

    private static func decodePlaylist(_ json: String) -> [PlayItem]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let items = array.compactMap { dict -> PlayItem? in
            guard let url = dict["url"] as? String, !url.isEmpty else { return nil }
            var item = PlayItem(url: url)
            item.title = (dict["filename"] as? String) ?? (dict["title"] as? String)
            return item
        }
        return items.isEmpty ? nil : items
    }

    // MARK: - Возврат исходного порядка серий

    static func unrotate(_ items: [PlayItem]) -> ([PlayItem], Int) {
        let keys = items.map { episodeSortKey($0.displayTitle) ?? episodeSortKey($0.url.removingPercentEncoding ?? $0.url) }
        guard items.count > 1, keys.allSatisfy({ $0 != nil }) else { return (items, 0) }
        let numbers = keys.map { $0! }
        let descents = (1..<numbers.count).filter { numbers[$0] < numbers[$0 - 1] }
        guard descents.count == 1, let k = descents.first, numbers[numbers.count - 1] < numbers[0] else {
            return (items, 0)
        }
        return (Array(items[k...] + items[..<k]), items.count - k)
    }

    private static let seasonEpisode = try! NSRegularExpression(pattern: "[Ss](\\d{1,2})[ ._-]?[Ee](\\d{1,3})")
    private static let episodeOnly = try! NSRegularExpression(
        pattern: "(?:^|[^A-Za-z])(?:[Ee]|[Ee][Pp]\\.?\\s?|серия\\s?|episode\\s?)(\\d{1,3})(?!\\d)",
        options: [.caseInsensitive]
    )

    static func episodeSortKey(_ text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        if let m = seasonEpisode.firstMatch(in: text, range: range),
           let s = Range(m.range(at: 1), in: text), let e = Range(m.range(at: 2), in: text),
           let season = Int(text[s]), let episode = Int(text[e]) {
            return season * 1000 + episode
        }
        if let m = episodeOnly.firstMatch(in: text, range: range),
           let e = Range(m.range(at: 1), in: text), let episode = Int(text[e]) {
            return episode
        }
        return nil
    }
}
