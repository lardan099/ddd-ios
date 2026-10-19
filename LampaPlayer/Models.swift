import Foundation

struct SubtitleRef: Codable, Hashable {
    var url: String
    var label: String
}

/// Метки пропуска от балансера (через плагин Lampa): заставки/титры и реклама, в секундах.
struct SkipSegments: Codable, Hashable {
    var ads: [[Double]]
    var skips: [[Double]]
    /// Длительность файла, по которому размечали (duration_ms / 1000). 0 — неизвестна.
    var referenceDuration: Double
}

struct PlayItem: Codable, Hashable {
    var url: String
    /// Имя файла / серии, как его передала Lampa (filename в infuse://).
    var title: String?
    /// Внешние субтитры (sub в infuse://).
    var sub: String?
    /// Позиция старта в секундах, которую передала Lampa.
    var position: Double?
    /// Все внешние субтитры (только через плагин Lampa).
    var subs: [SubtitleRef]?
    var segments: SkipSegments?
    /// WebVTT со спрайтами превью кадров.
    var thumbnails: String?
    /// Ключ отметки просмотра в Lampa (timeline hash) — по нему плагин ставит прогресс.
    var lampaHash: String?
    /// Перевод, выбранный в Lampa («Кубик в Кубе»): у онлайн-потоков дорожка обычно одна и без названия.
    var voice: String?

    /// Все внешние субтитры: из плагина или единственные из infuse://.
    var externalSubtitles: [SubtitleRef] {
        if let subs, !subs.isEmpty { return subs }
        if let sub, !sub.isEmpty { return [SubtitleRef(url: sub, label: "Из Lampa")] }
        return []
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return Self.stripExtension(title) }
        if let comps = URLComponents(string: url) {
            let last = (comps.path as NSString).lastPathComponent
            if !last.isEmpty, last != "/" { return Self.stripExtension(last) }
            if let host = comps.host { return host }
        }
        return url
    }

    /// Ключ для запоминания позиции. У TorrServer ссылка меняется (адрес сервера, &play/&preload),
    /// а пара hash+index — нет. У онлайн-источников ссылки протухают, поэтому опираемся на имя от Lampa.
    var resumeKey: String {
        // Ключ отметки Lampa уникален для серии и не зависит от источника и ссылки.
        if let lampaHash, !lampaHash.isEmpty { return "lh:\(lampaHash)" }
        if let comps = URLComponents(string: url), comps.path.contains("/stream"),
           let link = comps.queryItems?.first(where: { $0.name == "link" })?.value, !link.isEmpty {
            let index = comps.queryItems?.first(where: { $0.name == "index" })?.value ?? "1"
            return "ts:\(link.lowercased()):\(index)"
        }
        if let title, !title.isEmpty { return "t:\(title)" }
        if var comps = URLComponents(string: url) {
            comps.query = nil
            return "u:" + (comps.string ?? url)
        }
        return "u:" + url
    }

    static func stripExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let known = ["mkv", "mp4", "avi", "m4v", "mov", "ts", "m2ts", "webm", "wmv", "flv", "mpg", "mpeg", "m3u8", "vob"]
        return known.contains(ext) ? (name as NSString).deletingPathExtension : name
    }
}

struct PlaybackRequest: Identifiable, Codable, Hashable {
    var id = UUID()
    var items: [PlayItem]
    var startIndex: Int
    /// infuse / senplayer / lampaplayer / link / history
    var source: String
    /// x-success из infuse://, если Lampa его передала.
    var successURL: String?
}

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let title: String?
    let lang: String?
    let codec: String?
    let channels: Int?
    let external: Bool
    let forced: Bool
    let selected: Bool

    /// Заголовок без мусора: mpv подставляет в title имя файла или URL внешних субтитров.
    private var cleanTitle: String? {
        guard var text = title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("://") || lower.hasPrefix("/") || lower.contains("%2f") || lower.contains("?") {
            return nil
        }
        let ext = (text as NSString).pathExtension.lowercased()
        if ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "mka", "ac3", "dts", "aac"].contains(ext) {
            text = (text as NSString).deletingPathExtension
        }
        return text.isEmpty ? nil : text
    }

    var label: String {
        var parts: [String] = []
        if let cleanTitle { parts.append(cleanTitle) }
        if let lang, let name = Self.languageName(lang),
           !(cleanTitle?.localizedCaseInsensitiveContains(name) ?? false) {
            parts.append(name)
        }
        if parts.isEmpty { parts.append(external ? "Внешние" : "Дорожка \(id)") }
        return parts.joined(separator: " · ")
    }

    var details: String {
        var parts: [String] = []
        if let codec, let name = Self.codecName(codec) { parts.append(name) }
        if let channels {
            switch channels {
            case 1: parts.append("моно")
            case 2: parts.append("стерео")
            case 6: parts.append("5.1")
            case 8: parts.append("7.1")
            default: parts.append("\(channels) кан.")
            }
        }
        if forced { parts.append("форсированные") }
        if external && cleanTitle != "Из Lampa" { parts.append("внешние") }
        return parts.joined(separator: ", ")
    }

    /// Коротко для кнопки под названием: имя озвучки («Кубик в Кубе») или язык.
    var chipTitle: String {
        cleanTitle ?? lang.flatMap { Self.languageName($0) } ?? "Дорожка \(id)"
    }

    /// Двухбуквенный код языка для кнопки субтитров: «RU», «EN».
    var languageCode: String? {
        guard let lang, !lang.isEmpty else { return nil }
        let lower = lang.lowercased()
        return (Self.iso3to1[lower] ?? lower).uppercased()
    }

    var menuTitle: String {
        details.isEmpty ? label : "\(label) — \(details)"
    }

    private static let codecNames: [String: String] = [
        "subrip": "SRT", "srt": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "VTT", "mov_text": "TX3G",
        "hdmv_pgs_subtitle": "PGS", "pgssub": "PGS", "dvd_subtitle": "VobSub", "dvdsub": "VobSub",
        "dvb_subtitle": "DVB", "eia_608": "CC", "text": "Текст",
        "ac3": "AC3", "eac3": "E-AC3", "dts": "DTS", "truehd": "TrueHD", "mlp": "MLP", "aac": "AAC",
        "opus": "Opus", "flac": "FLAC", "mp3": "MP3", "mp2": "MP2", "vorbis": "Vorbis", "pcm_s16le": "PCM",
        "pcm_s24le": "PCM", "alac": "ALAC"
    ]

    static func codecName(_ codec: String) -> String? {
        let key = codec.lowercased()
        if let known = codecNames[key] { return known }
        if key.hasPrefix("pcm_") { return "PCM" }
        // Неизвестный длинный кодек в списке только мешает.
        return key.count <= 6 ? key.uppercased() : nil
    }

    private static let iso3to1: [String: String] = [
        "rus": "ru", "eng": "en", "ukr": "uk", "bel": "be", "kaz": "kk", "ger": "de", "deu": "de",
        "fre": "fr", "fra": "fr", "spa": "es", "ita": "it", "jpn": "ja", "kor": "ko", "chi": "zh",
        "zho": "zh", "pol": "pl", "por": "pt", "tur": "tr", "und": ""
    ]

    static func languageName(_ code: String) -> String? {
        let lower = code.lowercased()
        let short = iso3to1[lower] ?? lower
        guard !short.isEmpty, let name = Locale.current.localizedString(forLanguageCode: short) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

enum LanguagePrefs {
    private static let iso1to3: [String: [String]] = [
        "ru": ["rus"], "en": ["eng"], "uk": ["ukr"], "be": ["bel"], "kk": ["kaz"], "de": ["ger", "deu"],
        "fr": ["fre", "fra"], "es": ["spa"], "it": ["ita"], "ja": ["jpn"], "ko": ["kor"], "zh": ["chi", "zho"],
        "pl": ["pol"], "pt": ["por"], "tr": ["tur"]
    ]

    /// Список языков для alang/slang: выбранный в настройках или языки системы.
    static func mpvList() -> String {
        let override = UserDefaults.standard.string(forKey: AppSettings.languageKey) ?? ""
        let source = override.isEmpty ? Locale.preferredLanguages : [override]
        var codes: [String] = []
        for id in source {
            let two = String(id.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
            guard !two.isEmpty else { continue }
            codes.append(two)
            codes.append(contentsOf: iso1to3[two] ?? [])
        }
        if codes.isEmpty { codes = ["ru", "rus"] }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }.joined(separator: ",")
    }
}

enum AppSettings {
    static let hwdecKey = "hwdec"
    static let languageKey = "preferredLanguage"

    static let videoOutputKey = "videoOutput"
    static let hdrKey = "hdr"
    static let autoPiPKey = "autoPiP"
    static let subScaleKey = "subScale"
    static let torrServerEnabledKey = "torrServerEnabled"
    static let torrServerKeepAliveKey = "torrServerKeepAlive"
    static let skipModeKey = "skipMode"

    enum SkipMode: String, CaseIterable {
        case off, button, auto
        var title: String {
            switch self {
            case .off: return "Выключено"
            case .button: return "Кнопка «Пропустить»"
            case .auto: return "Пропускать автоматически"
            }
        }
    }

    static let subtitleModeKey = "subtitleMode"

    /// Включать ли субтитры сами. Ручной выбор в плеере всё равно переносится на следующие серии.
    enum SubtitleMode: String, CaseIterable {
        case off, forced, auto
        var title: String {
            switch self {
            case .off: return "Выключены"
            case .forced: return "Только форсированные"
            case .auto: return "Автоматически"
            }
        }
    }

    static var subtitleMode: SubtitleMode {
        SubtitleMode(rawValue: UserDefaults.standard.string(forKey: subtitleModeKey) ?? "") ?? .off
    }

    static var skipMode: SkipMode {
        get { SkipMode(rawValue: UserDefaults.standard.string(forKey: skipModeKey) ?? "") ?? .button }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: skipModeKey) }
    }

    static let autoNextKey = "autoNext"
    static let playbackSpeedKey = "playbackSpeed"

    /// Отсчёт «Следующая серия через 10 с» на титрах.
    static var autoNext: Bool {
        UserDefaults.standard.object(forKey: autoNextKey) as? Bool ?? true
    }

    /// Тех. строки поверх видео (кодек, битрейт, канал, буфер), пока видны контролы.
    static let statsOverlayKey = "statsOverlay"
    static var statsOverlay: Bool {
        get { UserDefaults.standard.object(forKey: statsOverlayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: statsOverlayKey) }
    }

    static let lampaURLKey = "lampaURL"
    static let lampaEnabledKey = "lampaEnabled"
    static let webUserAgentKey = "webUserAgent"
    static let defaultLampaURL = "http://lampa.byskaz.ru"

    /// Адрес Lampa для встроенного режима.
    static var lampaURL: String {
        UserDefaults.standard.string(forKey: lampaURLKey) ?? defaultLampaURL
    }

    /// Открывать встроенную Lampa при запуске.
    static var lampaEnabled: Bool {
        UserDefaults.standard.object(forKey: lampaEnabledKey) as? Bool ?? true
    }

    /// «lampa.mx» → «http://lampa.mx». Пусто или мусор — nil.
    static func normalizedLampaURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Настоящий User-Agent встроенной Lampa. Им же ходит mpv: часть CDN (okcdn и др.)
    /// сверяет UA с тем, что был у браузера при получении ссылки.
    static var webUserAgent: String? {
        get { UserDefaults.standard.string(forKey: webUserAgentKey) }
        set { UserDefaults.standard.set(newValue, forKey: webUserAgentKey) }
    }

    /// Скорость воспроизведения переживает закрытие плеера.
    static var playbackSpeed: Double {
        get {
            let value = UserDefaults.standard.double(forKey: playbackSpeedKey)
            return value > 0 ? value : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: playbackSpeedKey) }
    }

    static var hwdec: Bool {
        UserDefaults.standard.object(forKey: hwdecKey) as? Bool ?? true
    }

    static var hdr: Bool {
        UserDefaults.standard.object(forKey: hdrKey) as? Bool ?? true
    }

    static var autoPiP: Bool {
        UserDefaults.standard.object(forKey: autoPiPKey) as? Bool ?? true
    }

    static var subScale: Double {
        get {
            let value = UserDefaults.standard.double(forKey: subScaleKey)
            return value > 0 ? value : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: subScaleKey) }
    }

    static var torrServerEnabled: Bool {
        UserDefaults.standard.bool(forKey: torrServerEnabledKey)
    }

    static var torrServerKeepAlive: Bool {
        UserDefaults.standard.object(forKey: torrServerKeepAliveKey) as? Bool ?? true
    }
}
