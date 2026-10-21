// PuntoLite — мгновенная смена языка на Mac + исправление раскладки RU/EN.
//
// Fn (🌐) — мгновенная смена языка (любые языки). Работает и без приложения:
// кнопка перенастраивается один раз (FnSetup.swift), дальше язык меняет macOS.
// Option (одиночное нажатие ⌥) — только при наличии русской раскладки,
// отключается в меню:
//   есть выделение → конвертировать выделенное;
//   нет выделения  → проверить текст до курсора (до 3000 символов)
//                    и исправить слова, набранные не в той раскладке.
//   Если ошибок не найдено — конвертируется последнее слово
//   (повторное нажатие возвращает как было).
// Option + Space — конвертировать только последнее слово до пробела/спецсимвола.
// Интерфейс — на русском или английском по языку системы.

import Cocoa
import Carbon
import ApplicationServices
import ServiceManagement

let maxLookback = 3000          // сколько символов до курсора анализировать
let pasteThreshold = 30         // длиннее — вставка через буфер обмена, короче — печать

/// Интерфейс на языке системы: русский или английский.
let isRussianUI = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
func L(_ ru: String, _ en: String) -> String { isRussianUI ? ru : en }

// MARK: - Раскладка

final class KbLayout {
    let source: TISInputSource
    let id: String
    let lang: String                       // "en" / "ru"
    // table[mods][keycode]; mods: bit0 = shift, bit1 = caps lock
    var table = [[String]](repeating: [String](repeating: "", count: 128), count: 4)
    // символ → (keycode, mods)
    var reverse = [Character: (UInt16, Int)]()

    init?(source: TISInputSource, lang: String) {
        self.source = source
        self.lang = lang
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layoutPtr = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        for mods in 0..<4 {
            var carbonMods: UInt32 = 0
            if mods & 1 != 0 { carbonMods |= UInt32(shiftKey) }
            if mods & 2 != 0 { carbonMods |= UInt32(alphaLock) }
            let modState = (carbonMods >> 8) & 0xFF
            for kc in 0..<128 {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layoutPtr, UInt16(kc), UInt16(kUCKeyActionDown), modState,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &dead, 4, &len, &chars)
                guard st == noErr, len > 0 else { continue }
                let s = String(utf16CodeUnits: chars, count: len)
                if let sc = s.unicodeScalars.first,
                   !CharacterSet.controlCharacters.contains(sc),
                   !(0xF700...0xF8FF).contains(sc.value) {
                    table[mods][kc] = s
                }
            }
        }
        for mods in [0, 1] {
            for kc in 0..<128 {
                let s = table[mods][kc]
                if s.count == 1, let c = s.first, reverse[c] == nil {
                    reverse[c] = (UInt16(kc), mods)
                }
            }
        }
    }
}

func findLayouts() -> (KbLayout, KbLayout)? {
    let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
    guard let raw = TISCreateInputSourceList(filter, false) else { return nil }
    let list = raw.takeRetainedValue() as NSArray as! [TISInputSource]
    var en: KbLayout?
    var ru: KbLayout?
    for src in list {
        guard let lp = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { continue }
        let langs = Unmanaged<CFArray>.fromOpaque(lp).takeUnretainedValue() as? [String] ?? []
        guard let first = langs.first else { continue }
        if first.hasPrefix("en"), en == nil { en = KbLayout(source: src, lang: "en") }
        if first.hasPrefix("ru"), ru == nil { ru = KbLayout(source: src, lang: "ru") }
    }
    if let en = en, let ru = ru { return (en, ru) }
    return nil
}

// MARK: - Проверка слов (встроенные словари macOS)

final class Speller {
    private var codes = [String: String]()

    init() {
        let avail = NSSpellChecker.shared.availableLanguages
        for l in ["en", "ru"] {
            codes[l] = avail.first(where: { $0 == l }) ?? avail.first(where: { $0.hasPrefix(l) }) ?? l
        }
    }

    func isWord(_ w: String, _ lang: String) -> Bool {
        guard !w.isEmpty else { return false }
        let wantCyr = lang == "ru"
        for sc in w.unicodeScalars where CharacterSet.letters.contains(sc) {
            if isCyr(sc) != wantCyr { return false }
        }
        let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: codes[lang],
                                                    wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }
}

func isCyr(_ sc: Unicode.Scalar) -> Bool { (0x0400...0x04FF).contains(sc.value) }
func isLat(_ sc: Unicode.Scalar) -> Bool { (0x41...0x5A).contains(sc.value) || (0x61...0x7A).contains(sc.value) }

// MARK: - Типы

struct Stroke {
    let code: UInt16
    let mods: Int
    var layout: Int          // 0 = en, 1 = ru
}

enum Entry {
    case key(Stroke)
    case space
}

enum WordStatus { case right, wrong, unsure }

struct TextFix {
    let start: Int              // индекс Character, с которого заменяем
    let newText: String         // новый текст от start до конца
    let flipped: [Range<Int>]   // сконвертированные слова (индексы Character)
    let finalLayout: Int?       // раскладка, которую включить после исправления
}

// MARK: - Приложение

let magic: Int64 = 0x50554E54   // метка наших синтетических событий

let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    let app = Unmanaged<App>.fromOpaque(refcon!).takeUnretainedValue()
    return app.handle(type: type, event: event)
}

final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var layouts: [KbLayout] = []
    let speller = Speller()
    let eventSource = CGEventSource(stateID: .privateState)

    var buffer: [Entry] = []
    var fnDown = false
    var fnUsed = false
    var fnTime = Date()
    var pendingFix = false
    var swallowSpaceUp = false
    var f18Down = false                                  // Fn, переназначенный в F18
    var optDown = false                                  // одиночное нажатие Option
    var optUsed = false
    var optTime = Date()
    var paused = false
    var pauseItem: NSMenuItem!
    var loginItem: NSMenuItem!

    var fixItem: NSMenuItem?
    var accessItem: NSMenuItem?
    var accessTimer: Timer?
    var isReturningUser = false                          // приложение уже запускалось раньше
    var curSourceID: String?                             // текущий язык ввода
    var prevSourceID: String?                            // предыдущий — куда вернуться по Fn
    var hasRussian: Bool { !layouts.isEmpty }
    var fixEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "fixEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fixEnabled") }
    }
    var needsTap: Bool { hasRussian && fixEnabled && !paused }

    let fixedTitle = L("Кнопка смены языка перенастроена", "Language switch key fixed")

    @objc func repairFn() {
        FnSetup.repair()
        notify(fixedTitle, L("Проблема исправлена: Fn (🌐) снова переключает язык сразу.",
                             "Problem solved: Fn (🌐) switches the input language instantly again."))
    }

    func notify(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    @objc func uninstallFn() {
        FnSetup.uninstall()
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        NSApp.terminate(nil)
    }

    @objc func checkUpdates() { Updater.shared.check(userInitiated: true) }

    /// Запуск прямо из DMG — предлагаем скопировать в «Программы».
    func moveToApplicationsIfNeeded() -> Bool {
        let here = Bundle.main.bundleURL
        guard here.path.hasPrefix("/Volumes/") else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("Переместить PuntoLite в «Программы»?", "Move PuntoLite to Applications?")
        a.informativeText = L("Из образа диска приложение не сможет обновляться и запускаться при входе.",
                              "Running from the disk image, the app can't update itself or start at login.")
        a.addButton(withTitle: L("Переместить", "Move"))
        a.addButton(withTitle: L("Не сейчас", "Not now"))
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        let dest = URL(fileURLWithPath: "/Applications/PuntoLite.app")
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard FnSetup.run("/usr/bin/ditto", [here.path, dest.path]) == 0 else { return false }
        FnSetup.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(dest.path)\""]
        try? p.run()
        NSApp.terminate(nil)
        return true
    }

    @objc func openAXSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func togglePause() {
        paused.toggle()
        pauseItem.state = paused ? .on : .off
        buffer.removeAll()
        applyTapState()
    }

    @objc func toggleFix() {
        fixEnabled.toggle()
        fixItem?.state = fixEnabled ? .on : .off
        buffer.removeAll()
        applyTapState()
    }

    /// Перехват клавиатуры: исправление раскладки (если включено) и страховка Fn.
    /// Доступ запрашиваем только ради исправления раскладки; если он уже выдан —
    /// перехват работает и для страховки Fn.
    func applyTapState() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        else if needsTap { requestAccessAndStart() }
        else if AXIsProcessTrusted() { startTap() }
        updateTitle()
    }

    /// Доступ к «Универсальному доступу» нужен только для исправления раскладки.
    /// После обновления (новая подпись) macOS считает приложение другим: старая
    /// запись остаётся, но не работает. Тогда сбрасываем её и просим включить заново.
    func requestAccessAndStart(userInitiated: Bool = false) {
        if AXIsProcessTrusted() { startTap(); return }
        let ud = UserDefaults.standard
        let version = Updater.shared.current
        let afterUpdate = isReturningUser && ud.string(forKey: "accessResetVersion") != version
        if afterUpdate || userInitiated {
            ud.set(version, forKey: "accessResetVersion")
            FnSetup.run("/usr/bin/tccutil", ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "local.puntolite"])
            explainAccess(afterUpdate: afterUpdate && !userInitiated)
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if accessTimer == nil {
            accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    t.invalidate(); self.accessTimer = nil
                    if self.tap == nil { self.startTap() }
                }
            }
        }
        updateTitle()
    }

    func explainAccess(afterUpdate: Bool) {
        let why = afterUpdate
            ? L("PuntoLite обновился, и macOS просит подтвердить доступ ещё раз. ",
                "PuntoLite was updated, and macOS asks you to confirm access again. ")
            : ""
        notify(L("Включите PuntoLite в «Универсальном доступе»", "Turn on PuntoLite in Accessibility"),
               why + L("В открывшемся окне включите переключатель у PuntoLite.\n\nЭто нужно только для исправления раскладки по Option. Смена языка по Fn работает и без этого.",
                       "In the window that opens, turn on the switch next to PuntoLite.\n\nThis is only needed to fix the wrong layout with Option. Instant language switching with Fn works without it."))
        openAXSettings()
    }

    @objc func fixAccess() { requestAccessAndStart(userInitiated: true) }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify(L("Не удалось изменить автозапуск", "Couldn't change Open at Login"),
                   L("Переместите приложение в папку «Программы» и попробуйте снова.",
                     "Move the app to the Applications folder and try again.") + "\n\(error.localizedDescription)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if moveToApplicationsIfNeeded() { return }
        isReturningUser = UserDefaults.standard.bool(forKey: "fnSetupDone")
        if let pair = findLayouts() { layouts = [pair.0, pair.1] }   // RU+EN есть — доступно исправление раскладки

        if FnSetup.ensure() {
            let extra = hasRussian
                ? L("\nOption (⌥) — исправить текст, набранный не в той раскладке.", "")
                : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.notify(self.fixedTitle,
                            L("Проблема исправлена: Fn (🌐) теперь переключает язык сразу, без задержки.",
                              "Problem solved: Fn (🌐) now switches the input language instantly, with no delay.") + extra)
            }
        }
        Updater.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "pdf"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 16, height: 16)
            img.isTemplate = true                       // подстраивается под светлую/тёмную тему
            statusItem.button?.image = img
            statusItem.button?.imagePosition = .imageLeading
            statusItem.button?.title = ""
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "PuntoLite", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let fnInfo = NSMenuItem(title: L("Fn (🌐) — мгновенная смена языка", "Fn (🌐) — instant language switch"),
                                action: nil, keyEquivalent: "")
        fnInfo.isEnabled = false
        menu.addItem(fnInfo)
        if hasRussian {
            let item = NSMenuItem(title: L("Исправлять раскладку по Option (⌥)", "Fix wrong layout with Option (⌥)"),
                                  action: #selector(toggleFix), keyEquivalent: "")
            item.target = self
            item.state = fixEnabled ? .on : .off
            menu.addItem(item)
            fixItem = item
            let wordInfo = NSMenuItem(title: L("    Option + Пробел — только последнее слово", "    Option + Space — last word only"),
                                      action: nil, keyEquivalent: "")
            wordInfo.isEnabled = false
            menu.addItem(wordInfo)
        }
        let acc = NSMenuItem(title: hasRussian
                                ? L("⚠️ Включить исправление раскладки…", "⚠️ Enable layout fix…")
                                : L("Fn во всех программах (Photoshop и др.)…", "Make Fn work in all apps (Photoshop etc.)…"),
                             action: #selector(fixAccess), keyEquivalent: "")
        acc.target = self
        acc.isHidden = true
        menu.addItem(acc)
        accessItem = acc
        menu.addItem(.separator())
        pauseItem = NSMenuItem(title: L("Пауза", "Pause"), action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        if hasRussian { menu.addItem(pauseItem) }
        loginItem = NSMenuItem(title: L("Запускать при входе", "Open at Login"), action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        // автозапуск включаем сами при первом запуске
        let ud = UserDefaults.standard
        if !ud.bool(forKey: "didSetupLogin") {
            ud.set(true, forKey: "didSetupLogin")
            try? SMAppService.mainApp.register()
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        if hasRussian {
            let perm = NSMenuItem(title: L("Открыть настройки доступа…", "Open Accessibility Settings…"),
                                  action: #selector(openAXSettings), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }
        let repair = NSMenuItem(title: L("Починить кнопку смены языка", "Fix language switch key"),
                                action: #selector(repairFn), keyEquivalent: "")
        repair.target = self
        menu.addItem(repair)
        let reset = NSMenuItem(title: L("Вернуть стандартную кнопку языка и выйти", "Restore default Fn key and quit"),
                               action: #selector(uninstallFn), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let ver = NSMenuItem(title: L("Версия", "Version") + " \(Updater.shared.current)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        let upd = NSMenuItem(title: L("Проверить обновления…", "Check for Updates…"), action: #selector(checkUpdates), keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)
        menu.addItem(NSMenuItem(title: L("Выход", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        curSourceID = currentSourceID()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(resetBuffer),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        applyTapState()
    }

    func startTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: tapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            updateTitle()
            return
        }
        tap = t
        UserDefaults.standard.set(Updater.shared.current, forKey: "accessResetVersion")
        let rl = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rl, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        updateTitle()
    }

    // MARK: События клавиатуры

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        let fixActive = needsTap
        if event.getIntegerValueField(.eventSourceUserData) == magic { return pass }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .flagsChanged:
            if (code == 58 || code == 61) && fixActive {       // Option (левый / правый)
                let others: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]
                let down = event.flags.contains(.maskAlternate)
                if down && !optDown {
                    optDown = true
                    optUsed = !event.flags.intersection(others).isEmpty
                    optTime = Date()
                } else if !down && optDown {
                    optDown = false
                    if !optUsed && Date().timeIntervalSince(optTime) < 0.5 {
                        DispatchQueue.main.async { self.fnSpace() }
                    }
                }
                return pass
            }
            if optDown { optUsed = true }                      // Option в сочетании с другим модификатором
            if code == 63 || code == 179 {                     // Fn / Globe
                let down = event.flags.contains(.maskSecondaryFn)
                if down && !fnDown {
                    fnDown = true; fnUsed = false; pendingFix = false; fnTime = Date()
                } else if !down && fnDown {
                    fnDown = false
                    if pendingFix {
                        pendingFix = false
                        DispatchQueue.main.async { self.fnSpace() }
                    } else if !fnUsed && Date().timeIntervalSince(fnTime) < 0.6 {
                        DispatchQueue.main.async { if self.hasRussian { self.select(self.currentIndex() == 0 ? 1 : 0) } }
                    }
                }
            }
            return pass

        case .keyDown:
            if optDown { optUsed = true }                      // ⌥+клавиша — обычный ввод, не наш тап
            if optDown && code == 49 && fixActive &&           // Option + Space — только последнее слово
               event.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty {
                swallowSpaceUp = true
                DispatchQueue.main.async { self.lastWordFix() }
                return nil
            }
            if code == 79 {                                 // F18 (= Fn через hidutil)
                // пропускаем дальше: язык переключает сама macOS по сочетанию F18
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    f18Down = true
                    f18Watchdog()                           // если программа «съела» сочетание — переключим сами
                }
                return pass
            }
            if f18Down || fnDown {                          // сочетания с Fn — не трогаем
                fnUsed = true
                buffer.removeAll()
                return pass
            }
            if fixActive { record(event, code: code) }
            return pass

        case .keyUp:
            if code == 79 { f18Down = false; return pass }
            if code == 49 && swallowSpaceUp { swallowSpaceUp = false; return nil }
            return pass

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if optDown { optUsed = true }                      // ⌥+клик
            buffer.removeAll()
            return pass

        default:
            return pass
        }
    }

    func record(_ e: CGEvent, code: UInt16) {
        let f = e.flags
        if f.contains(.maskCommand) || f.contains(.maskControl) || f.contains(.maskAlternate) {
            buffer.removeAll(); return
        }
        if code == 51 { if !buffer.isEmpty { buffer.removeLast() }; return }   // Backspace
        if code == 49 { buffer.append(.space); trim(); return }                  // Space
        let li = currentIndex()
        let mods = (f.contains(.maskShift) ? 1 : 0) | (f.contains(.maskAlphaShift) ? 2 : 0)
        guard li >= 0, code < 128, !layouts[li].table[mods][Int(code)].isEmpty else {
            buffer.removeAll(); return
        }
        buffer.append(.key(Stroke(code: code, mods: mods, layout: li)))
        trim()
    }

    func trim() { if buffer.count > 400 { buffer.removeFirst(100) } }

    @objc func resetBuffer() { buffer.removeAll() }

    // MARK: Раскладки

    func currentIndex() -> Int {
        let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(cur, kTISPropertyInputSourceID) else { return -1 }
        let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        for (i, l) in layouts.enumerated() where l.id == id { return i }
        return -1
    }

    // MARK: Страховка Fn: программы, которые глотают сочетание смены языка

    func sourceID(_ src: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    func currentSourceID() -> String? { sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }

    @objc func sourceChanged() {
        if let id = currentSourceID(), id != curSourceID {
            prevSourceID = curSourceID
            curSourceID = id
        }
        updateTitle()
    }

    func selectableSources() -> [TISInputSource] {
        let filter: [String: Any] = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                                     kTISPropertyInputSourceIsSelectCapable as String: true]
        guard let raw = TISCreateInputSourceList(filter as CFDictionary, false) else { return [] }
        return raw.takeRetainedValue() as NSArray as! [TISInputSource]
    }

    /// Fn (F18) обычно переключает сама macOS. Некоторые окна (например, диалоги
    /// Photoshop) перехватывают сочетание — тогда язык не меняется. Если за 0,3 с
    /// смены не было, переключаем на предыдущий язык сами.
    func f18Watchdog() {
        let before = currentSourceID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.currentSourceID() == before else { return }
            let sources = self.selectableSources()
            let target = sources.first(where: { self.sourceID($0) == self.prevSourceID && self.prevSourceID != before })
                ?? sources.first(where: { self.sourceID($0) != before })
            if let t = target { TISSelectInputSource(t) }
        }
    }

    func select(_ i: Int) {
        TISSelectInputSource(layouts[i].source)
        updateTitle()
    }

    @objc func updateTitle() {
        let noAccess = needsTap && tap == nil
        statusItem?.button?.title = noAccess ? " !" : ""                 // «!» — нет доступа
        accessItem?.isHidden = hasRussian ? !noAccess : tap != nil
        statusItem?.button?.appearsDisabled = paused                     // на паузе иконка бледная
    }

    // MARK: Конвертация

    /// 1 — кириллица преобладает, 0 — латиница, nil — букв нет
    func scriptLayout(_ s: String) -> Int? {
        var cyr = 0, lat = 0
        for sc in s.unicodeScalars {
            if isCyr(sc) { cyr += 1 } else if isLat(sc) { lat += 1 }
        }
        if cyr == 0 && lat == 0 { return nil }
        return cyr > lat ? 1 : 0
    }

    /// Конвертирует строку из раскладки, в которой она набрана, в другую.
    func convertAuto(_ s: String) -> (text: String, src: Int, dst: Int) {
        let cur = currentIndex()
        let src = scriptLayout(s) ?? (cur >= 0 ? cur : 0)
        let dst = 1 - src
        var out = ""
        for c in s {
            if let m = layouts[src].reverse[c] {
                let t = layouts[dst].table[m.1][Int(m.0)]
                out += t.isEmpty ? String(c) : t
            } else {
                out.append(c)
            }
        }
        return (out, src, dst)
    }

    func status(_ token: String) -> WordStatus {
        // ссылки, почты, числа, код — не трогаем
        if token.rangeOfCharacter(from: .decimalDigits) != nil { return .right }
        for bad in ["@", "/", "\\", "_", "#", "://"] where token.contains(bad) { return .right }

        let conv = convertAuto(token)
        let letters = CharacterSet.letters
        let tCore = token.trimmingCharacters(in: letters.inverted)
        let aCore = conv.text.trimmingCharacters(in: letters.inverted)
        if tCore.isEmpty && aCore.isEmpty { return .right }

        let tOK = speller.isWord(tCore, layouts[conv.src].lang)
        let aOK = speller.isWord(aCore, layouts[conv.dst].lang)
        let short = max(tCore.count, aCore.count) <= 2
        switch (tOK, aOK) {
        case (true, false): return .right
        case (false, true): return short ? .unsure : .wrong
        case (true, true):  return short ? .unsure : .right
        default:            return .unsure          // нет в словарях: решаем по соседям
        }
    }

    /// Находит слова не в той раскладке. forceLast — если ничего не найдено,
    /// конвертировать последнее слово.
    func analyze(_ text: String, forceLast: Bool) -> TextFix? {
        let chars = Array(text)
        var tokens: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var j = i
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            tokens.append(i..<j)
            i = j
        }
        guard !tokens.isEmpty else { return nil }

        let firm = tokens.map { status(String(chars[$0])) }
        var st = firm
        for k in st.indices where firm[k] == .unsure {
            var left: WordStatus? = nil
            var right: WordStatus? = nil
            var a = k - 1
            while a >= 0 { if firm[a] != .unsure { left = firm[a]; break }; a -= 1 }
            var b = k + 1
            while b < firm.count { if firm[b] != .unsure { right = firm[b]; break }; b += 1 }
            let wrong: Bool
            switch (left, right) {
            case (.some(let x), .some(let y)): wrong = x == .wrong && y == .wrong
            case (.some(let x), nil):          wrong = x == .wrong
            case (nil, .some(let y)):          wrong = y == .wrong
            default:                           wrong = false
            }
            st[k] = wrong ? .wrong : .right
        }

        var wrongIdx = st.indices.filter { st[$0] == .wrong }
        if wrongIdx.isEmpty {
            guard forceLast else { return nil }
            wrongIdx = [tokens.count - 1]
        }
        let wrongSet = Set(wrongIdx)
        let start = tokens[wrongIdx[0]].lowerBound

        var out = ""
        var pos = start
        for (k, r) in tokens.enumerated() where r.upperBound > start {
            out += String(chars[pos..<r.lowerBound])
            let tok = String(chars[r])
            out += wrongSet.contains(k) ? convertAuto(tok).text : tok
            pos = r.upperBound
        }
        out += String(chars[pos..<chars.count])

        let last = tokens.count - 1
        let lastTok = String(chars[tokens[last]])
        let lastFinal = wrongSet.contains(last) ? convertAuto(lastTok).text : lastTok

        return TextFix(start: start, newText: out,
                       flipped: wrongIdx.map { tokens[$0] },
                       finalLayout: scriptLayout(lastFinal))
    }

    // MARK: Исправление раскладки (Option)

    func fnSpace() {
        if let el = editableFocused() {
            if let sel = axString(el, kAXSelectedTextAttribute), !sel.isEmpty {
                let conv = convertAuto(sel)
                replaceSelection(el, with: conv.text)
                buffer.removeAll()
                select(conv.dst)
                return
            }
            if fixViaAX(el) { return }
        }
        fixViaBuffer()
    }

    /// Option + Space: конвертировать только последнее слово перед курсором —
    /// до первого пробела или спецсимвола. Если есть выделение — его.
    func lastWordFix() {
        let isLetter: (String) -> Bool = { !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } }
        if let el = editableFocused(), let value = axString(el, kAXValueAttribute), let sel = axRange(el) {
            let ns = value as NSString
            let cursor = sel.location
            if cursor != kCFNotFound, cursor >= 0, cursor + max(sel.length, 0) <= ns.length {
                if sel.length > 0 {
                    let conv = convertAuto(ns.substring(with: NSRange(location: cursor, length: sel.length)))
                    replaceSelection(el, with: conv.text)
                    buffer.removeAll()
                    select(conv.dst)
                    return
                }
                var start = cursor
                while start > 0 {
                    let r = ns.rangeOfComposedCharacterSequence(at: start - 1)
                    guard isLetter(ns.substring(with: r)) else { break }
                    start = r.location
                }
                guard start < cursor else { return }
                let conv = convertAuto(ns.substring(with: NSRange(location: start, length: cursor - start)))
                if setRange(el, CFRange(location: start, length: cursor - start)) {
                    usleep(20_000)
                    replaceSelection(el, with: conv.text)
                    buffer.removeAll()
                    select(conv.dst)
                    return
                }
            }
        }
        // Запасной путь (терминал, Electron): по запомненным нажатиям.
        var n = 0
        for e in buffer.reversed() {
            guard case .key(let k) = e, isLetter(layouts[k.layout].table[k.mods][Int(k.code)]) else { break }
            n += 1
        }
        guard n > 0 else { return }
        var out = ""
        var dst = 0
        for idx in (buffer.count - n)..<buffer.count {
            if case .key(var k) = buffer[idx] {
                let flipped = 1 - k.layout
                let t = layouts[flipped].table[k.mods][Int(k.code)]
                out += t.isEmpty ? layouts[k.layout].table[k.mods][Int(k.code)] : t
                k.layout = flipped
                buffer[idx] = .key(k)
                dst = flipped
            }
        }
        backspaces(n)
        insert(out)
        select(dst)
    }

    /// Основной путь: читаем текст до курсора через Accessibility.
    func fixViaAX(_ el: AXUIElement) -> Bool {
        guard let value = axString(el, kAXValueAttribute), let sel = axRange(el) else { return false }
        let ns = value as NSString
        let cursor = sel.location
        guard cursor != kCFNotFound, cursor >= 0, cursor <= ns.length else { return false }

        var from = max(0, cursor - maxLookback)
        if from > 0 {
            from = ns.rangeOfComposedCharacterSequence(at: from).location
            // начинаем с целого слова
            let ws = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: [],
                                         range: NSRange(location: from, length: cursor - from))
            if ws.location != NSNotFound { from = ws.location + 1 }
        }
        let text = ns.substring(with: NSRange(location: from, length: cursor - from))
        guard let fix = analyze(text, forceLast: true) else { return true }

        let prefix = String(Array(text)[0..<fix.start]).utf16.count
        let loc = from + prefix
        guard setRange(el, CFRange(location: loc, length: cursor - loc)) else { return false }
        usleep(20_000)
        replaceSelection(el, with: fix.newText)
        buffer.removeAll()
        if let l = fix.finalLayout { select(l) }
        return true
    }

    /// Запасной путь (терминал, Electron): по запомненным нажатиям.
    func fixViaBuffer() {
        guard !buffer.isEmpty else { return }
        let rendered = buffer.map { e -> String in
            switch e {
            case .space: return " "
            case .key(let k): return layouts[k.layout].table[k.mods][Int(k.code)]
            }
        }
        guard rendered.allSatisfy({ $0.count == 1 }) else { buffer.removeAll(); return }
        guard let fix = analyze(rendered.joined(), forceLast: true) else { return }

        backspaces(buffer.count - fix.start)
        insert(fix.newText)
        for r in fix.flipped {
            for idx in r {
                if case .key(var k) = buffer[idx] {
                    k.layout = 1 - k.layout
                    buffer[idx] = .key(k)
                }
            }
        }
        if let l = fix.finalLayout { select(l) }
    }

    // MARK: Accessibility

    func editableFocused() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let fv = f else { return nil }
        let el = fv as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return el
    }

    func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    func axRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let vv = v else { return nil }
        var r = CFRange()
        guard AXValueGetValue(vv as! AXValue, .cfRange, &r) else { return nil }
        return r
    }

    func setRange(_ el: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Заменяет выделенное: сначала через AX, если поле не поменялось — вставкой.
    func replaceSelection(_ el: AXUIElement, with s: String) {
        let before = axString(el, kAXValueAttribute)
        let ok = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString) == .success
        usleep(30_000)
        let after = axString(el, kAXValueAttribute)
        if !ok || (before != nil && before == after) {
            insert(s)
        }
    }

    // MARK: Синтетический ввод

    func post(_ e: CGEvent, flags: CGEventFlags = []) {
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: magic)
        e.post(tap: .cghidEventTap)
    }

    func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        if let d = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true) { post(d, flags: flags) }
        if let u = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: false) { post(u, flags: flags) }
    }

    func backspaces(_ n: Int) {
        guard n > 0 else { return }
        for _ in 0..<n { pressKey(51); usleep(1500) }
    }

    func insert(_ s: String) {
        if s.count > pasteThreshold { paste(s) } else { typeText(s) }
    }

    func typeText(_ s: String) {
        for ch in s {
            var units = Array(String(ch).utf16)
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: down) {
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    post(e)
                }
            }
            usleep(1500)
        }
    }

    /// Вставка через буфер обмена с восстановлением его содержимого.
    func paste(_ s: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types {
                if let d = item.data(forType: t) { copy.setData(d, forType: t) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(s, forType: .string)
        pressKey(9, flags: .maskCommand)                       // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

// MARK: - main

let application = NSApplication.shared
let delegate = App()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
