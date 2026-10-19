// Обновление из GitHub Releases.
// Раз в сутки (и по кнопке в меню) смотрит последний релиз, скачивает
// PuntoLite.zip, проверяет подпись, подменяет приложение и перезапускает его.
// Файл, скачанный самим приложением, не получает карантинный флаг,
// поэтому Gatekeeper не мешает обновлению.

import Cocoa

final class Updater {
    static let shared = Updater()

    let repo = Bundle.main.object(forInfoDictionaryKey: "PLGitHubRepo") as? String ?? ""
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var timer: Timer?
    private var busy = false

    func start() {
        guard !repo.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        guard !repo.isEmpty, !busy else { return }
        busy = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                self.busy = false
                guard error == nil, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if userInitiated { self.alert("Не удалось проверить обновления", error?.localizedDescription ?? "") }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard Updater.isNewer(latest, than: self.current) else {
                    if userInitiated { self.alert("Обновлений нет", "У вас последняя версия \(self.current).") }
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                guard let zip = assets.first(where: { ($0["name"] as? String) == "PuntoLite.zip" }),
                      let urlStr = zip["browser_download_url"] as? String,
                      let url = URL(string: urlStr) else { return }
                let notes = (json["body"] as? String ?? "").prefix(600)
                self.offer(version: latest, notes: String(notes), url: url)
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func offer(version: String, notes: String, url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Доступна версия PuntoLite \(version)"
        a.informativeText = "Установлена \(current).\n\n\(notes)"
        a.addButton(withTitle: "Обновить")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn { download(url) }
    }

    private func download(_ url: URL) {
        busy = true
        URLSession.shared.downloadTask(with: url) { tmp, _, error in
            guard let tmp = tmp, error == nil else {
                DispatchQueue.main.async { self.busy = false; self.alert("Ошибка загрузки", error?.localizedDescription ?? "") }
                return
            }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("puntolite-update-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zipURL = work.appendingPathComponent("PuntoLite.zip")
            try? fm.moveItem(at: tmp, to: zipURL)
            DispatchQueue.main.async { self.install(zip: zipURL, work: work) }
        }.resume()
    }

    private func install(zip: URL, work: URL) {
        defer { busy = false }
        let fm = FileManager.default
        guard FnSetup.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else {
            alert("Ошибка обновления", "Не удалось распаковать архив."); return
        }
        let newApp = work.appendingPathComponent("PuntoLite.app")
        // подпись должна быть цела, а идентификатор — наш
        guard FnSetup.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0,
              Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            alert("Ошибка обновления", "Подпись загруженной версии не прошла проверку."); return
        }
        let target = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("old.app")
        do {
            try fm.moveItem(at: target, to: backup)
            try fm.moveItem(at: newApp, to: target)
        } catch {
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: backup, to: target) }
            alert("Ошибка обновления", "Нет прав на запись в \(target.deletingLastPathComponent().path).\n\(error.localizedDescription)")
            return
        }
        // перезапуск после выхода
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
