import Foundation
import Network

/// HTTP-прокси 127.0.0.1:<port> → 127.0.0.1:<targetPort> перед встроенным TorrServer.
///
/// Зачем: в TorrServer зашит WAF, который отвечает «403 Banned» запросам, где Referer/Origin — одно из
/// зеркал Lampa (bylampa.online, lampa.land, …), и этот список нельзя выключить. Прокси убирает Referer
/// и подменяет Origin на 127.0.0.1 — CORS при этом работает (TorrServer отвечает Allow-Origin: *).
/// Заодно пишет в лог каждый запрос и код ответа — видно, что именно спрашивает Lampa.
final class LocalProxy {
    let port: UInt16
    let targetPort: UInt16
    var log: ((String) -> Void)?

    private let queue = DispatchQueue(label: "lampaplayer.proxy", qos: .userInitiated)
    private var listener: NWListener?
    /// Слушает ли сейчас порт. iOS может закрыть сокет, пока приложение было заморожено.
    private(set) var isListening = false
    private var sessions: [ObjectIdentifier: ProxySession] = [:]

    init(port: UInt16, targetPort: UInt16) {
        self.port = port
        self.targetPort = targetPort
    }

    /// nil — запустился; иначе текст ошибки.
    func start() -> String? {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return "неверный порт \(port)" }
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DispatchQueue.main.async { self?.isListening = true }
                case .failed(let error):
                    DispatchQueue.main.async { self?.isListening = false }
                    self?.log?("Прокси :\(self?.port ?? 0) упал: \(error)")
                case .cancelled:
                    DispatchQueue.main.async { self?.isListening = false }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
        queue.async { [weak self] in
            self?.sessions.values.forEach { $0.close() }
            self?.sessions.removeAll()
        }
    }

    private func accept(_ client: NWConnection) {
        let session = ProxySession(client: client, targetPort: targetPort, queue: queue, log: log)
        let id = ObjectIdentifier(session)
        sessions[id] = session
        session.onClose = { [weak self] in self?.sessions.removeValue(forKey: id) }
        session.start()
    }
}

/// Одно клиентское соединение. Работает целиком на очереди прокси.
private final class ProxySession {
    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let log: ((String) -> Void)?
    private var rewriter = RequestRewriter()
    private var closed = false
    var onClose: (() -> Void)?

    init(client: NWConnection, targetPort: UInt16, queue: DispatchQueue, log: ((String) -> Void)?) {
        self.client = client
        self.queue = queue
        self.log = log
        upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort) ?? 8095, using: .tcp)
    }

    func start() {
        let handler: (NWConnection.State) -> Void = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.stateUpdateHandler = handler
        upstream.stateUpdateHandler = handler
        upstream.start(queue: queue)
        client.start(queue: queue)
        pumpRequests()
        pumpResponses()
    }

    /// Клиент → TorrServer, с переписыванием заголовков каждого запроса.
    private func pumpRequests() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                let out = self.rewriter.feed(data) { [weak self] line in self?.log?(line) }
                self.upstream.send(content: out, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil || isComplete { self.close(); return }
                    self.pumpRequests()
                })
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.pumpRequests()
            }
        }
    }

    /// TorrServer → клиент, как есть. Логируем строку статуса, если ответ начинается в этом куске.
    private func pumpResponses() {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                if data.starts(with: Data("HTTP/1.".utf8)),
                   let end = data.range(of: Data("\r\n".utf8)),
                   let status = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) {
                    self.log?("   ← \(status)")
                }
                self.client.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil || isComplete { self.close(); return }
                    self.pumpResponses()
                })
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.pumpResponses()
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream.cancel()
        onClose?()
        onClose = nil
    }
}

/// Режет поток запросов на заголовки и тела, переписывает Referer/Origin в заголовках.
private struct RequestRewriter {
    private var buffer = Data()
    private var bodyRemaining = 0
    private var passthrough = false
    private static let headerEnd = Data("\r\n\r\n".utf8)

    mutating func feed(_ data: Data, log: (String) -> Void) -> Data {
        if passthrough { return data }
        buffer.append(data)
        var out = Data()

        while !buffer.isEmpty {
            if bodyRemaining > 0 {
                let n = min(bodyRemaining, buffer.count)
                out.append(buffer.prefix(n))
                buffer = Data(buffer.dropFirst(n))
                bodyRemaining -= n
                continue
            }
            guard let end = buffer.range(of: Self.headerEnd) else {
                // Заголовок не пришёл целиком. Если он подозрительно большой — дальше просто пропускаем.
                if buffer.count > 64 * 1024 {
                    passthrough = true
                    out.append(buffer)
                    buffer = Data()
                }
                break
            }
            let head = buffer[buffer.startIndex..<end.lowerBound]
            buffer = Data(buffer[end.upperBound...])

            guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
                passthrough = true
                out.append(head)
                out.append(Self.headerEnd)
                out.append(buffer)
                buffer = Data()
                break
            }
            var lines = text.components(separatedBy: "\r\n")
            let requestLine = Self.collapseLeadingSlashes(lines.isEmpty ? "" : lines.removeFirst())
            var kept = [requestLine]
            var origin: String?
            var length = 0
            var chunked = false

            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { kept.append(line); continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch name {
                case "referer":
                    continue
                case "origin":
                    origin = value
                    kept.append("Origin: http://127.0.0.1")
                    continue
                case "content-length":
                    length = Int(value) ?? 0
                case "transfer-encoding":
                    if value.lowercased().contains("chunked") { chunked = true }
                default:
                    break
                }
                kept.append(line)
            }

            log("→ \(Self.shorten(requestLine))" + (origin.map { "  [\($0)]" } ?? ""))
            out.append(Data((kept.joined(separator: "\r\n") + "\r\n\r\n").utf8))

            if chunked {
                // Браузеры так не шлют; на всякий случай дальше без разбора.
                passthrough = true
                out.append(buffer)
                buffer = Data()
                break
            }
            bodyRemaining = length
        }
        return out
    }

    /// Если в Lampa адрес TorrServer записан со слэшем на конце (http://127.0.0.1:8090/), она шлёт
    /// «//settings», «//stream/…», а TorrServer на такие пути отвечает 404. Схлопываем «//…» в «/…».
    private static func collapseLeadingSlashes(_ requestLine: String) -> String {
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].hasPrefix("//") else { return requestLine }
        let path = "/" + parts[1].drop(while: { $0 == "/" })
        return "\(parts[0]) \(path) \(parts[2])"
    }

    /// Ссылки на поток бывают длинными (magnet в query) — в лог хватит начала.
    private static func shorten(_ line: String) -> String {
        line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}
