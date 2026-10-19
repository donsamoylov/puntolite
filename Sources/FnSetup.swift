// Настройка схемы Fn → F18 → системная смена языка.
// Работает и когда PuntoLite выключен: переназначение держит LaunchAgent,
// а смену языка делает сама macOS по сочетанию F18.

import Foundation

enum FnSetup {
    static let agentLabel = "local.fn-f18"
    static let mapping = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xFF0100000003,"HIDKeyboardModifierMappingDst":0x70000006D},{"HIDKeyboardModifierMappingSrc":0xFF00000003,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// Вызывается при каждом запуске: дёшево и идемпотентно.
    static func ensure() {
        run("/usr/bin/hidutil", ["property", "--set", mapping])
        installAgentIfNeeded()

        let ud = UserDefaults.standard
        if !ud.bool(forKey: "fnSetupDone") {
            applySystemSettings()
            ud.set(true, forKey: "fnSetupDone")
        }
    }

    /// Пункт меню «Восстановить настройку Fn».
    static func repair() {
        run("/usr/bin/hidutil", ["property", "--set", mapping])
        try? FileManager.default.removeItem(at: agentURL)
        installAgentIfNeeded()
        applySystemSettings()
    }

    /// Полный откат к стандартному поведению macOS.
    static func uninstall() {
        run("/bin/launchctl", ["unload", agentURL.path])
        try? FileManager.default.removeItem(at: agentURL)
        run("/usr/bin/hidutil", ["property", "--set", #"{"UserKeyMapping":[]}"#])
        // ⌃Space на «предыдущий источник», Fn снова переключает язык сам
        setSymbolicHotKey60(params: [32, 49, 262144])
        run("/usr/bin/defaults", ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "1"])
        activate()
        UserDefaults.standard.set(false, forKey: "fnSetupDone")
    }

    private static func applySystemSettings() {
        // F18 → «Select the previous input source»
        setSymbolicHotKey60(params: [65535, 79, 8388608])
        // «Press 🌐 key to» → Do Nothing
        run("/usr/bin/defaults", ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"])
        activate()
    }

    private static func installAgentIfNeeded() {
        let fm = FileManager.default
        if fm.fileExists(atPath: agentURL.path) { return }
        try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/hidutil", "property", "--set", mapping],
            "RunAtLoad": true,
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: agentURL)
            run("/bin/launchctl", ["load", agentURL.path])
        }
    }

    private static func setSymbolicHotKey60(params: [Int]) {
        let p = params.map { "<integer>\($0)</integer>" }.joined()
        let value = "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array>\(p)</array><key>type</key><string>standard</string></dict></dict>"
        run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", "60", value])
    }

    private static func activate() {
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: path) else { return -1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
