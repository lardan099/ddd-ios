import Foundation

/// API плеера для плагина Lampa на http://127.0.0.1:8090/lampaplayer/…
/// Обслуживается тем же LocalProxy, что стоит перед встроенным TorrServer, и работает, даже если TorrServer выключен.
///
///   GET /lampaplayer/ping          → {"ok":true,"app":"0.6.0 (12)","pending":3}
///   GET /lampaplayer/progress      → [{"h":"…","t":754,"d":1855,"pc":41}, …]  — позиции для отметок Lampa
///   GET /lampaplayer/ack?h=a,b     → {"ok":true}  — плагин поставил отметки, можно забыть
///
/// Только простые GET без своих заголовков — браузеру не нужен preflight. CORS открыт.
enum LocalAPI {
    static let prefix = "/lampaplayer/"

    static func response(method: String, target: String, log: ((String) -> Void)?) -> Data {
        if method.uppercased() == "OPTIONS" {
            return http(status: "204 No Content", body: Data(), type: "text/plain")
        }

        let components = URLComponents(string: "http://localhost" + target)
        let path = components?.path ?? target
        let query = components?.queryItems ?? []

        switch path {
        case prefix + "ping":
            let body: [String: Any] = ["ok": true, "app": appVersion, "pending": LampaProgressStore.pendingCount]
            return json(body)

        case prefix + "progress":
            return http(status: "200 OK", body: LampaProgressStore.pendingJSON(), type: "application/json")

        case prefix + "ack":
            let hashes = (query.first(where: { $0.name == "h" })?.value ?? "")
                .split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
            LampaProgressStore.acknowledge(hashes)
            if !hashes.isEmpty { log?("Lampa забрала отметки просмотра: \(hashes.count)") }
            return json(["ok": true])

        default:
            return http(status: "404 Not Found", body: Data("{\"ok\":false}".utf8), type: "application/json")
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static func json(_ object: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return http(status: "200 OK", body: body, type: "application/json")
    }

    private static func http(status: String, body: Data, type: String) -> Data {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(type); charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Access-Control-Allow-Private-Network: true",
            "Connection: close",
        ]
        var data = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}
