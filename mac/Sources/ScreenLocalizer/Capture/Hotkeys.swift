import AppKit
import Carbon

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case translateSelection, captureScreen, pasteBox
    var id: String { rawValue }

    var label: String {
        switch self {
        case .translateSelection: return L("Translate selected text")
        case .captureScreen: return L("Capture text from screen")
        case .pasteBox: return L("Open paste box")
        }
    }
}

/// A global shortcut: a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaults: [HotkeyAction: KeyCombo] = [
        .translateSelection: KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)),
        .captureScreen: KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey)),
        .pasteBox: KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)),
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a combo from a key event; requires ⌘, ⌃ or ⌥ so plain typing never becomes a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        guard KeyCombo.keyNames[Int(event.keyCode)] != nil else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var keyName: String { KeyCombo.keyNames[Int(keyCode)] ?? "?" }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// Key equivalent string for showing the shortcut in an NSMenu.
    var menuKeyEquivalent: String {
        let name = keyName
        return name.count == 1 ? name.lowercased() : ""
    }

    static let keyNames: [Int: String] = {
        var m: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Grave: "`", kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        m[kVK_UpArrow] = "↑"; m[kVK_DownArrow] = "↓"; m[kVK_LeftArrow] = "←"; m[kVK_RightArrow] = "→"
        return m
    }()
}

/// Registers system-wide shortcuts with the Carbon hot key API (needs no special permission).
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onAction: ((HotkeyAction) -> Void)?
    private(set) var failed: Set<HotkeyAction> = []
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var handlerInstalled = false
    private var suspended = false

    func registerAll(_ combos: [HotkeyAction: KeyCombo]) {
        unregisterAll()
        installHandlerIfNeeded()
        failed = []
        var nextID: UInt32 = 1
        for action in HotkeyAction.allCases {
            defer { nextID += 1 }
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x534C_4F43), id: nextID) // 'SLOC'
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[nextID] = action
            } else {
                failed.insert(action)
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    /// Temporarily releases the shortcuts, e.g. while the user records a new one.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll(AppSettings.shared.hotkeys)
    }

    fileprivate func fire(id: UInt32) {
        guard !suspended, let action = actions[id] else { return }
        onAction?(action)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotkeyManager.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
