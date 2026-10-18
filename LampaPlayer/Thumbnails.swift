import SwiftUI
import UIKit

/// Превью кадров при перемотке. Источник — WebVTT со спрайтами от балансера (thumbnails_vtt):
///   00:00:10.000 --> 00:00:20.000
///   https://…/sprite-1.jpg#xywh=160,0,160,90
final class ThumbnailProvider: ObservableObject {
    struct Cue {
        let start: Double
        let end: Double
        let url: URL
        let rect: CGRect?
    }

    @Published private(set) var image: UIImage?
    @Published private(set) var available = false

    private var cues: [Cue] = []
    private var source: String?
    private var lastKey: String?
    private var task: URLSessionDataTask?
    private let cache = NSCache<NSURL, UIImage>()

    func load(_ vtt: String?) {
        guard vtt != source else { return }
        source = vtt
        cues = []
        image = nil
        lastKey = nil
        available = false
        guard let vtt, let url = URL(string: vtt) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { return }
            let parsed = Self.parse(text, base: url)
            DispatchQueue.main.async {
                guard let self, self.source == vtt else { return }
                self.cues = parsed
                self.available = !parsed.isEmpty
            }
        }.resume()
    }

    func request(time: Double?) {
        guard let time, !cues.isEmpty else { return }
        guard let cue = cues.first(where: { time >= $0.start && time < $0.end }) ?? cues.last(where: { time >= $0.start }) else { return }
        let rect = cue.rect ?? .zero
        let key = "\(cue.url.absoluteString)#\(rect.origin.x),\(rect.origin.y)"
        guard key != lastKey else { return }
        lastKey = key

        if let sprite = cache.object(forKey: cue.url as NSURL) {
            image = Self.crop(sprite, cue.rect)
            return
        }
        task?.cancel()
        let cache = self.cache
        task = URLSession.shared.dataTask(with: cue.url) { [weak self] data, _, _ in
            guard let data, let sprite = UIImage(data: data) else { return }
            cache.setObject(sprite, forKey: cue.url as NSURL)
            let cropped = Self.crop(sprite, cue.rect)
            DispatchQueue.main.async {
                guard let self, self.lastKey == key else { return }
                self.image = cropped
            }
        }
        task?.resume()
    }

    static func crop(_ image: UIImage, _ rect: CGRect?) -> UIImage {
        guard let rect, rect.width > 0, rect.height > 0, let cg = image.cgImage else { return image }
        let s = image.scale
        let pixels = CGRect(x: rect.origin.x * s, y: rect.origin.y * s, width: rect.width * s, height: rect.height * s)
        guard let cropped = cg.cropping(to: pixels) else { return image }
        return UIImage(cgImage: cropped, scale: s, orientation: image.imageOrientation)
    }

    static func parse(_ text: String, base: URL) -> [Cue] {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var cues: [Cue] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.contains("-->") else { i += 1; continue }
            let parts = line.components(separatedBy: "-->")
            let endText = parts.count > 1 ? (parts[1].split(separator: " ").first.map(String.init) ?? "") : ""
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            if j < lines.count, let start = seconds(parts[0]), let end = seconds(endText) {
                let reference = lines[j].trimmingCharacters(in: .whitespaces)
                var path = reference
                var rect: CGRect?
                if let marker = reference.range(of: "#xywh=") {
                    path = String(reference[..<marker.lowerBound])
                    let numbers = reference[marker.upperBound...].split(separator: ",").compactMap { Double($0) }
                    if numbers.count == 4 { rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
                }
                if let url = URL(string: path, relativeTo: base)?.absoluteURL {
                    cues.append(Cue(start: start, end: end, url: url, rect: rect))
                }
            }
            i = j + 1
        }
        return cues
    }

    /// «00:01:02.500», «01:02.500», «62,5» → секунды.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

struct ThumbnailImage: View {
    @ObservedObject var provider: ThumbnailProvider
    var width: CGFloat = 160

    var body: some View {
        if let image = provider.image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.7), lineWidth: 1))
                .shadow(radius: 6)
        }
    }
}
