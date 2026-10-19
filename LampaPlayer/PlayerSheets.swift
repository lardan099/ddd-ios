import SwiftUI
import UIKit

/// Задержка звука и субтитров, размер субтитров.
struct TuningSheet: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    delayRow(value: model.audioDelay, set: model.setAudioDelay)
                } header: {
                    Text("Задержка звука")
                } footer: {
                    Text("Плюс — звук позже, минус — раньше. Шаг 0,1 с.")
                }

                Section {
                    delayRow(value: model.subDelay, set: model.setSubDelay)
                } header: {
                    Text("Задержка субтитров")
                } footer: {
                    Text("Плюс — субтитры позже, минус — раньше.")
                }

                Section {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: Binding(get: { model.subScale }, set: { model.setSubScale($0) }), in: 0.5...2.5, step: 0.1)
                        Image(systemName: "textformat.size.larger")
                    }
                    HStack {
                        Text("Масштаб")
                        Spacer()
                        Text(String(format: "%.0f%%", model.subScale * 100)).monospacedDigit()
                        Button("Сбросить") { model.setSubScale(1) }
                            .buttonStyle(.borderless)
                            .padding(.leading, 8)
                    }
                } header: {
                    Text("Размер субтитров")
                } footer: {
                    Text("Размер запоминается для всех видео.")
                }
            }
            .navigationTitle("Звук и субтитры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private func delayRow(value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Button { set(value - 0.5) } label: { Text("−0,5") }
            Button { set(value - 0.1) } label: { Image(systemName: "minus.circle.fill").font(.title2) }
            Spacer()
            Text(String(format: "%+.1f с", value))
                .font(.title3.monospacedDigit())
                .onTapGesture { set(0) }
            Spacer()
            Button { set(value + 0.1) } label: { Image(systemName: "plus.circle.fill").font(.title2) }
            Button { set(value + 0.5) } label: { Text("+0,5") }
        }
        .buttonStyle(.borderless)
    }
}

/// Технические данные: источник, сеть, видео, аудио, TorrServer и полный лог mpv.
struct TechSheet: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var torr = TorrServerManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [PlayerModel.TechSection] = []
    @State private var showServerLog = false
    @State private var copied = false
    /// С какого адреса выходят в сеть Lampa и плеер — проверяется один раз при открытии.
    @State private var addressRows: [(String, String)] = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top) {
                                Text(row.0).foregroundColor(.secondary)
                                Spacer(minLength: 12)
                                Text(row.1)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .font(.footnote)
                        }
                    }
                }

                Section("Встроенный TorrServer") {
                    HStack {
                        Text("Состояние").foregroundColor(.secondary)
                        Spacer()
                        Text(torr.running ? "работает, \(TorrServerManager.address)" : (AppSettings.torrServerEnabled ? "не запущен" : "выключен"))
                    }
                    .font(.footnote)
                    if let error = torr.lastError {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                    ForEach(Array(torr.log.suffix(10).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                    Button(showServerLog ? "Скрыть лог TorrServer" : "Показать лог TorrServer") { showServerLog.toggle() }
                    if showServerLog {
                        Text("web.log").font(.caption.bold())
                        Text(TorrServerManager.shared.webLogTail(maxBytes: 8 * 1024))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        Text("torrserver.log").font(.caption.bold())
                        Text(TorrServerManager.shared.serverLogTail(maxBytes: 16 * 1024))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("Лог mpv (\(model.log.count) строк)") {
                    ForEach(Array(model.log.suffix(300).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Тех. данные")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? "Скопировано" : "Скопировать") {
                        UIPasteboard.general.string = report()
                        copied = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear {
            refresh()
            NetDiagnostics.check { rows in
                addressRows = rows
                refresh()
            }
        }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        let extra = addressRows.isEmpty ? [] : [PlayerModel.TechSection(title: "Адрес в сети", rows: addressRows)]
        model.techInfo { sections = $0 + extra }
    }

    /// Всё одним текстом — чтобы переслать.
    private func report() -> String {
        var lines: [String] = ["Lampa Player \(HomeView.appVersion)"]
        for section in sections {
            lines.append("")
            lines.append("## \(section.title)")
            for row in section.rows { lines.append("\(row.0): \(row.1)") }
        }
        lines.append("")
        lines.append("## TorrServer")
        lines.append(torr.running ? "работает, \(TorrServerManager.address)" : "не запущен")
        lines.append(contentsOf: torr.log)
        lines.append("")
        lines.append("## Лог mpv")
        lines.append(contentsOf: model.log)
        return lines.joined(separator: "\n")
    }
}

/// Журнал встроенного TorrServer: что запрашивала Lampa через прокси и что ответил сервер.
struct TorrServerLogView: View {
    @ObservedObject private var torr = TorrServerManager.shared
    @State private var webLog = ""
    @State private var copied = false

    var body: some View {
        List {
            Section {
                if torr.log.isEmpty {
                    Text("Пусто. Откройте Lampa и выберите торрент — запросы появятся здесь.")
                        .foregroundColor(.secondary)
                }
                ForEach(Array(torr.log.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundColor(line.contains("← HTTP/1.1 4") || line.contains("← HTTP/1.1 5") ? .red : .primary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Запросы и события (новые сверху)")
            } footer: {
                Text("«→» — запрос Lampa (в скобках её адрес), «←» — ответ TorrServer. 403 Banned означает блокировку по адресу Lampa — её снимает прокси.")
            }

            Section("web.log TorrServer") {
                Text(webLog.isEmpty ? "пусто" : webLog)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Журнал TorrServer")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(copied ? "Скопировано" : "Скопировать") {
                    UIPasteboard.general.string = (torr.log + ["", "web.log:", webLog]).joined(separator: "\n")
                    copied = true
                }
            }
        }
        .onAppear { webLog = torr.webLogTail(maxBytes: 8 * 1024) }
    }
}
