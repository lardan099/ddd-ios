import Foundation
import CFNetwork

/// Системный HTTP(S)-прокси iOS. Его ставят VPN-приложения (Shadowrocket, Happ, v2RayTun…):
/// WebView и URLSession ходят через него, а FFmpeg открывает сокеты сам и прокси не видит —
/// выходит с другого IP. MODS привязывает ссылку к IP, с которого Lampa её получила, и отвечает 403.
/// Поэтому mpv отдаём тот же прокси (`http-proxy`).
enum SystemProxy {
    /// «http://127.0.0.1:1082» для этой ссылки или nil (прокси нет, исключение, PAC или SOCKS).
    static func proxy(for link: String) -> String? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return nil }
        let list = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]] ?? []
        for entry in list {
            guard let type = entry[kCFProxyTypeKey as String] as? String else { continue }
            if type == (kCFProxyTypeNone as String) { return nil }
            guard type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String),
                  let host = entry[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
                  let port = (entry[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue, port > 0 else { continue }
            return "http://\(host):\(port)"
        }
        return nil
    }

    /// Для тех. данных: что вообще настроено в системе.
    static var summary: String {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return "нет"
        }
        var parts: [String] = []
        if (settings["HTTPEnable"] as? NSNumber)?.boolValue == true,
           let host = settings["HTTPProxy"] as? String, let port = settings["HTTPPort"] as? NSNumber {
            parts.append("HTTP \(host):\(port)")
        }
        if (settings["HTTPSEnable"] as? NSNumber)?.boolValue == true,
           let host = settings["HTTPSProxy"] as? String, let port = settings["HTTPSPort"] as? NSNumber {
            parts.append("HTTPS \(host):\(port)")
        }
        if (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true { parts.append("PAC") }
        if (settings["SOCKSEnable"] as? NSNumber)?.boolValue == true { parts.append("SOCKS") }
        return parts.isEmpty ? "нет" : parts.joined(separator: ", ")
    }
}
