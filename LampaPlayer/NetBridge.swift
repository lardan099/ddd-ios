import Foundation
import Network
import WebKit

/// Мост mpv → URLSession на 127.0.0.1:8097.
///
/// Зачем: MODS (api.lampa.stream) и CDN VK привязывают ссылку к IP, с которого Lampa её получила.
/// Lampa в WebView ходит через сетевой стек iOS, а FFmpeg открывает сокеты сам — с VPN они выходят
/// в сеть по-разному (IPv4/IPv6, маршрут), MODS видит чужой IP и отдаёт 403 или 7-секундную заглушку.
/// URLSession выбирает адрес и маршрут так же, как WebKit, — поэтому такие ссылки mpv открывает через мост.
///
/// Адрес: http://127.0.0.1:8097/net/<base64url(scheme://host:port)>/<путь>?<query>. Путь сохраняется,
/// поэтому относительные ссылки внутри m3u8 работают; абсолютные и «/…» мост переписывает на себя.
/// Редиректы не проходит сам, а возвращает mpv 302 на завёрнутый адрес — вся цепочка идёт через мост.
final class NetBridge: NSObject {
    static let shared = NetBridge()
    static let port: UInt16 = 8097
    private static let prefix = "/net/"

    var log: ((String) -> Void)?

    private let queue = DispatchQueue(label: "lampaplayer.netbridge", qos: .userInitiated)
    private var listener: NWListener?
    private var listening = false
    private var exchanges: [Int: Exchange] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 8
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    // MARK: - Адреса

    static func wrap(_ link: String) -> String {
        guard let comps = URLComponents(string: link), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = comps.host, !host.isEmpty else { return link }
        var origin = "\(scheme)://\(host)"
        if let port = comps.port { origin += ":\(port)" }
        let encoded = Data(origin.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var path = comps.percentEncodedPath
        if !path.hasPrefix("/") { path = "/" + path }
        var out = "http://127.0.0.1:\(port)\(prefix)\(encoded)\(path)"
        if let query = comps.percentEncodedQuery { out += "?" + query }
        return out
    }

    static func isWrapped(_ link: String) -> Bool {
        link.hasPrefix("http://127.0.0.1:\(port)\(prefix)")
    }

    /// «/net/<origin>/путь?q» → настоящий URL.
    private static func unwrap(target: String) -> URL? {
        guard target.hasPrefix(prefix) else { return nil }
        let rest = target.dropFirst(prefix.count)
        let encoded = rest.prefix(while: { $0 != "/" && $0 != "?" })
        let tail = rest.dropFirst(encoded.count)
        var b64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let origin = String(data: data, encoding: .utf8) else { return nil }
        let path = tail.isEmpty ? "/" : (tail.hasPrefix("?") ? "/" + tail : String(tail))
        return URL(string: origin + path)
    }

    // MARK: - Сервер

    /// Идемпотентно: iOS закрывает сокеты, пока приложение заморожено, — перед воспроизведением зовём снова.
    func start() {
        queue.async { [self] in
            if listener != nil && listening { return }
            listener?.cancel()
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredInterfaceType = .loopback
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.listening = true
                    case .failed(let error):
                        self.listening = false
                        self.listener = nil
                        self.log?("Мост :\(Self.port) упал: \(error)")
                    case .cancelled: self.listening = false
                    default: break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                log?("Мост :\(Self.port) не запустился: \(error.localizedDescription)")
            }
        }
    }

    private func accept(_ client: NWConnection) {
        client.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let client else { return }
                // mpv закрыл соединение (перемотка, смена качества) — останавливаем загрузку.
                for (id, ex) in self.exchanges where ex.client === client {
                    ex.task?.cancel()
                    self.exchanges.removeValue(forKey: id)
                }
            default: break
            }
        }
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(client, head: buffer[buffer.startIndex..<end.lowerBound])
            } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                client.cancel()
            } else {
                self.readHead(client, buffer: buffer)
            }
        }
    }

    /// Заголовки, которые передаём дальше как есть.
    private static let forwarded: Set<String> = ["range", "user-agent", "referer", "origin", "accept", "accept-language"]

    private func handle(_ client: NWConnection, head: Data) {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return reply(client, status: "400 Bad Request")
        }
        var lines = text.components(separatedBy: "\r\n")
        let parts = (lines.isEmpty ? "" : lines.removeFirst()).split(separator: " ")
        guard parts.count >= 2, let url = Self.unwrap(target: String(parts[1])) else {
            return reply(client, status: "400 Bad Request")
        }
        let method = String(parts[0]).uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = method == "HEAD" ? "HEAD" : "GET"
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard Self.forwarded.contains(name.lowercased()) else { continue }
            request.setValue(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: name)
        }
        let task = session.dataTask(with: request)
        let ex = Exchange(client: client, url: url, head: method == "HEAD")
        ex.task = task
        exchanges[task.taskIdentifier] = ex
        task.resume()
    }

    private func reply(_ client: NWConnection, status: String, headers: [String] = []) {
        let text = (["HTTP/1.1 \(status)", "Content-Length: 0", "Connection: close"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
        client.send(content: Data(text.utf8), completion: .contentProcessed { _ in client.cancel() })
    }

    // MARK: - Плейлисты HLS

    private static func isPlaylist(_ response: HTTPURLResponse, url: URL) -> Bool {
        let type = (response.mimeType ?? "").lowercased()
        if type.contains("mpegurl") { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }

    /// Все ссылки в m3u8 (строки и URI="…") — абсолютные через мост.
    private static func rewritePlaylist(_ data: Data, base: URL) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        func wrapped(_ ref: String) -> String {
            guard let absolute = URL(string: ref, relativeTo: base)?.absoluteURL else { return ref }
            return wrap(absolute.absoluteString)
        }
        let uriPattern = try? NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        let lines = text.components(separatedBy: "\n").map { raw -> String in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if trimmed.hasPrefix("#") {
                guard let uriPattern, line.contains("URI=\"") else { return line }
                var out = line
                let ns = line as NSString
                for match in uriPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let ref = ns.substring(with: match.range(at: 1))
                    out = (out as NSString).replacingCharacters(in: match.range(at: 1), with: wrapped(ref))
                }
                return out
            }
            return wrapped(trimmed)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

/// С какого IP выходят в сеть Lampa (WebView) и плеер через мост (URLSession). Если они разные — MODS
/// не отдаст видео. Адрес FFmpeg напрямую отсюда не узнать, но расхождение WebView/URLSession уже ответ.
enum NetDiagnostics {
    private static let echo = "https://api64.ipify.org"

    static func check(_ completion: @escaping ([(String, String)]) -> Void) {
        let group = DispatchGroup()
        var web = "нет ответа", native = "нет ответа", v4 = "нет ответа"

        group.enter()
        DispatchQueue.main.async {
            guard let webView = LampaBridge.shared.webView else { web = "Lampa не открыта"; group.leave(); return }
            webView.callAsyncJavaScript(
                "const r = await fetch(u, {cache: 'no-store'}); return await r.text();",
                arguments: ["u": echo], in: nil, in: .page
            ) { result in
                if case .success(let value) = result, let text = value as? String { web = text }
                group.leave()
            }
        }
        for (link, assign) in [(echo, { (s: String) in native = s }), ("https://api.ipify.org", { (s: String) in v4 = s })] {
            group.enter()
            var request = URLRequest(url: URL(string: link)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            request.httpMethod = "GET"
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) { assign(text) }
                group.leave()
            }.resume()
        }
        group.notify(queue: .main) {
            var rows = [("Lampa (WebView)", web), ("Плеер через мост", native), ("IPv4", v4)]
            if web != native, !web.contains(" "), !native.contains(" ") {
                rows.append(("Внимание", "адреса Lampa и моста разные — MODS может не отдать видео"))
            }
            completion(rows)
        }
    }
}

/// Один запрос mpv. Живёт на очереди моста.
private final class Exchange {
    let client: NWConnection
    let url: URL
    let head: Bool
    var task: URLSessionDataTask?
    var playlist = false
    var body = Data()
    var headersSent = false
    var pending = 0
    var suspended = false
    var finished = false

    init(client: NWConnection, url: URL, head: Bool) {
        self.client = client
        self.url = url
        self.head = head
    }
}

extension NetBridge: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Сами не идём: отдадим mpv 302 на завёрнутый адрес (см. didReceive response).
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let ex = exchanges[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let code = http.statusCode
        if (300..<400).contains(code), let location = http.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: ex.url)?.absoluteURL {
            exchanges.removeValue(forKey: dataTask.taskIdentifier)
            completionHandler(.cancel)
            reply(ex.client, status: "302 Found", headers: ["Location: " + Self.wrap(target.absoluteString)])
            return
        }
        if code >= 400 { log?("Мост: \(code) от \(ex.url.host ?? "?")") }
        ex.playlist = code < 300 && !ex.head && Self.isPlaylist(http, url: ex.url)
        if !ex.playlist {
            sendHeaders(ex, http: http, contentLength: nil)
        }
        completionHandler(ex.head ? .cancel : .allow)
        if ex.head { finish(ex, id: dataTask.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let ex = exchanges[dataTask.taskIdentifier] else { return }
        if ex.playlist {
            ex.body.append(data)
            return
        }
        ex.pending += data.count
        // mpv читает медленнее сети — притормаживаем загрузку, чтобы не копить в памяти.
        if ex.pending > 8 * 1024 * 1024, !ex.suspended {
            ex.suspended = true
            dataTask.suspend()
        }
        ex.client.send(content: data, completion: .contentProcessed { [weak ex] _ in
            guard let ex else { return }
            ex.pending -= data.count
            if ex.suspended, ex.pending < 2 * 1024 * 1024 {
                ex.suspended = false
                ex.task?.resume()
            }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ex = exchanges[task.taskIdentifier] else { return }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            log?("Мост: \(ex.url.host ?? "?") — \(error.localizedDescription)")
            if !ex.headersSent {
                exchanges.removeValue(forKey: task.taskIdentifier)
                return reply(ex.client, status: "502 Bad Gateway")
            }
        }
        if ex.playlist, let http = task.response as? HTTPURLResponse {
            let body = Self.rewritePlaylist(ex.body, base: ex.url)
            sendHeaders(ex, http: http, contentLength: body.count)
            ex.client.send(content: body, completion: .contentProcessed { _ in })
        }
        finish(ex, id: task.taskIdentifier)
    }

    private func sendHeaders(_ ex: Exchange, http: HTTPURLResponse, contentLength: Int?) {
        guard !ex.headersSent else { return }
        ex.headersSent = true
        var lines = ["HTTP/1.1 \(http.statusCode) \(http.statusCode < 300 ? "OK" : "Error")", "Connection: close"]
        let decoded = http.value(forHTTPHeaderField: "Content-Encoding") != nil
        for name in ["Content-Type", "Content-Range", "Accept-Ranges"] {
            if let value = http.value(forHTTPHeaderField: name) { lines.append("\(name): \(value)") }
        }
        if let contentLength {
            lines.append("Content-Length: \(contentLength)")
        } else if !decoded, let value = http.value(forHTTPHeaderField: "Content-Length") {
            // URLSession сам распаковывает gzip — тогда длина другая, и её не шлём (читаем до закрытия).
            lines.append("Content-Length: \(value)")
        }
        ex.client.send(content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8), completion: .contentProcessed { _ in })
    }

    /// Всё отдано — закрываем соединение после последней отправки.
    private func finish(_ ex: Exchange, id: Int) {
        guard !ex.finished else { return }
        ex.finished = true
        exchanges.removeValue(forKey: id)
        ex.client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                       completion: .contentProcessed { [weak client = ex.client] _ in client?.cancel() })
    }
}
