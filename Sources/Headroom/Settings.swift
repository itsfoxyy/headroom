import Carbon.HIToolbox
import Combine
import Foundation

enum PopoverLayout: String, CaseIterable, Identifiable {
    case compact, standard
    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Standard" }
}

enum LabelStyle: String, CaseIterable, Identifiable {
    case rings
    case everyService
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rings: return "Rings + closest limit"
        case .everyService: return "Every service"
        case .pinned: return "One pinned service"
        }
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case dropdown, peek
    var id: String { rawValue }
}

enum CursorPlanSetting: String, CaseIterable, Identifiable {
    case automatic, current, legacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Detect automatically"
        case .current: return "New (weekly)"
        case .legacy: return "Legacy (monthly)"
        }
    }
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(cmdKey | optionKey))

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }
}

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var layout: PopoverLayout { didSet { defaults.set(layout.rawValue, forKey: "layout") } }
    @Published var labelStyle: LabelStyle { didSet { defaults.set(labelStyle.rawValue, forKey: "labelStyle2") } }
    @Published var pinnedService: ServiceID { didSet { defaults.set(pinnedService.rawValue, forKey: "pinnedService") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    @Published var connected: [ServiceID] {
        didSet { defaults.set(connected.map(\.rawValue), forKey: "connectedServices") }
    }
    @Published var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: "shortcutEnabled") } }
    @Published var shortcut: Shortcut {
        didSet {
            defaults.set(Int(shortcut.keyCode), forKey: "shortcutKey")
            defaults.set(Int(shortcut.modifiers), forKey: "shortcutModifiers")
        }
    }
    @Published var shortcutAction: ShortcutAction { didSet { defaults.set(shortcutAction.rawValue, forKey: "shortcutAction") } }
    @Published var holdToPeek: Bool { didSet { defaults.set(holdToPeek, forKey: "holdToPeek") } }
    @Published var cursorPlan: CursorPlanSetting { didSet { defaults.set(cursorPlan.rawValue, forKey: "cursorPlan") } }

    init() {
        AppSettings.migrateFromEarlyBuilds()
        layout = PopoverLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .compact
        labelStyle = LabelStyle(rawValue: defaults.string(forKey: "labelStyle2") ?? "") ?? .rings
        pinnedService = ServiceID(rawValue: defaults.string(forKey: "pinnedService") ?? "") ?? .claude
        let minutes = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = [1, 2, 5].contains(minutes) ? minutes : 2
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        // Fresh installs start with nothing connected; the welcome window offers the sign-ins.
        let saved = defaults.stringArray(forKey: "connectedServices")
        connected = saved?.compactMap(ServiceID.init(rawValue:)) ?? []
        shortcutEnabled = defaults.object(forKey: "shortcutEnabled") as? Bool ?? true
        if defaults.object(forKey: "shortcutKey") != nil {
            shortcut = Shortcut(keyCode: UInt32(defaults.integer(forKey: "shortcutKey")),
                                modifiers: UInt32(defaults.integer(forKey: "shortcutModifiers")))
        } else {
            shortcut = .default
        }
        shortcutAction = ShortcutAction(rawValue: defaults.string(forKey: "shortcutAction") ?? "") ?? .peek
        holdToPeek = defaults.object(forKey: "holdToPeek") as? Bool ?? true
        cursorPlan = CursorPlanSetting(rawValue: defaults.string(forKey: "cursorPlan") ?? "") ?? .automatic
    }

    /// The first builds used a different app ID; carry their settings over once.
    private static func migrateFromEarlyBuilds() {
        let defaults = UserDefaults.standard
        let oldID = "local.claudeusagebar"
        guard Bundle.main.bundleIdentifier != oldID,
              !defaults.bool(forKey: "migratedEarlySettings") else { return }
        if let old = defaults.persistentDomain(forName: oldID) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedEarlySettings")
    }

    func connect(_ service: ServiceID) {
        guard !connected.contains(service) else { return }
        connected = ServiceID.allCases.filter { connected.contains($0) || $0 == service }
    }

    func disconnect(_ service: ServiceID) {
        connected.removeAll { $0 == service }
    }
}

/// Readable names for the keys a shortcut can use.
enum KeyNames {
    static func name(for keyCode: UInt32) -> String {
        let code = Int(keyCode)
        if let special = specials[code] { return special }
        if let letter = letters[code] { return letter }
        return "Key \(code)"
    }

    private static let specials: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
        kVK_ANSI_Backslash: "\\",
    ]
}
