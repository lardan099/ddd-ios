import Foundation
import UIKit
import AVFoundation
import TorrServerKit

/// Встроенный TorrServer (TorrServerKit из релизов YouROK/TorrServer, gomobile).
///
/// Lampa ходит на 127.0.0.1:8090 — там наш прокси (LocalProxy), он убирает Referer/Origin, на которые
/// у TorrServer зашит бан, и пересылает на сам TorrServer на 127.0.0.1:8095. Плеер ходит на 8095 напрямую.
final class TorrServerManager: ObservableObject {
    static let shared = TorrServerManager()
    static let port = 8090
    static let internalPort = 8095
    static var address: String { "http://127.0.0.1:\(port)" }

    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var selfTestResult: String?

    /// Плеер открыт: у него своя аудиосессия, и звук фильма сам держит приложение в фоне.
    var playerActive = false

    private let queue = DispatchQueue(label: "lampaplayer.torrserver", qos: .userInitiated)
    private let keepAlive = BackgroundKeepAlive()
    private let proxy = LocalProxy(port: UInt16(port), targetPort: UInt16(internalPort))

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        proxy.log = { [weak self] line in
            DispatchQueue.main.async { self?.note(line) }
        }
    }

    var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("TorrServer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// Вызывается при запуске приложения: поднимает сервер, если он включён в настройках.
    func startIfEnabled() {
        if AppSettings.torrServerEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AppSettings.torrServerEnabledKey)
        enabled ? start() : stop()
    }

    func start() {
        guard !busy else { return }
        busy = true
        lastError = nil
        selfTestResult = nil
        let dir = dataDirectory.path
        note("Запуск TorrServer на :\(Self.internalPort), данные: \(dir)")
        queue.async { [weak self] in
            let error = TorrserverkitIsRunning() ? "" : TorrserverkitStartServer(Self.internalPort, dir)
            let ok = error.isEmpty || TorrserverkitIsRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                var problems: [String] = []
                if !ok { problems.append(error) }
                if ok, let proxyError = self.proxy.start() { problems.append("прокси :\(Self.port): \(proxyError)") }
                self.busy = false
                self.running = ok
                self.lastError = problems.isEmpty ? nil : problems.joined(separator: "; ")
                self.note(ok ? "Запущен, для Lampa: \(Self.address)" : "Ошибка запуска: \(error)")
                if let proxyProblem = problems.first(where: { $0.hasPrefix("прокси") }) { self.note(proxyProblem) }
                if ok { self.selfTest() }
            }
        }
    }

    func stop() {
        guard !busy else { return }
        busy = true
        note("Остановка")
        keepAlive.stop()
        proxy.stop()
        queue.async { [weak self] in
            let error = TorrserverkitStopServer()
            let stillRunning = TorrserverkitIsRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.running = stillRunning
                self.selfTestResult = nil
                self.lastError = error.isEmpty ? nil : error
                self.note(error.isEmpty ? "Остановлен" : "Ошибка остановки: \(error)")
            }
        }
    }

    func refreshStatus() {
        queue.async { [weak self] in
            let isRunning = TorrserverkitIsRunning()
            DispatchQueue.main.async { self?.running = isRunning }
        }
    }

    /// Проверка как у Lampa: GET /echo через прокси, с «чужим» Origin.
    func selfTest() {
        selfTestResult = "Проверяю…"
        guard let url = URL(string: Self.address + "/echo") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("https://bylampa.online", forHTTPHeaderField: "Origin")
        request.setValue("https://bylampa.online/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let body = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let result: String
            if let error {
                result = "Не отвечает: \(error.localizedDescription)"
            } else if status == 200 {
                result = "Отвечает, версия \(body.isEmpty ? "?" : body)"
            } else {
                result = "Ответ \(status.map(String.init) ?? "?"): \(body.prefix(80))"
            }
            DispatchQueue.main.async {
                self?.selfTestResult = result
                self?.note("Самопроверка: \(result)")
            }
        }.resume()
    }

    /// Ссылку Lampa на наш же TorrServer плеер открывает мимо прокси.
    static func directURL(_ url: String) -> String {
        guard shared.running else { return url }
        for host in ["127.0.0.1", "localhost"] {
            let prefix = "http://\(host):\(port)/"
            if url.hasPrefix(prefix) {
                // «…:8090//stream/…» (адрес в Lampa со слэшем на конце) — лишние слэши TorrServer не прощает.
                return "http://127.0.0.1:\(internalPort)/" + url.dropFirst(prefix.count).drop(while: { $0 == "/" })
            }
        }
        return url
    }

    /// Логи самого TorrServer (их пишет Go-часть): основной и веб (там видны баны WAF).
    var serverLogURL: URL { dataDirectory.appendingPathComponent("torrserver.log") }
    var webLogURL: URL { dataDirectory.appendingPathComponent("web.log") }

    func serverLogTail(maxBytes: Int = 64 * 1024) -> String {
        Self.tail(of: serverLogURL, maxBytes: maxBytes)
    }

    func webLogTail(maxBytes: Int = 16 * 1024) -> String {
        Self.tail(of: webLogURL, maxBytes: maxBytes)
    }

    private static func tail(of url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func note(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(stamp) \(text)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: - Фон

    // Пока Lampa открыта в Safari, наше приложение в фоне. Без звука iOS заморозит его через несколько
    // секунд, и TorrServer перестанет отвечать. Тихий звук держит процесс живым (режим audio в UIBackgroundModes).
    @objc private func willResignActive() {
        guard running, AppSettings.torrServerKeepAlive, !playerActive else { return }
        if keepAlive.start() {
            note("Фон: держу сервер живым тихим звуком")
        } else {
            note("Фон: не удалось включить тихий звук — iOS может заморозить сервер")
        }
    }

    @objc private func didBecomeActive() {
        if keepAlive.isRunning {
            keepAlive.stop()
            note("Вернулись из фона")
        }
        refreshStatus()
        if running, !busy, !proxy.isListening {
            note("Прокси не слушает — перезапускаю")
            if let error = proxy.start() { note("прокси: \(error)") }
        }
    }
}

/// Бесконечно проигрывает тишину. Сессия mixWithOthers — не глушит музыку и другие приложения.
final class BackgroundKeepAlive {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    var isRunning: Bool { engine?.isRunning ?? false }

    @discardableResult
    func start() -> Bool {
        guard engine == nil else { return true }
        let session = AVAudioSession.sharedInstance()
        // Плеер сам переводит сессию в .playback/.moviePlayback, когда открыт; здесь только фон без плеера.
        if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return false }
        buffer.frameLength = buffer.frameCapacity // нули = тишина
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
        } catch {
            return false
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
        return true
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
